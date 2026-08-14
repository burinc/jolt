;; RRB complexity gate: catvec and slice must not be linear in the vector size.
;; Run:  chez --script test/chez/rrb-scaling-test.ss
;;
;; Guards the complexity class, not the machine: both sizes are measured in
;; ONE process (same heap, same JIT-less substrate), and the assertion is the
;; n-vs-4n RATIO. An O(log n) op holds the ratio near 1; a rebuild-both-halves
;; regression puts it near 4. The bound is generous so only the class trips it
;; (see the readscaling precedent — never assert absolute times).

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define (fresh n)
  (let loop ((i 0) (p empty-pvec)) (if (fx=? i n) p (loop (fx+ i 1) (pvec-conj p i)))))

(define reps 400)

(define (time-catvec a b)
  (let loop ((k 0) (best #f))
    (if (fx=? k 5)
        best
        (let ((t0 (real-time)))
          (do ((i 0 (fx+ i 1))) ((fx=? i reps)) (pvec-catvec a b))
          (let ((dt (- (real-time) t0)))
            (loop (fx+ k 1) (if (or (not best) (< dt best)) dt best)))))))

(define (time-slice p)
  (let ((n (pvec-cnt p)))
    (let loop ((k 0) (best #f))
      (if (fx=? k 5)
          best
          (let ((t0 (real-time)))
            (do ((i 0 (fx+ i 1))) ((fx=? i reps))
              (pvec-slice p (fxquotient n 3) (fx* 2 (fxquotient n 3))))
            (let ((dt (- (real-time) t0)))
              (loop (fx+ k 1) (if (or (not best) (< dt best)) dt best))))))))

(define n1 50000)
(define a1 (fresh n1)) (define b1 (fresh n1))
(define a4 (fresh (* 4 n1))) (define b4 (fresh (* 4 n1)))

;; warmup
(pvec-catvec a1 b1) (pvec-catvec a4 b4)

(define cat1 (max 1 (time-catvec a1 b1)))
(define cat4 (max 1 (time-catvec a4 b4)))
(define cat-ratio (/ (exact->inexact cat4) cat1))

(define sl1 (max 1 (time-slice (pvec-catvec a1 b1))))
(define sl4 (max 1 (time-slice (pvec-catvec a4 b4))))
(define sl-ratio (/ (exact->inexact sl4) sl1))

(printf "rrbscaling: catvec ~ams vs ~ams (x4 size) ratio ~a; slice ~ams vs ~ams ratio ~a\n"
        cat1 cat4 cat-ratio sl1 sl4 sl-ratio)

(define fails 0)
(when (>= cat-ratio 2.5)
  (set! fails (+ fails 1))
  (printf "FAIL: catvec scales with size (ratio ~a >= 2.5) — linear rebuild is back\n" cat-ratio))
(when (>= sl-ratio 2.5)
  (set! fails (+ fails 1))
  (printf "FAIL: slice scales with size (ratio ~a >= 2.5) — linear rebuild is back\n" sl-ratio))
(unless (= fails 0) (exit 1))
(printf "RRB-SCALING OK\n")
