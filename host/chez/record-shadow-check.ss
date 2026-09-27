;; record-shadow-check.ss — a top-level define that replaces a record's own name.
;;
;; The Chez host files load into ONE top-level environment, where a later
;; (define (x ...)) silently rebinds an x an earlier define-record-type made. When
;; x is an accessor, every caller that meant the field gets the new procedure
;; instead. The fiber record's `waiter` field was the case that made this a
;; gate: fibers-async.ss already had (define (jolt-fiber-waiter f) ...) building
;; an alt handler, so each read of the field allocated a fresh handler, and an
;; interrupt claimed that instead of the wait the fiber was parked on. Nothing
;; failed; the fiber happened to claim its own wait on the way out.
;;
;; Checked: every name a define-record-type in a handwritten Chez host file
;; generates (constructor, predicate, accessors, mutators) against every
;; top-level define in those files.
;;
;; Modes:
;;   (default)  gate — exit 1 on any collision
;;   --list     print the record names it collected, exit 0
(import (chezscheme))
(include "host/chez/gate-scan-lib.ss")

(define (host-file? path)
  (and (gs-string-suffix? ".ss" path)
       (not (gs-string-contains? path "/seed/"))
       (not (gs-string-contains? path "/stub/"))
       (not (gs-string-contains? path "-test.ss"))
       (not (gs-string-contains? path "-check.ss"))
       (not (gs-string-contains? path "/run-"))
       (not (gs-string-contains? path "/gate-"))))

(define (sym-append . parts)
  (string->symbol
    (apply string-append
           (map (lambda (p) (if (symbol? p) (symbol->string p) p)) parts))))

;; The names (define-record-type spec clause ...) binds, R6RS defaults included.
(define (record-names form)
  (let* ((spec (cadr form))
         (name (if (pair? spec) (car spec) spec))
         (acc (if (pair? spec)
                  (list (cadr spec) (caddr spec))
                  (list (sym-append "make-" name) (sym-append name "?")))))
    (for-each
      (lambda (clause)
        (when (and (pair? clause) (eq? (car clause) 'fields))
          (for-each
            (lambda (f)
              (cond
                ((symbol? f) (set! acc (cons (sym-append name "-" f) acc)))
                ((and (pair? f) (eq? (car f) 'immutable))
                 (set! acc (cons (if (pair? (cddr f)) (caddr f) (sym-append name "-" (cadr f))) acc)))
                ((and (pair? f) (eq? (car f) 'mutable))
                 (set! acc (cons (if (pair? (cddr f)) (caddr f) (sym-append name "-" (cadr f))) acc))
                 (set! acc (cons (if (and (pair? (cddr f)) (pair? (cdddr f)))
                                     (cadddr f)
                                     (sym-append name "-" (cadr f) "-set!"))
                                 acc)))))
            (cdr clause))))
      (cddr form))
    acc))

;; Top-level forms, looking through (begin ...), which is still top level.
(define (walk-top forms proc)
  (for-each
    (lambda (d)
      (if (and (pair? d) (eq? (car d) 'begin))
          (walk-top (cdr d) proc)
          (proc d)))
    forms))

(define generated (make-eq-hashtable))   ; name -> file of its record
(define defined '())                     ; (name . file) per top-level define

(gs-walk-files "host/chez"
  (lambda (path)
    (when (host-file? path)
      (walk-top (gs-read-forms path)
        (lambda (d)
          (when (pair? d)
            (case (car d)
              ((define-record-type)
               (for-each (lambda (n) (hashtable-set! generated n path)) (record-names d)))
              ((define)
               (when (pair? (cdr d))
                 (let ((head (cadr d)))
                   (let ((n (if (pair? head) (car head) head)))
                     (when (symbol? n) (set! defined (cons (cons n path) defined))))))))))))))

(define list-mode? (member "--list" (cdr (command-line))))

(if list-mode?
    (begin
      (vector-for-each
        (lambda (n) (printf "~a  ~a\n" n (hashtable-ref generated n #f)))
        (vector-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                     (hashtable-keys generated)))
      (exit 0))
    (let ((hits (filter (lambda (p) (hashtable-ref generated (car p) #f)) defined)))
      (for-each
        (lambda (p)
          (printf "  FAIL: ~a (~a) redefines the record name from ~a\n"
                  (car p) (cdr p) (hashtable-ref generated (car p) #f)))
        hits)
      (if (null? hits)
          (begin (printf "OK: no top-level define shadows a record's name (~a names)\n"
                         (hashtable-size generated))
                 (exit 0))
          (exit 1))))
