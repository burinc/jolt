;; host/scheme-adapter/chez.ss — the Chez target's adapter for the portable
;; Scheme layer (PSL R2, epic jolt-867l).
;;
;; Role: on Chez every CONTRACT.txt name is a native, so this file adds ZERO
;; definitions and ZERO runtime cost — there is nothing to wrap and no
;; indirection for cp0 to see through. It exists to (1) document the
;; adapter's contract with the rest of the host and (2) verify, at build/gate
;; time only, that the contract file is telling the truth about this target:
;; every name it lists is actually bound in (chezscheme). A missing name is a
;; config bug (someone added an unimplementable name to CONTRACT.txt), and it
;; is reported ALL AT ONCE rather than one by one.
;;
;; This file is a gate-time script, not part of the runtime: nothing in the
;; host loads it at startup. Run it with `make adaptercheck` (chez --script).
;;
;; R3 started routing the FORBIDDEN tiers through capability entry points in
;; the RUNTIME half (host/chez/scheme-adapter-runtime.ss — the system tier:
;; process/GC/clock); R4-R9 route the rest (ffi, eval/compile, fasl,
;; introspection, Chez-only list/vector odds). The assertion pass loads that
;; runtime file at gate time so the capability-system names are probed too.
(import (chezscheme))

;; ---- minimal line parsing, self-contained (mirrors portability-check.ss) ----

(define (char-ws? c)
  (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline)
      (char=? c #\return)))

(define (string->tokens s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (cond
        ((>= i n) (reverse acc))
        ((char-ws? (string-ref s i)) (loop (+ i 1) acc))
        (else
         (let scan ((j i))
           (if (and (< j n) (not (char-ws? (string-ref s j))))
               (scan (+ j 1))
               (loop j (cons (substring s i j) acc)))))))))

(define (strip-comment s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond
        ((>= i n) s)
        ((or (char=? (string-ref s i) #\#) (char=? (string-ref s i) #\;))
         (substring s 0 i))
        (else (loop (+ i 1)))))))

;; ---- contract file resolution (repo-root-relative, like the checker) ----

(define (script-arg cl)
  (let loop ((l cl))
    (cond ((null? l) #f)
          ((string=? (car l) "--script") (and (pair? (cdr l)) (cadr l)))
          (else (loop (cdr l))))))

(define contract-file
  (let ((sp (or (script-arg (command-line)) "host/scheme-adapter/chez.ss")))
    (string-append (substring sp 0 (- (string-length sp) (string-length "chez.ss")))
                   "CONTRACT.txt")))

;; ---- capability runtime load (gate-time only) ------------------------------
;; The capability-system names are OUR definitions, not (chezscheme) exports:
;; load the runtime half so the assertion pass below can probe them. Loading
;; the file is also the compile check — a broken entry point fails here.

(define (runtime-file)
  (let* ((d (substring contract-file 0
                       (- (string-length contract-file) (string-length "CONTRACT.txt"))))
         (root (substring d 0 (- (string-length d) (string-length "host/scheme-adapter/")))))
    (string-append root "host/chez/scheme-adapter-runtime.ss")))

(load (runtime-file))

;; ---- the assertion pass ----

(define (read-contract-names path)
  (let ((p (open-input-file path)))
    (let loop ((acc '()))
      (let ((l (get-line p)))
        (if (eof-object? l)
            (begin (close-port p) (reverse acc))
            (let ((toks (string->tokens (strip-comment l))))
              (if (or (null? toks)
                      (and (>= (length toks) 2)
                           (string=? (car toks) "#")
                           (string=? (cadr toks) "tier:")))
                  (loop acc)
                  (loop (cons (string->symbol (car toks)) acc)))))))))

(define chez-exports (library-exports '(chezscheme)))

(define (bound-on-target? sym)
  ;; The combined environment: (chezscheme) exports OR a top-level binding.
  ;; library-exports enumerates BOTH variable and syntax bindings (it sees
  ;; with-mutex, which top-level-bound? cannot); top-level-bound? sees OUR
  ;; capability definitions, which the runtime file loaded as plain top-level
  ;; defines and library-exports cannot.
  (or (memq sym chez-exports) (top-level-bound? sym)))

(define (main)
  (let ((names (read-contract-names contract-file)))
    (let ((missing
            (filter (lambda (s) (not (bound-on-target? s))) names)))
      (for-each (lambda (s) (printf "  NOT-BOUND ~a\n" s)) missing)
      (printf "adaptercheck: ~a contract names checked against the combined env\n"
              (length names))
      (if (null? missing)
          (begin (printf "adaptercheck: chez adapter contract satisfied\n") 0)
          (begin (printf "adaptercheck: FAILED — CONTRACT.txt lists ~a name(s) not bound on Chez\n"
                         (length missing))
                 1)))))

(exit (main))
