;; run-gate-harness.ss — shared gate harness: boot preamble, check counter, substring scan, summary/exit.
;;
;; Loaded by every run-*.ss gate to avoid duplicating the runtime boot preamble
;; and check/fails harness. Usage:
;;   (import (chezscheme))
;;   (load "host/chez/run-gate-harness.ss")
;;   … gate-specific code …
;;   (gate-summary "name")

;; --- boot preamble ---------------------------------------------------------------
;; Shared with the test/chez gate scripts; uses target/dev/gate.so when `make
;; gateboot` has built it and it is fresh, else loads the runtime from source.
(load "host/chez/gate-boot.ss")

;; --- check counter ---------------------------------------------------------------
(define gate-fails 0)
(define gate-total 0)
(define (gate-check label actual expected)
  (set! gate-total (+ gate-total 1))
  (unless (equal? actual expected)
    (set! gate-fails (+ gate-fails 1))
    (printf "  FAIL ~a: got ~s expected ~s\n" label actual expected)))

;; --- substring scan --------------------------------------------------------------
(define (gate-sub? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

;; --- summary / exit --------------------------------------------------------------
(define (gate-summary name)
  (if (= gate-fails 0)
      (begin (printf "~a gate: ~a/~a passed\n" name gate-total gate-total) (exit 0))
      (begin (printf "~a gate: ~a/~a passed (~a failed)\n" name (- gate-total gate-fails) gate-total gate-fails) (exit 1))))
