;; host/chez/locks.ss — every lock in the runtime, and the count the scheduler
;; reads to decide whether a fiber may be preempted right now.
;;
;; WHY THIS FILE EXISTS
;;
;; An OS mutex has THREAD granularity. Fibers multiplex one OS thread. So an OS
;; mutex held across a fiber switch is broken either way, and there is no way to
;; fix the switch:
;;
;;   - if the switch UNWINDS, the lock is released mid-section. Chez's with-mutex
;;     is a dynamic-wind and a park is a nonlocal exit, so this is what happens
;;     by default. Measured: (swap! a inc) through a with-mutex'd compare-and-set
;;     loses an update, 11999 of 12000, on every run.
;;   - if the switch does NOT unwind, the fiber keeps the mutex while another
;;     fiber on the SAME carrier runs. Chez mutexes are recursive per thread, so
;;     that fiber's acquire succeeds and walks straight into the section.
;;
;; Both lose exclusion. The only sound answer is not to switch there at all,
;; which is what every runtime that has faced this does: Go's canPreemptM is
;; `mp.locks == 0 && ...`, a counter bumped by acquirem/releasem; Caladan wraps
;; non-reentrant regions in preempt_disable/preempt_enable; Linux PREEMPT_RT
;; keeps raw_spinlock for the sections that must not be preempted. All of them
;; on the same precondition, that such regions are SHORT — jolt's are, measured
;; at ~55ns mean against a 0.45ms quantum.
;;
;; The alternative architecture is to make the locks themselves fiber-aware so a
;; fiber CAN hold one across a switch. That is what Java did in JEP 491, and it
;; took a reimplementation of HotSpot's object monitors to get there. Not this.
;;
;; WHAT MUST NOT BE COPIED FROM THE INTERRUPT DEPTH
;;
;; Two per-carrier quantities behave OPPOSITELY across a park, and conflating
;; them is what broke the previous attempt:
;;
;;   interrupt depth   must NOT rewind. It is carried across the switch in
;;                     jolt-fiber-sic and restored at dispatch. Putting a
;;                     disable in a dynamic-wind before-thunk double-counts it.
;;   lock depth        MUST rewind, because it is a fact ABOUT THE LOCK: the
;;                     after-thunk really did release it and the before-thunk
;;                     really does re-acquire it.
;;
;; So the count below is bumped INSIDE the dynamic-wind, next to the acquire. It
;; has to agree with reality DURING a park, not merely at the ends, because the
;; carrier is handed to another fiber that reads the same register while this one
;; is parked.

;; Slot 7: how many locks this carrier currently holds. Per thread, like the
;; other virtual registers, and a fresh thread starts it at fixnum 0 — which is
;; the correct answer for a thread that never runs fibers.
(define jolt-vreg-locks 7)
(define (jolt-locks-held) (virtual-register jolt-vreg-locks))
;; Always ERR TOWARDS HELD. enter! runs BEFORE the acquire and exit! runs AFTER
;; the release, so the window on each side reads "a lock is held" when one is not
;; quite held yet or no longer is. That costs at most a deferred preemption; the
;; other order would leave a real window where the lock is held and the count
;; says otherwise, which is the bug this file exists to prevent.
(define (jolt-locks-enter!)
  (set-virtual-register! jolt-vreg-locks (fx+ 1 (virtual-register jolt-vreg-locks))))
(define (jolt-locks-exit!)
  (set-virtual-register! jolt-vreg-locks (fx- (virtual-register jolt-vreg-locks) 1)))

;; NOTE on how a refused preemption is remembered. It is NOT remembered here.
;; The obvious design — a pending flag, honoured when the outermost region exits
;; — would have to park from inside a dynamic-wind's after-thunk, since that is
;; where the release happens, and escaping from an after-thunk is its own hazard.
;; The timer is a better memory than a flag: the scheduler's handler simply
;; re-arms on a short retry when it finds a lock held, so the preemption lands
;; just after the region ends without anything here knowing about fibers. That is
;; also what Go does — a goroutine interrupted at an unsafe point is resumed and
;; retried later.

;; (jolt-with-mutex m body ...) — the replacement for Chez's with-mutex.
;; Deliberately a DIFFERENT NAME rather than a shadow: a shadow would make every
;; site silently safe, which is pleasant right up until the gate cannot tell
;; whether a site was considered or merely inherited the shadow. host/chez/
;; lock-check.sh requires the explicit name, so the migration is visible and the
;; count can only go down.
;;
;; A FIBER MAY NOT PARK INSIDE THE BODY, and that is a rule rather than a
;; guideline: the count above is what the preempt handler reads to refuse an
;; INVOLUNTARY switch, and a voluntary one is not different in kind. So there is
;; one rule, and it covers both:
;;
;;   a fiber never leaves the CPU while its carrier holds a counted lock.
;;
;; jolt-locks-assert-none! below is that rule, and every switch point calls it —
;; jolt-fiber-to-scheduler! (which is yield, park, and the preemption) and
;; jolt-sm-park! (the cheap park). So a violation raises at the park instead of
;; wedging a process with no error and no output.
;;
;; IT USED TO BE AN EXCEPTION, which is how the same bug arrived three times
;; (jolt-3a87, jolt-dfuo, jolt-04ee). Parking inside the body was legal,
;; licensed by dynamic-wind: the after-thunk releases on the way out and the
;; before-thunk re-acquires when the continuation is resumed, so the lock is not
;; held ACROSS the park. What that reading leaves out is WHERE the re-acquire
;; runs. It runs from Chez's rewind, on the carrier thread, at the interrupt
;; depth the fiber parked at, where the preemption timer is not polled, the
;; carrier can do nothing else until it succeeds, and nothing can make it give
;; up. So a park does not merely release a lock and retake it. It attaches a
;; blocking acquire to a point in the SCHEDULER, and the wait edge that creates
;; belongs to every fiber on that carrier, not to the one that parked.
;;
;; The precondition that makes that safe is non-local to match: no fiber on the
;; carrier may be holding m while this one is off the CPU. A parking site cannot
;; check that, and a reviewer cannot see it, because it is a statement about
;; every OTHER user of m that shares the carrier. For the object monitor it was
;; read as the weaker "no fiber is parked while HOLDING m", which is true and
;; insufficient; one run in twelve of a contended monitor wedged the whole
;; process, and one of those was a ninety-minute `make test` (jolt-8tma). The
;; rule above is the same guarantee with nothing left to read wrong, and unlike
;; the precondition it replaces it is checkable — at the switch, and statically
;; over the whole runtime (host/chez/park-lock-check.ss).
;;
;; WAITING FOR STATE THIS LOCK GUARDS is what the exception existed for, and it
;; never needed one: commit under the lock, switch outside it. That is
;; jolt-lock-wait, below.
;;
;; A CHEAP park (java/sm.ss) was never allowed here even under the old reading —
;; it does not rewind, so the lock would be released and never retaken. The CPS
;; pass keeps them apart by treating every form that takes a thunk as opaque;
;; see jolt-sm-park!.
(define-syntax jolt-with-mutex
  (syntax-rules ()
    ((_ m e1 e2 ...)
     (let ((jwm-mu m))
       (dynamic-wind
         (lambda () (jolt-locks-enter!) (mutex-acquire jwm-mu))
         (lambda () e1 e2 ...)
         (lambda () (mutex-release jwm-mu) (jolt-locks-exit!)))))))

;; The same pair for the paths that CANNOT use the macro because they must
;; release before parking and re-acquire after — the fiber channel ops, which
;; hold the channel mutex by hand for exactly that reason.
;; The optional second argument is Chez's: (mutex-acquire mu #f) TRIES and
;; answers #f rather than blocking. The count is claimed before the attempt and
;; given back if it fails, so a failed try never leaves the carrier looking like
;; it holds something, and a successful one is never briefly uncounted.
(define jolt-lock!
  (case-lambda
    ((mu) (jolt-locks-enter!) (mutex-acquire mu))
    ((mu block?)
     (jolt-locks-enter!)
     (let ((got (mutex-acquire mu block?)))
       (unless got (jolt-locks-exit!))
       got))))
(define (jolt-unlock! mu) (mutex-release mu) (jolt-locks-exit!))

;; --- the invariant, checked where it can be broken ---------------------------
;; (jolt-locks-assert-none! who) — raise unless this carrier holds no counted
;; lock. Called by every switch point rather than by the sites that park, and
;; that placement is the point: there are two switch points and a growing number
;; of parking sites, and the ones that go wrong are the ones nobody thought of as
;; parking sites at all (a `locking` body, a validator, a load that waits).
;;
;; Complete for parks that HAPPEN, in a way the static check cannot be: it does
;; not care whether the park is lexically inside the region, one call away
;; (jolt-04ee), or inside user code the lock never wrote (jolt-3a87). If a fiber
;; is about to leave the CPU with a lock held, this is on the path.
;;
;; It RAISES, and the alternative is worth naming: the failure it replaces is a
;; process that stops dead with no error and no output, on some fraction of runs,
;; needing a sampling profiler to diagnose. Raising costs the fiber (its guard
;; marks it dead) and reports the invariant, the count, and a stack. That trade
;; is not close. The check runs before the caller's first mutation at both sites,
;; so the raise leaves the switch untaken rather than half-taken.
;;
;; Always on, never behind a flag: a check that is off in the build people ship is
;; not a check, and the cost is one virtual-register read and a fixnum compare
;; against a switch that costs ~136 ns. Measured rather than asserted, on
;; bench/fibers: the scheduler yield+slice figure spans 135.8-137.7 ns over three
;; runs with the check and reads 136.6 ns without it, so it is inside the
;; run-to-run spread; channel ping-pong and fan-in move the same way.
(define (jolt-locks-assert-none! who)
  (let ((n (jolt-locks-held)))
    (when (fx>? n 0)
      (error who
        (string-append
         "a fiber cannot leave the CPU while its carrier holds a counted lock ("
         (number->string n)
         " held). Commit under the lock and switch outside it — jolt-lock-wait,"
         " host/chez/locks.ss.")))))

;; --- waiting for state a lock guards ----------------------------------------
;; (jolt-lock-wait mu decide) -> whatever decide returns
;;
;; The one sanctioned way for a fiber to wait on state that a mutex guards, and
;; the protocol five sites had hand-rolled between them: the channel waiters
;; (java/fibers-async.ss, java/sm.ss), the object monitor and ReentrantLock
;; (java/concurrency.ss), jolt.io-poller/wait-fiber, and the load claims in
;; loader.ss — which is the one that got it wrong (jolt-04ee). Four correct
;; copies of an unnamed protocol are four chances to write a fifth.
;;
;; decide runs with mu HELD and answers either
;;
;;   jolt-lock-parked   "I have registered myself where my waker will look and
;;                       set my own state to 'parked. Switch me out, and call me
;;                       again when something resumes me."
;;   anything else       the decision, returned to the caller as-is.
;;
;; Three properties, and each one is where a hand-rolled copy can go wrong:
;;
;;   THE SWITCH IS OUTSIDE mu, so no resume carries a mutex re-acquire and the
;;   invariant above holds by construction. It is also lexically outside the
;;   jolt-with-mutex below, which is what the static check reads, so every caller
;;   inherits a shape that check can see through.
;;
;;   NO WAKEUP CAN BE LOST, because registering and committing to 'parked both
;;   happen under the same mu the waker must take. A resume landing in the window
;;   between the release and the switch finds the fiber 'parked, moves it to
;;   'ready and enqueues it; the switch then stores its continuation and the
;;   carrier dispatches it. A preemption in that window is refused, because
;;   jolt-fiber-preempt-handler refuses to preempt a fiber that is not 'running —
;;   which is why this needs no interrupt disable of its own.
;;
;;   THE DECISION IS RETAKEN, not resumed into. A wakeup means something changed,
;;   never "it is yours", so decide runs again from the top with mu held. That is
;;   also why decide must be safe to run more than once.
;;
;; A THREAD needs none of this and is not sent a different way: inside decide it
;; waits on a condition variable, which releases mu atomically with blocking and
;; holds it again on return, loops there, and answers a real value — so it never
;; reaches the branch below. One function serves both contenders and the entire
;; difference between them is that one branch.
(define jolt-lock-parked (list 'jolt-lock-parked))   ; unique; never a decision

(define (jolt-lock-wait mu decide)
  (let retake ()
    (let ((r (jolt-with-mutex mu (decide))))
      (if (eq? r jolt-lock-parked)
          ;; mu is released here. jolt-current-fiber still answers this fiber —
          ;; the switch is what clears that register — and the state it needs is
          ;; already 'parked, set by decide under mu.
          (begin (jolt-fiber-to-scheduler! (jolt-current-fiber))
                 (retake))
          r))))
