;; jolt-nvpr.10 probe B — the size of a fiber with REAL frames.
;; Method: retain in a global, force a full collect, absolute live bytes.
;; Per-phase bytes-allocated deltas are not evidence (they produced both of R0's
;; wrong findings). The pool is never started, because a forced full collect
;; cannot run while carrier threads are alive.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(define held '())
(define (measure label k mk)
  (set! held '())
  (jolt-fiber-carrier-count-set! 1)
  (jolt-fiber-pool-reset!)
  (collect (collect-maximum-generation))
  (let ((base (bytes-allocated)))
    (do ((i 0 (+ i 1))) ((= i k))
      (set! held (cons (sa-fiber-spawn (mk i)) held)))
    (sa-fiber-run-all)
    (let ((parked (let loop ((l held) (n 0))
                    (cond ((null? l) n)
                          ((eq? (jolt-fiber-state (car l)) 'parked) (loop (cdr l) (+ n 1)))
                          (else (loop (cdr l) n))))))
      (collect (collect-maximum-generation))
      (let ((live (- (bytes-allocated) base)))
        (printf "  ~a: ~a B/fiber   (~a/~a parked)\n"
                label (/ (exact->inexact live) k) parked k)))))

(define ch (jolt-async-chan 1))
;; 0. a fiber that RAN TO COMPLETION: the continuation is dropped, so this is the
;;    record alone and shows what the stack segment costs by its absence.
(measure "completed (no continuation) " 10000 (lambda (i) (lambda () (sa-fiber-yield) 'done)))
;; 1. parked ONE frame deep on a channel take — the R0 baseline shape
(measure "1 frame, parked on channel " 10000 (lambda (i) (lambda () (jolt-fiber-<! ch))))
;; 2. realistic body: nested calls with live locals, parked on a channel take
(define (lvl3 a b) (jolt-fiber-<! ch))
(define (lvl2 a b) (let ((x (+ a 1)) (y (* b 2))) (lvl3 x y)))
(define (lvl1 a)   (let ((z (list a a))) (lvl2 a (length z))))
(measure "3 nested calls + channel   " 10000 (lambda (i) (lambda () (lvl1 i))))
;; 3. the same inside a try/finally (dynamic-wind stays on the stack)
(measure "same, inside dynamic-wind  " 10000
         (lambda (i) (lambda () (dynamic-wind (lambda () #f) (lambda () (lvl1 i) 'done) (lambda () #f)))))
(printf "done.\n")
