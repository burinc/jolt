;; collect-safe-scaling.ss — run by collect-safe-activation-test.sh (plain Chez).
;; jolt's lockfree-activation patch walks the thread list to deactivate
;; threads sitting in collect-safe calls, and locks parked threads' code when
;; it collects. Done in the wrong place either is quadratic, so this measures
;; the two places it could show, in one process:
;;   MUTEX   — taking the tc mutex from Scheme (with-tc-mutex does it all over
;;             the runtime) with 2000 parked threads, over none. ~2 on stock
;;             and patched kernels; ~190 with a conversion walk on every
;;             acquire (measured on a kernel built that way).
;;   COLLECT — one collection with 1000 parked threads, over 100. Either ~0.5
;;             or ~14 from run to run on stock and patched kernels alike (the
;;             collector visits every thread); a walk per waiting thread, or a
;;             lock per parked thread, would be quadratic, ~100.
(define (secs thunk)
  (let ([t0 (current-time 'time-monotonic)])
    (thunk)
    (let ([d (time-difference (current-time 'time-monotonic) t0)])
      (+ (time-second d) (/ (time-nanosecond d) 1e9)))))
(define (with-parked n thunk)
  (let ([m (make-mutex)] [c (make-condition)] [stop #f] [up 0])
    (do ([i 0 (fx+ i 1)]) ((fx= i n))
      (fork-thread (lambda () (with-mutex m (set! up (fx+ up 1)) (condition-broadcast c)
                                (let w () (unless stop (condition-wait c m) (w)))))))
    (with-mutex m (let w () (unless (fx= up n) (condition-wait c m) (w))))
    (let ([r (thunk)])
      (with-mutex m (set! stop #t) (condition-broadcast c))
      r)))
(define tcm #%$tc-mutex)
(define (mutex-per k)
  (/ (secs (lambda ()
             (do ([i 0 (fx+ i 1)]) ((fx= i k))
               (disable-interrupts) (mutex-acquire tcm) (mutex-release tcm) (enable-interrupts))))
     k))
(define (collect-per k)
  (/ (secs (lambda () (do ([i 0 (fx+ i 1)]) ((fx= i k)) (collect-rendezvous)))) k))
(define (best f) (apply min (map (lambda (_) (f)) '(1 2 3))))
(let* ([m0 (best (lambda () (with-parked 0 (lambda () (mutex-per 200000)))))]
       [m1 (best (lambda () (with-parked 2000 (lambda () (mutex-per 200000)))))]
       [c0 (best (lambda () (with-parked 100 (lambda () (collect-per 200)))))]
       [c1 (best (lambda () (with-parked 1000 (lambda () (collect-per 200)))))])
  (printf "MUTEX ~,2f COLLECT ~,2f\n" (/ m1 m0) (/ c1 c0)))
(exit)
