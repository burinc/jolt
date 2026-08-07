;; gen-eval-syntax.ss — generate host/gambit/eval-syntax.ss from the
;; define-syntax forms in host/chez/seq.ss. Run on CHEZ via `make gambitseed`
;; (bundled with the seed mint):
;;   chez --script host/gambit/gen-eval-syntax.ss
;;
;; WHY: the backend emits references to seq.ss's syntax-rules macros
;; (jolt-n+/n-/n*/n/ checked arithmetic, the jolt-l* long ops). On Chez a
;; top-level define-syntax lands in the interaction environment, so runtime
;; (eval emitted-code) expands them. On Gambit the boot unit's macros are
;; invisible to eval — eval'd code is its own unit. This generated file
;; re-registers each macro INTO the interaction environment via eval, at boot,
;; with the forms baked as data (no runtime file reads — the js target has no
;; filesystem). Regenerate when seq.ss's macros change.

(import (chezscheme))
(print-brackets #f)

(define src "host/chez/seq.ss")
(define out "host/gambit/eval-syntax.ss")

(define (read-all f)
  (with-input-from-file f
    (lambda ()
      (let loop ((acc '()))
        (let ((x (read)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

;; Both the define-syntax forms AND top-level USES of the macros they define
;; (define-n-cmp generates further define-syntax forms — its uses must replay
;; in the interaction environment too, in file order).
(define all-forms (read-all src))
(define syntax-names
  (map cadr (filter (lambda (f) (and (pair? f) (eq? (car f) 'define-syntax)))
                    all-forms)))
(define syntax-forms
  (filter (lambda (f)
            (and (pair? f)
                 (or (eq? (car f) 'define-syntax)
                     (memq (car f) syntax-names))))
          all-forms))

(define port (open-output-file out 'replace))
(put-string port ";; eval-syntax.ss — GENERATED from host/chez/seq.ss by\n")
(put-string port ";; host/gambit/gen-eval-syntax.ss (make gambitseed). Do not edit.\n")
(put-string port ";; Registers seq.ss's emit-referenced macros into the interaction\n")
(put-string port ";; environment so runtime-eval'd compiled code expands them (Gambit\n")
(put-string port ";; eval does not see the boot unit's syntax definitions).\n\n")
(for-each
  (lambda (f)
    (put-string port "(eval '")
    (pretty-print f port)
    (put-string port " (interaction-environment))\n\n"))
  syntax-forms)
(close-port port)
(display (string-append "gen-eval-syntax: wrote " out " ("
                        (number->string (length syntax-forms)) " macros)\n"))
