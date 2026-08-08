;; jolt-nvpr.10 probe A — memory under fiber CHURN. R0 measured a steady-state
;; population; this creates fibers, runs them to completion, discards them, and
;; asks whether live bytes return to baseline wave over wave. A creep with a flat
;; population is the finding; a clean result is also a result.
(import (chezscheme))
(load "host/chez/gate-boot.ss")
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-pool-reset!)
(define ch (jolt-async-chan 1))
(define (wave! n)
  ;; each fiber parks on a take, is fed, and finishes — a full lifecycle
  (let loop ((i 0) (fs '()))
    (if (< i n)
        (loop (+ i 1) (cons (sa-fiber-spawn (lambda () (jolt-fiber-<! ch))) fs))
        (begin
          (sa-fiber-run-all)                       ; all park
          (do ((j 0 (+ j 1))) ((= j n))
            (jolt-async-give ch j)
            (sa-fiber-run-all))                    ; each wakes and finishes
          (length fs)))))
(collect (collect-maximum-generation))
(define base (bytes-allocated))
(printf "baseline live: ~a bytes\n" base)
(let loop ((w 0))
  (when (< w 8)
    (wave! 2000)
    (collect (collect-maximum-generation))
    (printf "  wave ~a: ~a fibers created so far, live delta ~a B\n"
            w (* 2000 (+ w 1)) (- (bytes-allocated) base))
    (flush-output-port (current-output-port))
    (loop (+ w 1))))
(printf "done.\n")
