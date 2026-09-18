;; Every clojure.core fn must be NAMEABLE in value position. Run:
;;   chez --script test/chez/core-proc-name-test.ss
;;
;; A core fn used as a VALUE — (tree-seq branch? seq root), (map seq colls),
;; (sorted-map-by >) — compiles to the runtime's own Scheme procedure, not to the
;; var's root. The state image writes a procedure as its var NAME, and def-var!
;; records that name for the procedure it was handed. When a native is
;; set!-EXTENDED afterwards (lazy-bridge teaching seq about lazy seqs,
;; natives-array teaching nth about arrays, the numeric layer taking over min and
;; quot), the extension is a NEW procedure nothing named — and every value built
;; from it silently stops being writable.
;;
;; That is how seq, get, nth, peek, pop, min, max, mod, rem and quot came to be
;; unwritable while 37 of 40 fns spot-checked were fine (jolt-6cwk). The names are
;; re-registered in post-prelude.ss, after every extension has run; this gate is
;; what makes the NEXT extension that forgets fail here instead of surfacing as an
;; image that will not write.
;;
;; Swept from the var table rather than a hand-written list, so a fn added later
;; is covered without anyone remembering to add it.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; a name whose value position cannot even be EVALUATED is a macro or a special
;; form, not a fn — skipped, not failed
(define (value-of name)
  (call/cc (lambda (k)
    (with-exception-handler (lambda (e) (k 'no-value))
      (lambda () (jolt-compile-eval name "user"))))))

(define unnameable '())
(define checked 0)
(for-each
  (lambda (name)
    (let ((root (var-deref "clojure.core" name)))
      (when (procedure? root)
        (let ((v (value-of name)))
          (when (procedure? v)
            (set! checked (+ checked 1))
            (unless (proc-name-of v)
              (set! unnameable (cons name unnameable))))))))
  ;; var-table is keyed "ns/name"; take clojure.core's, unqualified
  (sort string<?
        (let loop ((ks (vector->list (hashtable-keys var-table))) (acc '()))
          (cond ((null? ks) acc)
                ((and (> (string-length (car ks)) 13)
                      (string=? (substring (car ks) 0 13) "clojure.core/"))
                 (loop (cdr ks) (cons (substring (car ks) 13 (string-length (car ks))) acc)))
                (else (loop (cdr ks) acc))))))

(ok (string-append "every core fn is nameable in value position; unnameable: "
                   (let loop ((l (sort string<? unnameable)) (acc ""))
                     (if (null? l) (if (string=? acc "") "none" acc)
                         (loop (cdr l) (string-append acc (if (string=? acc "") "" " ") (car l))))))
    (null? unnameable))

;; the shape that found it: tree-seq hands `seq` in as a value
(ok "a value-position native travels in an image"
    (zero? (jolt-count (jolt-compile-eval
                         "(jolt.host/image-scan (tree-seq vector? seq [[1] 2]))" "user"))))

(printf "core-proc-name: ~a core fns checked, ~a/~a assertions passed\n"
        checked (- total fails) total)
(exit (if (= fails 0) 0 1))
