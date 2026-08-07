;; gen-records.ss — generate host/gambit/records-gambit.ss from
;; host/chez/records.ss. Run on CHEZ via `make gambitgen`:
;;   chez --script host/gambit/gen-records.ss
;;
;; WHY: records.ss's define-jrec-family is a PROCEDURAL transformer whose body
;; calls helper procedures at expansion time. Gambit expands a whole ##include
;; unit before evaluating any of it, so those helpers are unbound when the
;; expander reaches the macro's use — the same phase wall as with-syntax. The
;; expansion itself is pure data, so this script produces it ON CHEZ: it reads
;; records.ss as data, evals the transformer lambda, applies it to the use
;; form, and writes every records.ss form verbatim with the macro definition
;; dropped and each use replaced by its expansion. records-gambit.ss is
;; GENERATED, DERIVED single-source output (the seed-mint pattern) — never
;; hand-edit it; regenerate when records.ss changes.

(import (chezscheme))

;; Gambit does not read Chez-style brackets — emit parens only.
(print-brackets #f)

(define src "host/chez/records.ss")
(define out "host/gambit/records-gambit.ss")

(define (read-all f)
  (with-input-from-file f
    (lambda ()
      (let loop ((acc '()))
        (let ((x (read)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

(define forms (read-all src))

;; the transformer lambda from (define-syntax define-jrec-family (lambda (x) ...))
(define transformer
  (let loop ((fs forms))
    (cond
      ((null? fs) (error 'gen-records "define-jrec-family not found in" src))
      ((and (pair? (car fs))
            (eq? (caar fs) 'define-syntax)
            (eq? (cadar fs) 'define-jrec-family))
       (eval (caddar fs)))
      (else (loop (cdr fs))))))

(define (expand-use form)
  ;; apply the transformer to the use as a syntax object; syntax->datum of the
  ;; result is the clean (begin (define-record-type ...) ...) — no lowering.
  (syntax->datum (transformer (datum->syntax #'here form))))

(define port (open-output-file out 'replace))
(put-string port ";; records-gambit.ss — GENERATED from host/chez/records.ss by\n")
(put-string port ";; host/gambit/gen-records.ss (make gambitgen). Do not edit; regenerate\n")
(put-string port ";; when records.ss changes. The define-jrec-family transformer is\n")
(put-string port ";; expansion-phase-hostile on Gambit; its uses are pre-expanded here.\n\n")
(for-each
  (lambda (f)
    (cond
      ((and (pair? f) (eq? (car f) 'define-syntax) (eq? (cadr f) 'define-jrec-family))
       (put-string port ";; (define-syntax define-jrec-family ...) — pre-expanded below\n\n"))
      ((and (pair? f) (eq? (car f) 'define-jrec-family))
       (put-string port ";; expansion of ")
       (write f port)
       (put-string port "\n")
       (for-each (lambda (g) (pretty-print g port) (newline port))
                 (cdr (expand-use f))))   ; drop the begin head
      (else (pretty-print f port) (newline port))))
  forms)
(close-port port)
(display (string-append "gen-records: wrote " out "\n"))
