;; vfasl-shared-strings-test.ss — equal string constants share one object in a
;; vfasl image (jolt-50zg, host/chez/chez-patches/0004-vfasl-share-strings.patch).
;;
;; compile-file writes one fasl entry per top-level form, and every literal in
;; them is its own object, so a built app's heap held 44k strings with 27k
;; distinct values: 788 copies of "clojure.core", 265 of "jolt.host", 67 of a
;; message Chez's own foreign-procedure expansion carries. The boot is converted
;; to vfasl, which combines those entries into one image, and the patched
;; converter keeps the first string of each content and points the rest at it.
;;
;; The rows, over a unit compiled and converted the way build.ss converts an app
;; unit (sa-vfasl-convert-object-file):
;;   a. two literals in different top-level forms are one object after loading
;;      the vfasl unit, and three forms share one too
;;   b. the plain fasl of the same unit loads them as separate objects — what
;;      the patch changes, and the proof that (a) measures the converter
;;   c. sharing keeps a string's mutability, and different contents stay apart
;;
;; (a) needs the patched kernel. On a stock one it reports and passes, unless
;; JOLT_REQUIRE_LOCKFREE_CHEZ=1 says the kernel must carry jolt's patches (CI).
;;
;;   chez --script test/chez/vfasl-shared-strings-test.ss
(import (chezscheme))

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (if pred (printf "PASS: ~a\n" name)
      (begin (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name))))

(define tmp "target/vfasl-shared-strings-gate")
(unless (file-exists? "target") (mkdir "target"))
(unless (file-exists? tmp) (mkdir tmp))
(define (at name) (string-append tmp "/" name))

(define src (at "probe.ss"))
(define so (at "probe.so"))
(define vso (at "probe.vso"))
(for-each (lambda (f) (when (file-exists? f) (delete-file f))) (list src so vso))

(with-output-to-file src
  (lambda ()
    (for-each (lambda (form) (write form) (newline))
      '((define vss-a "vss-shared-probe")
        (define (vss-b) "vss-shared-probe")
        (define vss-c (list "vss-shared-probe" "vss-other-probe"))
        (define vss-d "vss-other-probe")))))

(parameterize ((current-output-port (open-output-string)))
  (compile-file src so))
(vfasl-convert-file so vso #f)

;; --- b: the plain fasl -------------------------------------------------------
(load so)
(ok "plain fasl: literals of separate forms are separate objects"
    (not (eq? vss-a (vss-b))))

;; --- a/c: the vfasl image ----------------------------------------------------
(load vso)
(define shared? (eq? vss-a (vss-b)))
(define patched? (foreign-entry? "(cs)lockfree_activation"))
(define required? (equal? (getenv "JOLT_REQUIRE_LOCKFREE_CHEZ") "1"))
(cond
  ((or patched? required?)
   (ok "vfasl: two forms' equal literals are one object" shared?)
   (ok "vfasl: a third form's literal is that object too" (eq? vss-a (car vss-c))))
  (else
   (printf "vfasl-shared-strings: stock Chez kernel (shared: ~a), sharing not checked\n" shared?)))
(ok "vfasl: the shared literal keeps its value" (string=? vss-a "vss-shared-probe"))
(ok "vfasl: sharing keeps mutability" (not (immutable-string? vss-a)))
(ok "vfasl: different contents stay different objects" (not (eq? vss-a vss-d)))
(ok "vfasl: the other content is shared too"
    (or (not (or patched? required?)) (eq? vss-d (cadr vss-c))))

(printf "vfasl-shared-strings: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
