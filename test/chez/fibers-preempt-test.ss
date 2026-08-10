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
;; OFF by default: preemption can still split any with-mutex region in the
;; runtime, which loses atom updates (jolt-atc.7). Everything below exercises it
;; explicitly so the machinery keeps working while that is outstanding.
(ok "1. preemption is off by default" (not (jolt-fiber-preempt-ticks)))
(jolt-fiber-preempt-ticks-set! 20000)
(ok "1. host setter pins a quantum" (eqv? 20000 (jolt-fiber-preempt-ticks)))
(jolt-fiber-preempt-ticks-set! #f)
(ok "1. #f turns it off again" (not (jolt-fiber-preempt-ticks)))
;; A quantum below the floor cannot make progress, so it is refused rather than
;; allowed to livelock the carrier.
(ok "1. a quantum below the floor is refused"
    (guard (e (#t #t))
      (jolt-fiber-preempt-ticks-set! (fx- jolt-fiber-preempt-ticks-min 1)) #f))
(ok "1. the floor itself is accepted"
    (guard (e (#t #f))
      (jolt-fiber-preempt-ticks-set! jolt-fiber-preempt-ticks-min) #t))

;; --- 2. cooperatively, a spinner starves its carrier ------------------------
;; ONE carrier, so B has nowhere else to go. A spins on a box the driver flips;
;; the flag is how the test stops it without ever letting it park.
;; Section 2 wants the cooperative failure mode on purpose.
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

;; --- 5. turning it off again starves again ----------------------------------
;; The knob is read per dispatch rather than latched at pool start.
(jolt-fiber-preempt-ticks-set! #f)
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(define off-stop (box #f))
(define off-b-ran (box #f))
(define off-a (sa-fiber-spawn (lambda () (spin-until off-stop))))
(define off-b (sa-fiber-spawn (lambda () (set-box! off-b-ran #t))))
(jolt-fiber-ensure-carrier!)
(sleep (make-time 'time-duration 300000000 0))
(ok "5. with preemption off the queued fiber starves again" (not (unbox off-b-ran)))
(set-box! off-stop #t)
(wait-until (lambda () (unbox off-b-ran)) 5.0 "5. B runs after A finishes")

;; --- 6. channel ops are not preempted mid-critical-section ------------------
;; The regression test for the two races preemption introduced, both found by
;; running this with the quantum tightened until it broke.
;;
;; ONE carrier on purpose. Fibers on a carrier share an OS thread and Chez
;; mutexes are recursive per thread, so a fiber suspended holding a channel mutex
;; does NOT announce itself as a deadlock — the next fiber's acquire succeeds and
;; walks into a section another fiber is halfway through. Before the guards, this
;; stalled at 802 of 1600 values; before the commit-window guard, at 0 of 1600.
;;
;; Runs at the FLOOR, the tightest quantum the scheduler accepts, which is four
;; orders of magnitude below the default. Anything looser stops exercising the
;; window at all: at the default a channel-bound fiber parks long before its
;; quantum expires and no preemption ever lands inside an op.
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! jolt-fiber-preempt-ticks-min)

(define NPROD 4)
(define NPER 300)
(define st-ch (jolt-async-chan 4))
(define st-seen (make-eqv-hashtable))
(define st-got 0)
(define st-before (jolt-fiber-preempts))

;; Each producer BURNS a quantum between puts. Without that the test proves
;; nothing: a purely channel-bound fiber parks long before its quantum expires,
;; so no preemption ever fires and the run is trivially clean. The spin is what
;; puts a preemption near, and sometimes inside, a channel op.
(define (st-burn n) (let loop ((i 0) (acc 0)) (if (fx=? i n) acc (loop (fx+ i 1) (fx+ acc i)))))
(do ((i 0 (+ i 1))) ((= i NPROD))
  (let ((id i))
    (sa-fiber-spawn
     (lambda ()
       (let loop ((j 0))
         (when (< j NPER)
           (st-burn 400)
           (jolt-fiber->! st-ch (+ (* id 100000) j))
           (loop (+ j 1))))))))
(sa-fiber-spawn
 (lambda ()
   (let loop ()
     (let ((v (jolt-fiber-<! st-ch)))
       (unless (jolt-nil? v)
         (hashtable-set! st-seen v (+ 1 (hashtable-ref st-seen v 0)))
         (set! st-got (+ st-got 1))
         (loop))))))
(jolt-fiber-ensure-carrier!)
(wait-until (lambda () (>= st-got (* NPROD NPER))) 60.0
            "6. every value delivered under a tight quantum")
(ok "6. no value lost" (= st-got (* NPROD NPER)))
(ok "6. no value duplicated" (= (hashtable-size st-seen) (* NPROD NPER)))
(ok "6. preemption actually fired during the stress"
    (> (jolt-fiber-preempts) st-before))
;; --- 7. a long synchronous drain stays linear -------------------------------
;; The interrupt depth a park records has to be BALANCED when the fiber resumes.
;; It was not, at first: every yield left the depth one higher than it found it,
;; so the stored count grew without bound and the restore loop turned a drain
;; quadratic. 10,000 yields still finished and 200,000 hung, which is exactly the
;; shape of bug the other sections cannot see — they all use short bodies.
(jolt-fiber-preempt-ticks-set! #f)
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(define drain-f
  (sa-fiber-spawn
   (lambda () (let loop ((i 0)) (when (< i 200000) (sa-fiber-yield) (loop (+ i 1)))))))
(define drain-t0 (now-secs))
(jolt-fiber-drain! (jolt-fiber-carrier drain-f))
(ok "7. 200k yields complete on a synchronous drain"
    (eq? 'done (jolt-fiber-state drain-f)))
;; Linear, not quadratic. The quadratic version did not finish in minutes, so any
;; sane bound catches it; 30s leaves room for a slow machine.
(ok "7. and in linear time" (< (- (now-secs) drain-t0) 30.0))

(jolt-fiber-preempt-ticks-set! #f)
(jolt-fiber-pool-reset!)
(printf "\nfibers-preempt-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-preempt-test: PASS — preemptive scheduling\n") (exit 0))
    (exit 1))
