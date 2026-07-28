;; aot-fingerprint-test.ss — the AOT cache's content hash and the two runtime
;; fingerprints built on it.
;;
;; The cache keys fasls on source content, and the generation directory keys on
;; the runtime that emitted them. Both used to fold in Chez's equal-hash, which
;; is NOT a content hash: it samples ~26 characters of a string no matter how
;; long the string is (first 6, ~15 strided, last 5). Length was doing all the
;; real invalidation work, so any length-preserving edit — 42→99, <→>, inc→dec,
;; an equal-length rename — kept the key and silently served the previous fasl.
;;
;; aot-cache-smoke.sh covers the per-namespace key end to end. This gate covers
;; the two things that file cannot reach cheaply: the hash's own byte coverage
;; (case a is the property everything else rests on — under equal-hash it fails
;; ~4000 times over), and the two runtime fingerprints, which otherwise need a
;; full jolt rebuild to exercise.
;;
;;   chez --script test/chez/aot-fingerprint-test.ss
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

;; pid-unique so parallel `make -j` runs can't collide; tracked so the run cleans
;; up after itself rather than littering /tmp on every CI build.
(define tmpdirs '())
(define (tmpdir)
  (let ((d (string-append "/tmp/jolt-fp-test-" (number->string (get-process-id))
                          "-" (number->string (length tmpdirs)))))
    (aot-mkdir-p d)
    (set! tmpdirs (cons d tmpdirs))
    d))
(define (cleanup!) (for-each aot-delete-tree tmpdirs))
(define (spit path s)
  (let ((p (open-output-file path 'replace))) (put-string p s) (close-port p)))
(define (slurp path)
  (let* ((p (open-input-file path)) (s (get-string-all p)))
    (close-port p) (if (eof-object? s) "" s)))
(define (contains? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

;; --- (a) every byte contributes ----------------------------------------------
;; The property the whole cache rests on. Walk a realistically-sized source and
;; flip ONE character at each offset in turn: every single-character edit must
;; move the hash. equal-hash saw 26 of these ~4096 offsets; the other ~4070 edits
;; produced an identical key and served stale code.
(let* ((n 4096)
       (base (make-string n #\a))
       (bh (aot-content-hash base))
       (blind (let loop ((i 0) (acc '()))
                (if (= i n) (reverse acc)
                    (let ((s (make-string n #\a)))
                      (string-set! s i #\Z)
                      (loop (+ i 1) (if (= (aot-content-hash s) bh) (cons i acc) acc)))))))
  (ok (string-append "(a) every byte of a " (number->string n)
                     "-char source affects the hash"
                     (if (null? blind) ""
                         (string-append " — BLIND at " (number->string (length blind))
                                        " offsets, first " (number->string (car blind)))))
      (null? blind)))

;; --- (b) reproducible across processes ---------------------------------------
;; The key is a filename: if the hash drifted between runs or machines the cache
;; would miss every time and silently degrade to "no cache" rather than fail.
;; Pinned vectors, so a rewrite that changes the algorithm has to say so here.
(ok "(b) hash of \"\" is the FNV-1a offset basis"
    (= (aot-content-hash "") 2166136261))
(ok "(b) hash of \"jolt\" matches its pinned vector"
    (= (aot-content-hash "jolt") 3776321102))
(ok "(b) hash of a longer pinned string matches"
    (= (aot-content-hash "jolt aot cache fingerprint vector") 955009679))

;; --- (c) the namespace key moves on a mid-file same-length edit ---------------
;; aot-cache-key is length + content hash. Length alone cannot see this edit.
(let* ((pad (make-string 2000 #\space))
       (src1 (string-append "(ns a.b)" pad "(defn f [] 42)" pad))
       (src2 (string-append "(ns a.b)" pad "(defn f [] 99)" pad)))
  (ok "(c) aot-cache-key differs for a mid-file same-length edit"
      (and (= (string-length src1) (string-length src2))
           (not (string=? (aot-cache-key src1) (aot-cache-key src2))))))

;; --- (d) the source-tree runtime fingerprint ---------------------------------
;; Running from a checkout there is no baked fingerprint, so the generation dir
;; is keyed on a hash of the runtime sources on disk. A same-length edit to one
;; of them has to start a new generation — otherwise the new runtime loads the
;; old one's fasls. aot-source-fingerprint reads aot-runtime-source-dirs relative
;; to the cwd, so a synthetic tree exercises the real function.
;; ONE character at a mid-file offset, not a bulk rewrite: a bulk change is
;; caught even by a sampling hash, so a fixture built that way passes without
;; the fix and proves nothing. Offset 1500 of ~3023 is outside every offset
;; equal-hash looks at, which is what makes this gate real.
(define (fp-body flip?)
  (let ((s (string-copy (string-append ";; " (make-string 3000 #\x)
                                       "\n(define answer 42)\n"))))
    (when flip? (string-set! s 1500 #\y))
    s))
(let* ((root (tmpdir))
       (hc (string-append root "/host/chez"))
       (f (string-append hc "/fake-runtime.ss")))
  (aot-mkdir-p (string-append hc "/java"))
  (aot-mkdir-p (string-append hc "/seed"))
  (spit f (fp-body #f))
  (let* ((cwd (current-directory))
         (fp1 (begin (current-directory root) (aot-source-fingerprint)))
         (fp2 (begin (spit f (fp-body #t)) (aot-source-fingerprint))))
    (current-directory cwd)
    (ok "(d) aot-source-fingerprint moves on a one-character runtime edit"
        (and (string? fp1) (string? fp2)
             (= (string-length (fp-body #f)) (string-length (fp-body #t)))
             (not (string=? fp1 fp2))))))

;; --- (e) the baked runtime fingerprint (build.ss) -----------------------------
;; A built binary bakes a fingerprint of its own emitted image, because the
;; version string does not pin a runtime: `git describe` reports the same
;; "…-dirty" for every build out of one working tree. Two builds whose flat.ss
;; differs only by a same-length change must not land in one generation, or each
;; happily loads the other's output. bld-prepend-prologue! is the real emitter.
(let* ((d (tmpdir))
       (a (string-append d "/flat-a.ss"))
       (b (string-append d "/flat-b.ss"))
       ;; readable Scheme (bld-kernel-prologue reads forms), differing by ONE
       ;; character deep inside a string literal. Same reasoning as (d): a bulk
       ;; rewrite would pass even against a sampling hash.
       (mk (lambda (flip?)
             (let ((s (string-copy (string-append "(define pad \"" (make-string 3000 #\x)
                                                  "\")\n(define answer 42)\n"))))
               (when flip? (string-set! s 1500 #\y))
               s)))
       (baked (lambda (path)
                (let* ((s (slurp path))
                       (marker "(define jolt-baked-runtime-fingerprint ")
                       (i (let loop ((i 0))
                            (cond ((> (+ i (string-length marker)) (string-length s)) #f)
                                  ((string=? (substring s i (+ i (string-length marker))) marker)
                                   (+ i (string-length marker)))
                                  (else (loop (+ i 1)))))))
                  (and i (let loop ((j i))
                           (if (char=? (string-ref s j) #\)) (substring s i j)
                               (loop (+ j 1)))))))))
  (spit a (mk #f))
  (spit b (mk #t))
  (bld-prepend-prologue! a)
  (bld-prepend-prologue! b)
  (let ((fa (baked a)) (fb (baked b)))
    (ok "(e) build.ss bakes a fingerprint at all" (and fa fb #t))
    (ok "(e) baked fingerprint differs on a one-character flat.ss edit"
        (and fa fb
             (= (string-length (mk #f)) (string-length (mk #t)))
             (not (string=? fa fb))))))

;; --- (f) build-jolt.ss keys on the same hash ---------------------------------
;; build-jolt.ss bakes the jolt binary's own fingerprint with an inline
;; expression, not a callable function, so this is a drift guard: it must fold in
;; aot-content-hash, and must not have drifted back to equal-hash.
(let ((s (slurp "host/chez/build-jolt.ss")))
  (ok "(f) build-jolt.ss fingerprint uses aot-content-hash"
      (contains? s "(number->string (aot-content-hash src) 16)"))
  (ok "(f) build-jolt.ss fingerprint no longer uses equal-hash"
      (not (contains? s "(number->string (equal-hash src) 16)"))))

(cleanup!)
(printf "\naot fingerprint: ~a passed, ~a failed\n" (- total fails) fails)
(when (> fails 0) (exit 1))
