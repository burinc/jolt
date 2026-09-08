;; vfasl-ceiling-test.ss — the boot image's LZ4 ceiling (jolt-lang/jolt#886).
;;
;; A compressed fasl entry big enough cannot be read back when the entry is LZ4:
;; c/new-io.c's S_bytevector_uncompress returns the length as `Sfixnum(r)` with
;; `int r`, and Sfixnum multiplies by 8 in the argument's own type, so the
;; product leaves 32 bits and c/fasl.c's length check can never match. A binary
;; whose boot image is over the line dies inside Sbuild_heap before a line of its
;; own code runs. gzip's arm of the same function hands zlib a uLong and has no
;; ceiling.
;;
;; WHERE the line falls is undefined behaviour and differs by platform: 2^28
;; where the widened product keeps its sign (the reporter's ta6le), 2^29 where
;; it does not (tarm64osx). jolt re-encodes at 2^28, at or below both, so this
;; gate measures the kernel in front of it rather than asserting one number.
;;
;; That only became reachable in 0.8.5, which ships the boot as vfasl: a plain
;; boot is one compressed entry per top-level form and its entries are kilobytes,
;; while vfasl-convert-file combines each input boot file into ONE entry — so the
;; app half of a large program is a single image that stops loading rather than
;; merely loading slowly.
;;
;; jolt cannot patch the kernel it links against, so build.ss measures the
;; converted boot and re-encodes over-ceiling images with gzip. This gate pins
;; what that fix rests on:
;;
;;   a. a ceiling still exists, and jolt's constant sits at or below it while
;;      staying high enough that everything under it loads — no ceiling found at
;;      all means a newer Chez fixed the overflow and the workaround can go
;;   b. gzip clears the size that defeated LZ4, so it is a valid answer
;;   c. the entry scanner reads real converted boots correctly, answers 0 for a
;;      boot with no LZ4 entries at all, and trips at exactly jolt's constant
;;   d. both fallbacks run: bld-vfasl-convert! in process, and bld-vfasl-ensure!
;;      for the paths that convert in a spawned Chez (build-with-cc,
;;      build-shared, and every cross build)
;;
;; (a) and (b) allocate bytevectors of the measured ceiling; the Makefile target
;; runs this with JOLT_MAX_HEAP=off so the runtime's own heap bound does not fire
;; first.
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
;; Drive the REAL site: a compressed fasl ENTRY, written and read back through
;; c/fasl.c's fasl_entry, which is where the length comparison that gives out
;; lives. All-zero bytes so the compressor is fast and the file stays ~1MB: what
;; is under test is the LENGTH the kernel reports back, not the codec's ratio.
(define (fasl-round-trips? fmt n)
  (let ((path (at (format "probe-~a-~a.fasl" fmt n))))
    (guard (e (#t #f))
      (parameterize ((fasl-compressed #t) (compress-format fmt) (compress-level 'minimum))
        (let ((p (open-file-output-port path (file-options no-fail))))
          (fasl-write (make-bytevector n 0) p)
          (close-port p)))
      (let* ((p (open-file-input-port path))
             (v (fasl-read p)))
        (close-port p)
        (= n (bytevector-length v))))))

;; The ceiling is UNDEFINED BEHAVIOUR, and it does not land in the same place on
;; every platform. Sfixnum(x) is ((ptr)(uptr)((x)*8)) over an `int`: the product
;; leaves 32 bits at x = 2^28, and what the widening cast then does with the top
;; bit is the C compiler's business. Both manifestations are real, on Chez 10.4.1:
;;
;;   sign-extended   length comes back NEGATIVE at 2^28     ceiling 2^28
;;                   (ta6le, and the platform in jolt-lang/jolt#886 — its
;;                    -222298112 is exactly 314572800*8 wrapped to signed
;;                    32-bit and divided back by 8)
;;   zero-extended   length comes back 0 at 2^29            ceiling 2^29
;;                   (tarm64osx)
;;
;; So this MEASURES the ceiling of the kernel in front of it rather than
;; asserting one platform's number — an equality on 2^28 is red on tarm64osx,
;; where it reads as "Chez fixed the overflow" when Chez has done nothing of the
;; kind. What gets asserted instead is the property that keeps binaries working.
(define (measured-lz4-ceiling)
  (let loop ((cands (list (expt 2 28) (expt 2 29))))
    (cond ((null? cands) #f)
          ((not (fasl-round-trips? 'lz4 (car cands))) (car cands))
          (else (loop (cdr cands))))))
(define lz4-ceiling (measured-lz4-ceiling))
(printf "  measured LZ4 fasl ceiling on ~a: ~a (jolt re-encodes at ~a)\n"
        (machine-type) (or lz4-ceiling "none at or below 2^29") (bld-lz4-image-ceiling))

;; The check that must keep FINDING a ceiling. If no probe fails, the Chez being
;; built against has fixed S_bytevector_uncompress, and the whole workaround —
;; the gzip arms of bld-vfasl-convert! and bld-vfasl-ensure!, the entry scanner,
;; this gate — can be deleted. That is a "drop the workaround" signal, not a
;; regression.
(ok "the LZ4 fasl ceiling is still there"
    (and lz4-ceiling #t))
;; The safety invariant the fix rests on: jolt re-encodes at or before the point
;; where the kernel gives out, so no image it leaves on LZ4 is one that cannot
;; be read back.
(ok "jolt's ceiling is at or below the kernel's"
    (and lz4-ceiling (<= (bld-lz4-image-ceiling) lz4-ceiling)))
;; The other half of that invariant: jolt's constant must not be so HIGH that a
;; doomed image slips under it. Everything below it has to load.
(ok "lz4 loads one byte under jolt's ceiling"
    (fasl-round-trips? 'lz4 (- (bld-lz4-image-ceiling) 1)))
;; gzip is what the fallback re-encodes to, so it has to clear the size that
;; defeated LZ4.
(ok "gzip loads at the measured ceiling"
    (and lz4-ceiling (fasl-round-trips? 'gzip lz4-ceiling)))

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

;; --- c: the ceiling branch, without building an over-ceiling app ------------
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

;; --- d: the spawned-script path (build-with-cc, build-shared, every cross) ----
;; Those paths convert inside a compile script run under bld-system, which turns
;; a non-zero exit into a dead build. So what they hand the codec decision is a
;; STRING, and the only thing between a conversion that raises and a failed build
;; is that the form is guarded. Nothing else pins this: build-smoke drives the
;; self-contained binary, which takes the in-process path instead.
(define (substring? needle hay)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))
(define (script-form-for mode)
  (parameterize ((bld-boot-mode mode))
    (bld-vfasl-script-form "/tmp/in.boot" "/tmp/out.vfasl")))

(ok "'plain emits no conversion at all"
    (string=? (script-form-for 'plain) ""))
(ok "'fast emits a conversion on the default codec"
    (let ((s (script-form-for 'fast)))
      (and (substring? "vfasl-convert-file" s)
           (not (substring? "compress-format" s)))))
(ok "'small emits the gzip codec"
    (let ((s (script-form-for 'small)))
      (and (substring? "vfasl-convert-file" s)
           (substring? "(compress-format 'gzip)" s))))
;; the guard is the whole point: without it a target that cannot vfasl takes the
;; build down instead of falling back to the plain boot.
(ok "a conversion that raises cannot kill the build"
    (let ((s (script-form-for 'fast)))
      (and (substring? "guard" s) (substring? "delete-file" s))))

;; bld-vfasl-ensure! for real, in a spawned Chez, over all three of its arms.
(define ensure-over (at "ensure-over.vfasl"))
(ok "ensure! re-encodes an over-ceiling image the script produced"
    (parameterize ((bld-lz4-image-ceiling 1024))
      (and (sa-vfasl-convert-file probe-so ensure-over)     ; stand in for the script's LZ4 result
           (bld-vfasl-ensure! tmp probe-so ensure-over)
           (= (bld-boot-max-lz4-entry ensure-over) 0))))
(define ensure-under (at "ensure-under.vfasl"))
(ok "ensure! leaves an under-ceiling image alone"
    (and (sa-vfasl-convert-file probe-so ensure-under)
         (bld-vfasl-ensure! tmp probe-so ensure-under)
         (> (bld-boot-max-lz4-entry ensure-under) 0)))
;; The arm the cc path had no answer for: the script's conversion raised, so
;; there is no image at all. It retries under gzip rather than dying.
(define ensure-missing (at "ensure-missing.vfasl"))
(when (file-exists? ensure-missing) (delete-file ensure-missing))
(ok "ensure! retries a conversion that produced nothing"
    (and (bld-vfasl-ensure! tmp probe-so ensure-missing)
         (file-exists? ensure-missing)))
;; …and when even that cannot produce one, it answers #f so the caller keeps the
;; plain boot, instead of raising and taking the build with it.
(ok "ensure! answers #f rather than raising when no image is possible"
    (not (bld-vfasl-ensure! tmp (at "no-such-input.so") (at "no-such-output.vfasl"))))

(printf "\nvfasl ceiling gate: ~a/~a passed~a\n"
        (- total fails) total (if (= fails 0) "" (format " (~a failed)" fails)))
(exit (if (= fails 0) 0 1))
