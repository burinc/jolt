;; Fibers: preemptive scheduling (jolt-atc.2, swish's quantum — erlang.ss:872).
;;
;; Cooperatively scheduled fibers only leave their carrier at a channel op, so a
;; compute-bound go block pins that carrier and starves everything queued behind
;; it. R0(d) pins a fiber to its carrier for life, so growing the pool cannot
;; rescue the stranded work — the only fix is to take the carrier away.
;;
;; The gate pins the pool to ONE carrier so starvation is deterministic: fiber A
;; spins without ever yielding, fiber B is queued behind it. Cooperatively B can
;; never run. With a quantum it does.
;;
;; Loads the full runtime (rt.ss) because the preempt knob is read off a jolt
;; var and the handler needs the real carrier pool.
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))

(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((pred) #t)
            ((> (now-secs) deadline)
             (set! fails (+ fails 1))
             (printf "  FAIL: ~a (timed out)\n" what)
             #f)
            (else (sleep (make-time 'time-duration 2000000 0)) (loop))))))

(printf "== fiber preemption ==\n")

;; --- 1. off by default ------------------------------------------------------
;; ON by default. Cooperative-only is not a milder default, it is an unbounded
;; starvation window, so the preemptive path is the only path that ships.
(ok "1. preemption is ON by default" (and (jolt-fiber-preempt-ticks) #t))
(ok "1. the default quantum is sub-millisecond"
    (eqv? (jolt-fiber-preempt-ticks) jolt-fiber-preempt-ticks-default))

(jolt-fiber-preempt-ticks-set! 20000)
(ok "1. host setter pins a different quantum" (eqv? 20000 (jolt-fiber-preempt-ticks)))
(jolt-fiber-preempt-ticks-set! #f)
(ok "1. the escape hatch turns it off" (not (jolt-fiber-preempt-ticks)))
(ok "1. a non-positive tick count is refused"
    (guard (e (#t #t)) (jolt-fiber-preempt-ticks-set! 0) #f))

;; --- 2. cooperatively, a spinner starves its carrier ------------------------
;; ONE carrier, so B has nowhere else to go. A spins on a box the driver flips;
;; the flag is how the test stops it without ever letting it park.
;; section 2 needs cooperative behaviour on purpose, which is no longer the
;; default, so it asks for it explicitly
(jolt-fiber-preempt-ticks-set! #f)
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)

(define (spin-until stop-box) (let loop () (unless (unbox stop-box) (loop))))

(define coop-stop (box #f))
(define coop-b-ran (box #f))
(define coop-a
  (sa-fiber-spawn (lambda () (spin-until coop-stop))))
(define coop-b
  (sa-fiber-spawn (lambda () (set-box! coop-b-ran #t))))
(jolt-fiber-ensure-carrier!)
(sleep (make-time 'time-duration 300000000 0))       ; 0.3s
(ok "2. cooperatively the queued fiber is starved" (not (unbox coop-b-ran)))
(set-box! coop-stop #t)
(wait-until (lambda () (unbox coop-b-ran)) 5.0 "2. B runs once A finishes")
(ok "2. B ran after A released the carrier" (unbox coop-b-ran))

;; --- 3. with a quantum the same fiber does NOT starve ------------------------
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! 20000)

(define pre-stop (box #f))
(define pre-b-ran (box #f))
(define preempts-before (jolt-fiber-preempts))
(define pre-a
  (sa-fiber-spawn (lambda () (spin-until pre-stop))))
(define pre-b
  (sa-fiber-spawn (lambda () (set-box! pre-b-ran #t))))
(jolt-fiber-ensure-carrier!)
(define b-ran-while-a-spins?
  (wait-until (lambda () (unbox pre-b-ran)) 5.0
              "3. queued fiber runs while the spinner still holds the carrier"))
(ok "3. the spinner was actually preempted"
    (> (jolt-fiber-preempts) preempts-before))
(ok "3. the queued fiber ran WITHOUT the spinner ever yielding"
    (and b-ran-while-a-spins? (not (unbox pre-stop))))
(set-box! pre-stop #t)
(wait-until (lambda () (eq? 'done (jolt-fiber-state pre-a))) 5.0 "3. spinner completes")
(ok "3. the preempted fiber still completed normally"
    (eq? 'done (jolt-fiber-state pre-a)))

;; --- 4. a preemption is not counted as a park -------------------------------
;; run-gosm.ss asserts EXACT deltas on the two park counters, so a preemption
;; must not land in either. It takes the continuation path, which is neither an
;; sm cheap park nor a channel park.
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! 20000)
(define sm-before (jolt-sm-parks))
(define chan-before (jolt-fiber-chan-parks))
(define p4-before (jolt-fiber-preempts))
(define p4-stop (box #f))
(define p4-f (sa-fiber-spawn (lambda () (spin-until p4-stop))))
(jolt-fiber-ensure-carrier!)
(wait-until (lambda () (> (jolt-fiber-preempts) p4-before)) 5.0 "4. a preemption fired")
(set-box! p4-stop #t)
(wait-until (lambda () (eq? 'done (jolt-fiber-state p4-f))) 5.0 "4. fiber completes")
(ok "4. preemption did not bump the sm-park counter"
    (= sm-before (jolt-sm-parks)))
(ok "4. preemption did not bump the chan-park counter"
    (= chan-before (jolt-fiber-chan-parks)))

;; --- 5. turning it off again restores cooperative behaviour -----------------
;; Proves the knob is read per dispatch rather than latched at pool start, which
;; is what makes it safe to leave the machinery compiled in while off.
(jolt-fiber-preempt-ticks-set! #f)
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(define off-stop (box #f))
(define off-b-ran (box #f))
(define off-a (sa-fiber-spawn (lambda () (spin-until off-stop))))
(define off-b (sa-fiber-spawn (lambda () (set-box! off-b-ran #t))))
(jolt-fiber-ensure-carrier!)
(sleep (make-time 'time-duration 300000000 0))
(ok "5. with the knob off the queued fiber starves again" (not (unbox off-b-ran)))
(set-box! off-stop #t)
(wait-until (lambda () (unbox off-b-ran)) 5.0 "5. B runs after A finishes")

(jolt-fiber-pool-reset!)
(printf "\nfibers-preempt-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-preempt-test: PASS — preemptive scheduling\n") (exit 0))
    (exit 1))
