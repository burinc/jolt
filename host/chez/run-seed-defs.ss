;; run-seed-defs.ss — every var the checked-in seed defines is DEFINED after the
;; seed loads.
;;
;; The seed's top-level forms are emitted guard-wrapped (emit-image.ss, ei-emit-ns
;; guard? #t) so a form the mint cannot COMPILE is skipped rather than failing the
;; whole build; remint.sh fails the fixpoint pass on a nonzero skip count, so that
;; half is checked. The guard is in the emitted TEXT, though, which means it also
;; swallows a form that fails to RUN when the seed loads — and nothing checked
;; that half. A def whose initializer raises at load leaves no var behind, and
;; every later read of the name gets the unbound sentinel, which is an OBJECT and
;; therefore truthy: a flag read as a condition is then silently ON forever. That
;; is jolt#879 — JOLT_WP_TRACE and JOLT_IR_VALIDATE both read jolt.host/getenv in
;; a top-level def, and jolt.host/getenv did not exist yet at image-load time.
;;
;; So: read the seed back, collect every (def-var! NS NAME …) /
;; (def-var-with-meta! NS NAME …) it emits, and assert the runtime has each one.
;; The boot preamble here is the runtime's own prefix through the image, so a
;; form that raises at load raises here too.
;;
;;   chez --script host/chez/run-seed-defs.ss
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

;; Collect (ns . name) for every def-var! / def-var-with-meta! call in a datum.
;; Walks car and cdr separately so an improper list inside quoted data is fine.
(define (sd-collect x acc)
  (cond
    ((pair? x)
     (let ((acc (if (and (memq (car x) '(def-var! def-var-with-meta! def-var-plain! def-var-linked!))
                         (pair? (cdr x)) (string? (cadr x))
                         (pair? (cddr x)) (string? (caddr x)))
                    (cons (cons (cadr x) (caddr x)) acc)
                    acc)))
       (sd-collect (cdr x) (sd-collect (car x) acc))))
    ((vector? x)
     (let loop ((i 0) (acc acc))
       (if (fx=? i (vector-length x)) acc (loop (fx+ i 1) (sd-collect (vector-ref x i) acc)))))
    (else acc)))

(define (sd-defs file)
  (let ((p (open-input-file file)))
    (let loop ((acc '()))
      (let ((f (read p)))
        (if (eof-object? f)
            (begin (close-port p) (reverse acc))
            (loop (sd-collect f acc)))))))

;; A miss and an "off" flag must not read alike, so report a symbol, never a boolean.
(define (sd-state ns name)
  (let ((cell (var-cell-lookup ns name)))
    (cond ((not (and cell (var-cell-defined? cell))) 'missing)
          ((jolt-truthy? (var-cell-root cell)) 'on)
          (else 'off))))

;; floor: the emit shape changing under the collector would otherwise leave this
;; gate passing over an empty list.
(define (sd-check-file file floor)
  (let ((defs (sd-defs file)))
    (gate-check (string-append file " def count >= " (number->string floor))
                (>= (length defs) floor) #t)
    (for-each
      (lambda (p)
        (let ((cell (var-cell-lookup (car p) (cdr p))))
          (gate-check (string-append (car p) "/" (cdr p))
                      (and cell (var-cell-defined? cell) #t) #t)))
      defs)))

(sd-check-file "host/chez/seed/prelude.ss" 500)
(sd-check-file "host/chez/seed/image.ss" 400)

;; The two compiler trace flags, whose defs run as the image loads. Their value
;; must follow the environment; this script is run twice (see the Makefile), once
;; with both set, so both arms are covered.
(define (sd-flag-check ns name env)
  (gate-check (string-append ns "/" name " vs $" env)
              (sd-state ns name)
              (if (getenv env) 'on 'off)))

(sd-flag-check "jolt.passes" "ir-validate?" "JOLT_IR_VALIDATE")
(sd-flag-check "jolt.passes" "wp-trace?" "JOLT_WP_TRACE")
(sd-flag-check "jolt.passes.types" "wp-trace?" "JOLT_WP_TRACE")

(gate-summary "seed-defs")
