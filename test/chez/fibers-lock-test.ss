;; Fibers: an object monitor across a fiber switch (jolt-3a87).
;;
;; Every lock in the runtime routes through the counting wrapper in locks.ss, and
;; the scheduler refuses to preempt a fiber that holds one. locks.ss states the
;; premise that makes that sound: such regions are SHORT — measured at ~55ns mean
;; against a 0.45ms quantum — and they never span a park, because either
;; jolt-with-mutex rewinds the acquire or the site releases by hand before parking.
;;
;; That premise is true of every lock in the runtime and false of exactly one, the
;; object monitor behind clojure.core/locking and the bare (monitor-enter x) /
;; (monitor-exit x) special forms. A monitor wraps arbitrary user code: the region is
;; as long as the body, and the body may park. Treating it as one of the short ones
;; failed three ways, and this gate is the three.
;;
;; It also pins what the fix rests on, which is that ownership is a FIELD and not
;; the OS mutex. A field survives a switch; an OS mutex cannot, because it has thread
;; granularity and fibers multiplex one thread — and Chez mutexes are recursive per
;; thread, so a sibling fiber's acquire SUCCEEDS and walks into the section rather
;; than failing where it could be noticed.
;;
;; Loads the full runtime: the monitors live in java/concurrency.ss and the gate
;; needs real channels to park on.
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-secs)
  (let ((t (current-time 'time-monotonic)))
    (+ (exact->inexact (time-second t)) (/ (time-nanosecond t) 1e9))))
(define (wait-until pred secs what)
  (let ((deadline (+ (mono-secs) secs)))
    (let loop ()
      (cond ((pred) #t)
            ((> (mono-secs) deadline)
             (set! fails (+ fails 1))
             (printf "  FAIL: ~a (timed out)\n" what)
             #f)
            (else (sleep (make-time 'time-duration 2000000 0)) (loop))))))

(printf "== object monitors across a fiber switch ==\n")

;; ONE carrier throughout the synchronous sections: two fibers on one carrier is the
;; only configuration in which a fiber can observe another fiber's monitor at all,
;; because same-carrier fibers are the only ones that share a thread. sa-fiber-run-all
;; drains on THIS thread, which makes the interleaving exact instead of timed.
(jolt-fiber-carrier-count-set! 1)

;; An occupancy counter, which is the property under test said directly: how many
;; executions are between enter and exit of ONE monitor at the same moment. Mutual
;; exclusion is "this never exceeds 1", and nothing weaker is worth asserting — a
;; monitor that is merely acquired and released in some order proves nothing.
(define occ 0)
(define occ-max 0)
(define (occ-in!) (set! occ (+ occ 1)) (when (> occ occ-max) (set! occ-max occ)))
(define (occ-out!) (set! occ (- occ 1)))
(define (occ-reset!) (set! occ 0) (set! occ-max 0))

(define trace '())
(define (note! x) (set! trace (cons x trace)))
(define (trace-reset!) (set! trace '()))
(define (trace-out) (reverse trace))

;; --- 1. `locking` around a park keeps the monitor -----------------------------
;; jolt-with-monitor used to be a plain dynamic-wind, so a park unwound it: the
;; monitor was released mid-body and re-taken on resume. Two fibers on one carrier
;; then both got in — traced (a-in b-in a-resumed a-out b-resumed b-out), occupancy
;; 2 — and when the second one's resume re-entered, monitor-enter! found the owner
;; equal to its own identity, because the owner WAS the carrier thread, which both
;; fibers share. So it took the reentrant arm and never noticed.
(occ-reset!)
(trace-reset!)
(define l1-obj (vector 'l1))
(define l1-a-ch (ac-make 1 'fixed #f))
(define l1-b-ch (ac-make 1 'fixed #f))
(define (l1-body tag ch)
  (lambda ()
    (jolt-with-monitor l1-obj
      (lambda ()
        (occ-in!) (note! (string->symbol (string-append tag "-in")))
        (jolt-fiber-<! ch)
        (note! (string->symbol (string-append tag "-resumed")))
        (occ-out!) (note! (string->symbol (string-append tag "-out")))))))
(define l1-a (sa-fiber-spawn (l1-body "a" l1-a-ch)))
(define l1-b (sa-fiber-spawn (l1-body "b" l1-b-ch)))

;; A enters and parks. B wants the monitor and must WAIT for it, so B never reaches
;; its own channel and the drain ends with both fibers parked.
(sa-fiber-run-all)
(ok "1. only one fiber is inside the monitor while the other waits" (= 1 occ-max))
(ok "1. B never entered while A held it" (equal? '(a-in) (trace-out)))

;; Feed A. It resumes inside the body, leaves, releases — and only then does B get in.
(jolt-async-give l1-a-ch 1)
(sa-fiber-run-all)
(jolt-async-give l1-b-ch 2)
(sa-fiber-run-all)
(ok "1. both fibers completed"
    (and (eq? 'done (jolt-fiber-state l1-a)) (eq? 'done (jolt-fiber-state l1-b))))
(ok "1. exclusion held across both parks" (= 1 occ-max))
(ok "1. and the bodies did not interleave"
    (equal? '(a-in a-resumed a-out b-in b-resumed b-out) (trace-out)))
(ok "1. the monitor is free afterwards" (= 0 occ))

;; --- 2. the bare halves are the same monitor, and the same rule ---------------
;; (monitor-enter x) / (monitor-exit x) have no dynamic-wind at all, so a park in
;; between could not even release the monitor by accident — it simply kept the OS
;; mutex across the switch. Two things followed and both are checked here: the next
;; fiber on the carrier saw jolt-locks-held stuck above zero, which makes the whole
;; carrier unpreemptible for as long as the first fiber stays parked, and its own
;; monitor-enter recursed on the shared thread and let it straight in.
(occ-reset!)
(trace-reset!)
(define l2-obj (vector 'l2))
(define l2-ch (ac-make 1 'fixed #f))
(define l2-locks-seen 'unset)
(define l2-a
  (sa-fiber-spawn
   (lambda ()
     (jolt-monitor-enter l2-obj)
     (occ-in!) (note! 'a-in)
     (jolt-fiber-<! l2-ch)
     (occ-out!) (note! 'a-out)
     (jolt-monitor-exit l2-obj))))
(define l2-b
  (sa-fiber-spawn
   (lambda ()
     ;; read BEFORE contending: this is the carrier's count as the next fiber finds
     ;; it, which is what the preempt handler reads.
     (set! l2-locks-seen (jolt-locks-held))
     (jolt-monitor-enter l2-obj)
     (occ-in!) (note! 'b-in)
     (occ-out!) (note! 'b-out)
     (jolt-monitor-exit l2-obj))))
(sa-fiber-run-all)
(ok "2. the carrier holds no lock while a fiber is parked inside a monitor"
    (eqv? 0 l2-locks-seen))
(ok "2. the sibling fiber did not re-enter the held monitor" (equal? '(a-in) (trace-out)))
(jolt-async-give l2-ch 1)
(sa-fiber-run-all)
(ok "2. it got in once the holder left"
    (equal? '(a-in a-out b-in b-out) (trace-out)))
(ok "2. exclusion held for the bare halves too" (= 1 occ-max))
(ok "2. both fibers completed"
    (and (eq? 'done (jolt-fiber-state l2-a)) (eq? 'done (jolt-fiber-state l2-b))))

;; --- 3. a monitor body is preemptible -----------------------------------------
;; The other half of routing a monitor through the counting wrapper: the count stayed
;; up for the whole body, so the scheduler refused to preempt anywhere inside it.
;; With one carrier, a fiber spinning inside (locking o …) starved everything queued
;; behind it — 0 preemptions, and the queued fiber ran only once the monitor was
;; released. That is the unbounded starvation window fibers.ss says no setting opens.
;; Real carrier threads here: the point is that the SCHEDULER takes the carrier away.
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! 20000)

(define l3-obj (vector 'l3))
(define l3-stop (box #f))
(define l3-b-ran (box #f))
(define l3-before (jolt-fiber-preempts))
(define (l3-spin-until b) (let loop () (unless (unbox b) (loop))))
(define l3-a
  (sa-fiber-spawn
   (lambda () (jolt-with-monitor l3-obj (lambda () (l3-spin-until l3-stop))) 'a)))
(define l3-b (sa-fiber-spawn (lambda () (set-box! l3-b-ran #t) 'b)))
(jolt-fiber-ensure-carrier!)
(define l3-ran-while-held?
  (wait-until (lambda () (unbox l3-b-ran)) 5.0
              "3. the queued fiber runs while the monitor is held"))
(ok "3. a queued fiber is not starved by a long monitor body"
    (and l3-ran-while-held? (not (unbox l3-stop))))
(ok "3. the scheduler actually preempted the holder" (> (jolt-fiber-preempts) l3-before))
(set-box! l3-stop #t)
(wait-until (lambda () (eq? 'done (jolt-fiber-state l3-a))) 5.0 "3. the holder completes")
(ok "3. the holder still completed normally" (eq? 'done (jolt-fiber-state l3-a)))

;; --- 4. a preempted monitor body still excludes -------------------------------
;; The check that says the fix is not "stop protecting the region": with the body now
;; preemptible, a contended monitor under a floor quantum must still serialize. Four
;; fibers on ONE carrier, each incrementing an unsynchronized counter inside the
;; monitor, with a burn either side so preemptions fall due mid-body. Losing exclusion
;; loses increments.
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! jolt-fiber-preempt-ticks-min)

(define L4-N 4)
(define L4-PER 500)
(define l4-obj (vector 'l4))
(define l4-count 0)
(define l4-occ-max 0)
(define l4-occ 0)
(define l4-done 0)
(define l4-before (jolt-fiber-preempts))
(define (l4-burn n) (let loop ((i 0) (a 0)) (if (fx=? i n) a (loop (fx+ i 1) (fx+ a i)))))
(do ((i 0 (+ i 1))) ((= i L4-N))
  (sa-fiber-spawn
   (lambda ()
     (let loop ((j 0))
       (if (< j L4-PER)
           (begin
             (jolt-with-monitor l4-obj
               (lambda ()
                 (set! l4-occ (+ l4-occ 1))
                 (when (> l4-occ l4-occ-max) (set! l4-occ-max l4-occ))
                 (l4-burn 300)
                 (set! l4-count (+ l4-count 1))
                 (set! l4-occ (- l4-occ 1))))
             (l4-burn 100)
             (loop (+ j 1)))
           (set! l4-done (+ l4-done 1)))))))
(jolt-fiber-ensure-carrier!)
(wait-until (lambda () (= l4-done L4-N)) 120.0 "4. every fiber finished")
(ok "4. no monitored update lost under preemption" (= l4-count (* L4-N L4-PER)))
(ok "4. never two fibers inside the monitor at once" (= 1 l4-occ-max))
(ok "4. preemption fired during the run" (> (jolt-fiber-preempts) l4-before))
(ok "4. no lock left held on this thread" (= 0 (jolt-locks-held)))

;; --- 5. a thread and a fiber contend the same monitor -------------------------
;; Cross-thread is what the OS mutex was there for, and it has to keep working now
;; that ownership is a field. A fiber takes the monitor and parks inside it; a plain
;; thread then asks for the same monitor and must wait, not walk in — and must not
;; wait forever once the fiber leaves.
(jolt-fiber-pool-reset!)
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-preempt-ticks-set! #f)

(define l5-obj (vector 'l5))
(define l5-ch (ac-make 1 'fixed #f))
(define l5-in (box #f))
(define l5-thread-got (box #f))
(define l5-thread-saw-occ (box 'unset))
(define l5-occ (box 0))
(define l5-a
  (sa-fiber-spawn
   (lambda ()
     (jolt-with-monitor l5-obj
       (lambda ()
         (set-box! l5-occ (+ 1 (unbox l5-occ)))
         (set-box! l5-in #t)
         (jolt-fiber-<! l5-ch)
         (set-box! l5-occ (- (unbox l5-occ) 1)))))))
(jolt-fiber-ensure-carrier!)
(wait-until (lambda () (unbox l5-in)) 5.0 "5. the fiber took the monitor")
(define l5-t
  (fork-thread
   (lambda ()
     (jolt-with-monitor l5-obj
       (lambda ()
         (set-box! l5-thread-saw-occ (unbox l5-occ))
         (set-box! l5-thread-got #t))))))
(sleep (make-time 'time-duration 100000000 0))   ; 100ms: long enough to prove it waits
(ok "5. a thread does not enter a monitor a parked fiber holds" (not (unbox l5-thread-got)))
(jolt-async-give l5-ch 1)
(wait-until (lambda () (unbox l5-thread-got)) 5.0 "5. the thread gets in once the fiber leaves")
(thread-join l5-t)
(ok "5. and it found the monitor empty when it did" (eqv? 0 (unbox l5-thread-saw-occ)))
(ok "5. the fiber completed" (eq? 'done (jolt-fiber-state l5-a)))

;; --- 6. the properties a monitor already had ----------------------------------
;; Regressions, all of them on the fiber that the sections above changed the
;; implementation for. Reentrancy is the one that matters most: it is what keeps a
;; nested (locking x …) on one object from deadlocking on itself, and the owner
;; identity moved, which is exactly the field that decides it.
(define l6-obj (vector 'l6))
(define l6-nested (box #f))
(define l6-threw (box #f))
(define l6-released (box #f))
(define l6-f
  (sa-fiber-spawn
   (lambda ()
     ;; reentrant on the same object, from the same fiber
     (jolt-with-monitor l6-obj
       (lambda ()
         (jolt-with-monitor l6-obj (lambda () (set-box! l6-nested #t)))))
     ;; a throw inside the body is a real exit, so the monitor is released
     (guard (e (#t (set-box! l6-threw #t)))
       (jolt-with-monitor l6-obj (lambda () (error 'l6 "boom"))))
     (jolt-with-monitor l6-obj (lambda () (set-box! l6-released #t)))
     'done)))
(jolt-fiber-ensure-carrier!)
(wait-until (lambda () (memq (jolt-fiber-state l6-f) '(done dead))) 5.0 "6. the fiber finishes")
(ok "6. a nested locking on one object re-enters" (unbox l6-nested))
(ok "6. a throw inside the body still propagates" (unbox l6-threw))
(ok "6. and still releases the monitor" (unbox l6-released))
(ok "6. the fiber completed rather than died" (eq? 'done (jolt-fiber-state l6-f)))

;; monitor-exit by something that does not own it is still an error, on a fiber as
;; on a thread — the bare halves are reachable from user code and unbalanced use has
;; to be reported rather than corrupt the count.
(define l7-obj (vector 'l7))
(ok "6. monitor-exit without the monitor throws"
    (guard (e (#t #t)) (jolt-monitor-exit l7-obj) #f))

(jolt-fiber-pool-reset!)

(printf "\nfibers-lock-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-lock-test: PASS — monitors across a fiber switch\n") (exit 0))
    (exit 1))
