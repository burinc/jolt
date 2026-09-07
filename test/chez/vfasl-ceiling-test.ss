;; vfasl-ceiling-test.ss — the boot image's LZ4 ceiling (jolt-23z).
;;
;; A compressed fasl entry whose UNCOMPRESSED size reaches 2^28 bytes cannot be
;; read back when the entry is LZ4: c/new-io.c's S_bytevector_uncompress returns
;; the length as `Sfixnum(r)` with `int r`, and Sfixnum multiplies by 8 in the
;; argument's own type, so 2^28 and up wrap to a negative fixnum and c/fasl.c's
;; length check can never match. A binary whose boot image is over the line dies
;; inside Sbuild_heap before a line of its own code runs. gzip's arm of the same
;; function hands zlib a uLong and has no ceiling.
;;
;; That only became reachable in 0.8.5, which ships the boot as vfasl: a plain
;; boot is one compressed entry per top-level form and its entries are kilobytes,
;; while vfasl-convert-file combines each input boot file into ONE entry — so the
;; app half of a large program is a single image, and past 256MiB it stops
;; loading rather than merely loading slowly.
;;
;; jolt cannot patch the kernel it links against, so build.ss measures the
;; converted boot and re-encodes over-ceiling images with gzip. This gate pins
;; the three things that fix rests on:
;;
;;   a. the ceiling is real, and it is exactly 2^28 — case (b) failing means a
;;      newer Chez fixed the overflow and the workaround can go
;;   b. gzip has no ceiling, so it is a valid answer for an oversized image
;;   c. the entry scanner reads real converted boots correctly, answers 0 for a
;;      boot with no LZ4 entries at all, and trips at exactly the ceiling
;;
;; (a) and (b) allocate 256MiB bytevectors; the Makefile target runs this with
;; JOLT_MAX_HEAP=off so the runtime's own heap bound does not fire first.
;;
;;   chez --script test/chez/vfasl-ceiling-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/cli-core.ss")
(load "host/chez/png.ss")
(load "host/chez/loader.ss")
(load "host/chez/java/ffi.ss")
(load "host/chez/build.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (if pred (printf "PASS: ~a\n" name)
      (begin (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name))))

(define tmp "target/vfasl-ceiling-gate")
(bld-mkdir-p tmp)
(define (at name) (string-append tmp "/" name))

;; --- a/b: the kernel fact the workaround exists for -------------------------
;; All-zero bytes so the compressor is fast and the compressed form is ~1MB:
;; what is under test is the LENGTH the kernel reports back, not the codec.
(define (round-trips? fmt n)
  (parameterize ((compress-format fmt) (compress-level 'minimum))
    (guard (e (#t #f))
      (let* ((bv (make-bytevector n 0))
             (back (bytevector-uncompress (bytevector-compress bv))))
        (= n (bytevector-length back))))))

(ok "lz4 entry round-trips one byte under the ceiling"
    (round-trips? 'lz4 (- (bld-lz4-image-ceiling) 1)))
;; The one that must keep failing. If it starts passing, the Chez being built
;; against has fixed S_bytevector_uncompress and bld-vfasl-convert! can drop the
;; gzip arm — so this is a "delete the workaround" signal, not a regression.
(ok "lz4 entry does NOT round-trip at the ceiling"
    (not (round-trips? 'lz4 (bld-lz4-image-ceiling))))
(ok "gzip entry round-trips at the ceiling"
    (round-trips? 'gzip (bld-lz4-image-ceiling)))

;; --- c: the scanner, over boots it actually produced -------------------------
;; A compiled object with a body big enough to clear the 100-byte floor under
;; which $write-fasl-bytevectors does not compress at all, converted both ways
;; sa-vfasl-convert-file offers.
(define probe-src (at "probe.ss"))
(let ((p (open-output-file probe-src 'replace)))
  (put-string p "(define probe-data '#(")
  (let loop ((i 0))
    (when (< i 4000)
      (put-string p (number->string (modulo i 97)))
      (put-string p " ")
      (loop (+ i 1))))
  (put-string p "))\n")
  (close-port p))
(define probe-so (at "probe.so"))
(sa-compile-file probe-src probe-so
  '((optimize . 2) (inspector-info . #f) (source-info . #f) (compressed . #t)))

(define lz4-boot (at "probe.lz4boot"))
(define gzip-boot (at "probe.gzipboot"))
(ok "vfasl conversion (default codec) succeeds"
    (sa-vfasl-convert-file probe-so lz4-boot))
(ok "vfasl conversion ('wide codec) succeeds"
    (sa-vfasl-convert-file probe-so gzip-boot 'wide))

(ok "scanner finds the LZ4 entries of a default-codec boot"
    (> (bld-boot-max-lz4-entry lz4-boot) 0))
;; The whole point of the 'wide arm: nothing in the re-encoded boot is LZ4, so
;; nothing in it can hit the ceiling.
(ok "a 'wide boot carries no LZ4 entry at all"
    (= (bld-boot-max-lz4-entry gzip-boot) 0))
(ok "neither small boot reads as over the ceiling"
    (and (not (bld-boot-over-lz4-ceiling? lz4-boot))
         (not (bld-boot-over-lz4-ceiling? gzip-boot))))

;; --- c: the ceiling branch, without building a 256MiB app --------------------
;; Boot framing, from ChezScheme s/strip.ss (read-entry): a header entry, then
;; one LZ4 object entry declaring DECLARED as its uncompressed size. Only the
;; declared size is read, so the payload can be anything.
(define (uptr-bytes n)                   ; Chez put-uptr: septets, high first,
  (let loop ((n n) (septets '()))        ; bit 7 set on all but the last
    (if (< n 128)
        (let mark ((s (cons n septets)) (out '()))
          (if (null? (cdr s))
              (reverse (cons (car s) out))
              (mark (cdr s) (cons (+ 128 (car s)) out))))
        (loop (quotient n 128) (cons (remainder n 128) septets)))))

(define (write-synthetic-boot! path declared)
  (let* ((dest (uptr-bytes declared))
         (payload 8)
         (size (+ 2 (length dest) payload))
         (bytes (append '(0 0 0 0 99 104 101 122)          ; fasl header + "chez"
                        (uptr-bytes 168034560)              ; version
                        (uptr-bytes 38)                     ; machine
                        '(40 41)                            ; ( )  no boot files
                        '(37)                               ; visit-revisit
                        (uptr-bytes size)
                        '(46 101)                           ; lz4, vfasl
                        dest
                        (make-list payload 0))))
    (let ((p (open-file-output-port path (file-options no-fail))))
      (put-bytevector p (u8-list->bytevector bytes))
      (close-port p))))

(define under (at "under.boot"))
(define over (at "over.boot"))
(write-synthetic-boot! under (- (bld-lz4-image-ceiling) 1))
(write-synthetic-boot! over (bld-lz4-image-ceiling))
(ok "scanner reads back a declared size one under the ceiling"
    (= (bld-boot-max-lz4-entry under) (- (bld-lz4-image-ceiling) 1)))
(ok "one byte under the ceiling is not over it"
    (not (bld-boot-over-lz4-ceiling? under)))
(ok "the ceiling itself is over it"
    (bld-boot-over-lz4-ceiling? over))

;; A file that is not a boot at all: the scanner says #f (don't know) and the
;; caller leaves the boot alone rather than re-encoding on a guess.
(define junk (at "junk.boot"))
(let ((p (open-file-output-port junk (file-options no-fail))))
  (put-bytevector p (u8-list->bytevector '(200 201 202 203)))
  (close-port p))
(ok "an unparseable boot scans as #f" (eq? (bld-boot-max-lz4-entry junk) #f))
(ok "an unparseable boot is not treated as over the ceiling"
    (not (bld-boot-over-lz4-ceiling? junk)))

;; --- the fallback itself, driven by a ceiling this gate can reach ------------
;; bld-vfasl-convert! is what `jolt build` calls, and its gzip arm only ever runs
;; for an image no gate can afford to build. Lowering the ceiling under it puts
;; the small probe boot "over" and exercises the same decision, note and all.
(define fallback-boot (at "fallback.boot"))
(define default-boot (at "default.boot"))
(ok "under the ceiling, bld-vfasl-convert! leaves the boot on LZ4"
    (and (bld-vfasl-convert! probe-so default-boot)
         (> (bld-boot-max-lz4-entry default-boot) 0)))
(ok "over the ceiling, bld-vfasl-convert! re-encodes off LZ4"
    (parameterize ((bld-lz4-image-ceiling 1024))
      (and (bld-vfasl-convert! probe-so fallback-boot)
           (= (bld-boot-max-lz4-entry fallback-boot) 0))))

(printf "\nvfasl ceiling gate: ~a/~a passed~a\n"
        (- total fails) total (if (= fails 0) "" (format " (~a failed)" fails)))
(exit (if (= fails 0) 0 1))
