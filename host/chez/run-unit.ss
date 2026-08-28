;; run-unit.ss — host-specific unit gate.
;;
;; Loads the checked-in seed + spine, reads test/chez/unit.edn, and for each case
;; evaluates :expr (wrapped in (do ...), as `jolt -e` does) and compares its PRINTED
;; value (jolt-repl-str, the readable `-e` printer — an :expected string for a
;; string result therefore carries its quotes) to the literal :expected string.
;; :expected :throws asserts
;; the case raises. These cover host-specific behavior (dot-forms, java statics, io,
;; reader, walk, …) that isn't in the JVM-portable corpus. Global state is reset
;; between cases for per-case isolation.
;;
;;   chez --script host/chez/run-unit.ss
(import (chezscheme))

(load "host/chez/run-gate-harness.ss")
;; The loader + install source roots, so a row's (require 'stdlib.ns) resolves the
;; .clj overlay from source exactly like jolt — without this, a require of a ns
;; whose NATIVE vars exist (e.g. clojure.core.async) silently no-ops via the
;; ns-has-vars? arm and the overlay fns are missing at analysis.
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
;; The base java.time API (stdlib/jolt/time) autoloads on first java.time.* use at
;; runtime; here we load it once BEFORE the per-case snapshot below so its
;; value-semantics arms (impl/install-seams!) and class registrations are part of
;; the stable base world. Otherwise the first java.time case would install those
;; arms after the snapshot, and zj-reset! — which prunes vars but can't unregister
;; a Scheme-level arm — would leave them dangling and break later cases. (Cold
;; autoload is covered per-process by the smoke gate.)
(load-namespace "jolt.time.base")

(define (slurp path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((cs '()) (c (read-char p)))
        (if (eof-object? c) (list->string (reverse cs))
            (loop (cons c cs) (read-char p)))))))

(define cases (jolt-read-string (slurp "test/chez/unit.edn")))
(define kw-suite    (keyword #f "suite"))
(define kw-expr     (keyword #f "expr"))
(define kw-expected (keyword #f "expected"))
(define kw-throws   (keyword #f "throws"))

(load "host/chez/run-case-isolation.ss")

;; --- run ------------------------------------------------------------------------
(define pass 0)
(define fails '())              ; (suite expr msg)
(define suite-pass (make-hashtable string-hash string=?))
(define suite-total (make-hashtable string-hash string=?))
(define (bump! ht k) (hashtable-set! ht k (+ 1 (hashtable-ref ht k 0))))

(let loop ((i 0))
  (when (< i (pvec-count cases))
    (let* ((row (pvec-nth-d cases i jolt-nil))
           (suite (jolt-get row kw-suite))
           (expr (jolt-get row kw-expr))
           (expected (jolt-get row kw-expected))
           (throws? (eq? expected kw-throws))
           (sink (open-output-string)))
      (bump! suite-total suite)
      (guard (e (#t (if throws?
                        (begin (set! pass (+ pass 1)) (bump! suite-pass suite))
                        (set! fails (cons (list suite expr "raised") fails)))))
        (let ((got (jolt-repl-str
                     (parameterize ((current-output-port sink))
                       (jolt-compile-eval (string-append "(do " expr ")") "user")))))
          (cond
            (throws? (set! fails (cons (list suite expr (string-append "expected throw; got " got)) fails)))
            ((string=? got expected) (begin (set! pass (+ pass 1)) (bump! suite-pass suite)))
            (else (set! fails (cons (list suite expr
                    (string-append "want `" expected "` got `" got "`")) fails))))))
      (zj-reset!))
    (loop (+ i 1))))

(printf "\nunit gate: ~a/~a passed\n" pass (pvec-count cases))
(let-values (((ks vs) (hashtable-entries suite-total)))
  (for-each (lambda (p)
              (printf "  ~a/~a  ~a\n" (hashtable-ref suite-pass (car p) 0) (cdr p) (car p)))
            (list-sort (lambda (a b) (string<? (car a) (car b)))
                       (vector->list (vector-map cons ks vs)))))
(when (> (length fails) 0)
  (printf "\n~a FAIL(s):\n" (length fails))
  (for-each (lambda (f) (printf "  [~a] ~a\n    ~a\n" (car f) (caddr f) (cadr f)))
            (list-head (reverse fails) (min 40 (length fails)))))
(flush-output-port)
(exit (if (> (length fails) 0) 1 0))
