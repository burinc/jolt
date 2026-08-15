;; gen-records.ss — generate host/gambit/records-gambit.ss from the four
;; host/chez records files (records.ss, records-coll.ss, protocols.ss,
;; records-dispatch.ss). Run on CHEZ via `make gambitgen`:
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

;; The records subsystem is four chez files, concatenated here in their rt.ss
;; load order — the single gambit include preserves the total form order.
(define srcs '("host/chez/records.ss"
               "host/chez/records-coll.ss"
               "host/chez/protocols.ss"
               "host/chez/records-dispatch.ss"))
;; GEN_RECORDS_OUT redirects the write, which is what `make gambitgencheck` uses
;; to generate into a temp file and diff against the committed one.
(define out (or (getenv "GEN_RECORDS_OUT") "host/gambit/records-gambit.ss"))

(define (read-all f)
  (with-input-from-file f
    (lambda ()
      (let loop ((acc '()))
        (let ((x (read)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

(define forms (apply append (map read-all srcs)))

;; the transformer lambda from (define-syntax define-jrec-family (lambda (x) ...))
(define transformer
  (let loop ((fs forms))
    (cond
      ((null? fs) (error 'gen-records "define-jrec-family not found in" srcs))
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
(put-string port ";; records-gambit.ss — GENERATED from host/chez/{records,records-coll,\n")
(put-string port ";; protocols,records-dispatch}.ss by host/gambit/gen-records.ss (make\n")
(put-string port ";; gambitgen). Do not edit; regenerate when any of the four changes. The\n")
(put-string port ";; define-jrec-family transformer is expansion-phase-hostile on Gambit;\n")
(put-string port ";; its uses are pre-expanded here.\n\n")
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
