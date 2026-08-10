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

;; (jolt-with-mutex m body ...) — the replacement for Chez's with-mutex.
;; Deliberately a DIFFERENT NAME rather than a shadow: a shadow would make every
;; site silently safe, which is pleasant right up until the gate cannot tell
;; whether a site was considered or merely inherited the shadow. host/chez/
;; lock-check.sh requires the explicit name, so the migration is visible and the
;; count can only go down.
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
