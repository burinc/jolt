;; host/chez/fibers.ss — the fiber primitive and single-carrier scheduler
;; (R1, epic jolt-nvpr.2).
;;
;; A fiber is a green thread sharing one OS thread (the carrier). The design is
;; pinned by R0 (fibers-r0-findings.md, corrections included):
;;   - the per-fiber slice rides in ONE Chez VIRTUAL REGISTER holding the
;;     current fiber record (a thread-parameter write is 33 ns vs 2 ns for a
;;     vreg — three writes per switch measured 8.6x and would drop the 3.4M
;;     switches/sec design point to ~350k). The slot index is
;;     jolt-vreg-current-fiber, allocated with the other vregs in rt.ss; this
;;     file re-defines the same value so the gate test can load it standalone
;;     (the duplicate define is the harmless re-define pattern rt.ss already
;;     uses for scheme-adapter-runtime.ss).
;;   - the run queue is INTRUSIVE: the fiber record carries its own next link,
;;     so the queue costs zero extra per fiber.
;;   - a fiber costs ~3.5 KB from the moment it PARKS (one Chez stack segment),
;;     not once scheduled — spawn-heavy workloads are not cheap; that is the
;;     representation, not a bug to design around.
;;   - exceptions are isolated PER FIBER: a raise inside a fiber kills that
;;     fiber (state 'dead) and never reaches the scheduler loop or the
;;     sa-fiber-run-all caller. R0(b) proved guard handler chains ride the
;;     continuation correctly on Chez, so the catch lives in the resume path.
;;   - call/1cc is the primitive (measured identical to call/cc; one-shot for
;;     the discipline it documents — a continuation is captured fresh per park
;;     and invoked exactly once per resume, so the multi-shot re-entry trap
;;     cannot happen).
;;
;; The slice: the record carries a `slice` field holding the fiber's per-fiber
;; dynamic state (a jolt-dslice record — the dyn-binding-stack value, the
;; current namespace, and the STM *txn*). R2 owns the dynamic-binding work
;; (per the round split, dyn-binding.ss is NOT touched here; the swap lives in
;; the switch below).
;;
;; Loaded from rt.ss in the usual place AND from scheme-adapter-runtime.ss
;; (which loads first, so the gate-time adaptercheck, which loads only that
;; file, sees the sa-fiber-* names bound). Self-contained: uses nothing beyond
;; Chez natives, so the gate test loads it directly.

;; --- the fiber record -------------------------------------------------------
;; state: 'ready (on the run queue) | 'running | 'parked (waiting on
;; sa-fiber-resume) | 'done | 'dead (raised; error field holds the condition).
;; thunk: the fiber body (immutable). k: the one-shot continuation captured at
;; the last park (unconsumed while 'parked). result/error: completion payload.
;; next: intrusive run-queue link. slice: R2's per-fiber dynamic slice (a
;; jolt-dslice: dyn-binding-stack value, current ns, *txn* — see below).
(define-record-type jolt-fiber
  (fields (mutable state)
          thunk
          (mutable k)
          (mutable result)
          (mutable error)
          (mutable next)
          (mutable slice))
  (nongenerative jolt-fiber-v1))

;; --- the per-fiber dynamic slice ---------------------------------------------
;; R2 (jolt-nvpr.3). jolt's `binding` macro pushes by calling the
;; dyn-binding-stack thread parameter as a SETTER, and a setter write is not
;; undone by a continuation escape (R0(a)): a fiber that parks inside a binding
;; leaves its frames on the carrier, visible to the scheduler and to every
;; other fiber, and a second fiber popping its own frame can pop the parked
;; fiber's. `set-chez-ns!` leaks the same way. The swap below saves the fiber's
;; slice on switch-out and restores the incoming party's on switch-in.
;;
;; The scheduler's own slice is captured per sa-fiber-run-all entry, so the
;; carrier reverts to the CALLER's state between fibers (the parked-fiber leak
;; regression). *txn* is parameterize-managed inside dosync, so it unwinds on
;; park on its own (R0(a)) — its two jobs in the slice are: a fiber parked
;; inside a dosync resumes INSIDE its txn, and sa-fiber-spawn does NOT convey
;; it (async-go-spawn parity: a child whose first dosync joined the parent's
;; txn would write into the parent's log).
;;
;; Writes are diffed with eq?: a thread-parameter WRITE is ~33 ns vs ~2 ns to
;; read (R0(c)), so a swap between two parties with identical slices — the
;; common case — costs a few reads and zero writes.
(define-record-type jolt-dslice
  (fields (mutable stack) (mutable ns) (mutable txn))
  (nongenerative jolt-dslice-v1))

;; The virtual-register slot holding the current fiber record (0 = not on a
;; fiber — a fresh thread starts every slot at fixnum 0, NOT #f). Allocated
;; with the other vregs in rt.ss (jolt-vreg-site 2 / catch-line 3 /
;; print-readably 4); this duplicate definition keeps the file self-contained
;; for the standalone gate and is a harmless re-define under the full boot.
(define jolt-vreg-current-fiber 0)
;; Slot 1: non-zero while a PARK escape is unwinding this carrier. Read by the
;; try/finally after-thunk (values.ss jolt-park-unwinding?) so a park does not
;; run cleanup that belongs to the real exit. A vreg and not a global because R5
;; runs several carriers, each of which can be mid-park independently.
(define jolt-vreg-park-unwinding 1)
(define (jolt-park-unwinding-set! on?)
  (set-virtual-register! jolt-vreg-park-unwinding (if on? 1 0)))
;; Installed only when the full runtime is present; a standalone load of this
;; file (the R1 gate) has no values.ss, and the guard keeps that working — the
;; same probe pattern this file already uses for the slice parameters.
(guard (e (#t #f))
  (set! jolt-park-unwinding?-hook
        (lambda () (eqv? 1 (virtual-register jolt-vreg-park-unwinding)))))

;; The single carrier's intrusive run queue (head/tail; the `next` link lives
;; in each fiber record). R3 makes it thread-safe: a channel delivery to a
;; fiber-waiter (alt-deliver! in async.ss) resumes the fiber — enqueues it —
;; and that can run on ANY thread (a putter delivering to a parked fiber-taker)
;; while the carrier is mid-dequeue, so the head/tail pair is guarded by a leaf
;; mutex. Lock order: ... → run-queue mu is ALWAYS the last lock acquired; the
;; enqueue/dequeue below never acquire anything else, so the order never
;; cycles. R5 (work stealing) may swap this for a lock-free queue.
;;
;; jolt-fiber-q-cv is the R4 carrier's park: the carrier thread waits on it
;; when the queue is empty (never a spin) and jolt-fiber-enqueue! signals it
;; on the empty→non-empty transition. Both sides hold q-mu, so a wake cannot
;; be lost between the carrier's empty check and its wait.
(define jolt-fiber-q-mu (make-mutex))
(define jolt-fiber-q-cv (make-condition))
(define jolt-fiber-q-head #f)
(define jolt-fiber-q-tail #f)

;; The scheduler's resume continuation, captured fresh by jolt-fiber-run for
;; each fiber it starts and invoked exactly once when that fiber parks,
;; finishes, or dies. A global is safe because R0(d) pinned carriers: a fiber
;; can only park while ITS carrier's scheduler is running it, so there is
;; never a second writer.
(define jolt-sched-k #f)

;; The three thread parameters that make up a fiber's dynamic slice live in
;; other host files (dyn-binding.ss's dyn-binding-stack, multimethods.ss's
;; chez-current-ns-param, refs.ss's *txn*). The full boot defines all three
;; BEFORE this file's last load (rt.ss loads fibers.ss last), so these
;; references capture the real parameters there; a standalone load (the R1
;; gate, or scheme-adapter-runtime.ss before the rest of rt.ss) sees them
;; unbound and gets a private fallback parameter instead — behaviorally
;; identical for the R1 semantics, and rt.ss's later re-load of this file
;; re-captures the real ones (the harmless re-define pattern this file already
;; uses for jolt-vreg-current-fiber). The probe is a guard on the reference,
;; not top-level-bound? (blocklisted: fibers.ss is not a target-owned file).
(define jolt-slice-stack-param
  (guard (e (#t (make-thread-parameter '())))
    dyn-binding-stack))
(define jolt-slice-ns-param
  (guard (e (#t (make-thread-parameter "user")))
    chez-current-ns-param))
(define jolt-slice-txn-param
  (guard (e (#t (make-thread-parameter #f)))
    *txn*))

;; The scheduler's own slice — the caller's dynamic state at sa-fiber-run-all
;; entry — kept in one mutable record so the per-run capture allocates nothing.
(define jolt-sched-slice (make-jolt-dslice #f #f #f))
(define (jolt-sched-slice-capture!)
  (jolt-dslice-stack-set! jolt-sched-slice (jolt-slice-stack-param))
  (jolt-dslice-ns-set! jolt-sched-slice (jolt-slice-ns-param))
  (jolt-dslice-txn-set! jolt-sched-slice (jolt-slice-txn-param)))

;; Save the CURRENT carrier values into fiber f's slice record. Runs in f's own
;; dynamic context, BEFORE the switch invokes the scheduler continuation — the
;; parameterize unwind fires as part of that invocation, so reading earlier is
;; the only way to capture a txn a fiber is parked inside.
(define (jolt-fiber-slice-save! f)
  (let ((s (jolt-fiber-slice f)))
    (jolt-dslice-stack-set! s (jolt-slice-stack-param))
    (jolt-dslice-ns-set! s (jolt-slice-ns-param))
    (jolt-dslice-txn-set! s (jolt-slice-txn-param))))

;; Restore the carrier to slice s's values. Writes are diffed with eq?: a
;; thread-parameter WRITE is ~33 ns vs ~2 ns to read (R0(c)), so a swap between
;; two fibers with identical slices (the common case — empty stacks, same ns,
;; no txn) costs the reads and zero writes. eq? can only skip a write when the
;; carrier already holds the exact object, so it can never miss a change.
(define (jolt-fiber-slice-restore! s)
  (when s
    (let ((v (jolt-dslice-stack s)))
      (unless (eq? v (jolt-slice-stack-param)) (jolt-slice-stack-param v)))
    (let ((v (jolt-dslice-ns s)))
      (unless (eq? v (jolt-slice-ns-param)) (jolt-slice-ns-param v)))
    (let ((v (jolt-dslice-txn s)))
      (unless (eq? v (jolt-slice-txn-param)) (jolt-slice-txn-param v)))))

(define (jolt-current-fiber)
  (let ((r (virtual-register jolt-vreg-current-fiber)))
    (if (eq? r 0) #f r)))

(define (jolt-fiber-enqueue! f)
  (mutex-acquire jolt-fiber-q-mu)
  (if jolt-fiber-q-tail
      (begin (jolt-fiber-next-set! jolt-fiber-q-tail f)
             (set! jolt-fiber-q-tail f))
      ;; empty -> non-empty: wake the R4 carrier if it is parked on q-cv
      (begin (condition-signal jolt-fiber-q-cv)
             (set! jolt-fiber-q-head f)
             (set! jolt-fiber-q-tail f)))
  (mutex-release jolt-fiber-q-mu))

(define (jolt-fiber-dequeue!)
  (mutex-acquire jolt-fiber-q-mu)
  (let ((f jolt-fiber-q-head))
    (when f
      (set! jolt-fiber-q-head (jolt-fiber-next f))
      (unless jolt-fiber-q-head (set! jolt-fiber-q-tail #f))
      ;; clear the link so a completed fiber does not retain the queue
      (jolt-fiber-next-set! f #f))
    (mutex-release jolt-fiber-q-mu)
    f))

;; --- the switch -------------------------------------------------------------
;; Symmetric two-party switch over call/1cc. Each side captures a fresh
;; continuation per park; the parked continuation is invoked exactly once by
;; the scheduler's resume path, so no continuation is ever invoked twice (the
;; one-shot discipline — a multi-shot re-entry would return into the caller's
;; half-finished expression and re-run it, the exact trap the plan warns
;; about). Chez represents a continuation as a lazily-split stack segment, so
;; capture is O(1) and depth-independent (R0: identical cost at 1 and 40
;; frames).

;; Park the CURRENT fiber: capture its continuation, hand control to the
;; scheduler (invoking the continuation fiber-run captured when it started
;; this fiber). The fiber's state is set by the caller BEFORE the switch
;; (yield -> 'ready + enqueue; park -> 'parked).
(define (jolt-fiber-to-scheduler! f)
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (call/1cc
    (lambda (k)
      (jolt-fiber-k-set! f k)
      (jolt-fiber-slice-save! f)
      ;; The dynamic-wind after-thunks between here and the scheduler are about
      ;; to fire as this continuation unwinds. They belong to forms the fiber is
      ;; still inside, so flag the escape as a park and let them skip.
      (jolt-park-unwinding-set! #t)
      (jolt-sched-k))))

;; (sa-fiber-yield) -> void. Park the current fiber and move it to the back of
;; the run queue (round-robin); returns when the scheduler resumes it. An
;; error outside a fiber — the vreg read is the "am I on a fiber?" dispatch
;; R0's design calls out.
(define (sa-fiber-yield)
  (let ((f (jolt-current-fiber)))
    (if f
        (begin (jolt-fiber-state-set! f 'ready)
               (jolt-fiber-enqueue! f)
               (jolt-fiber-to-scheduler! f))
        (error 'sa-fiber-yield "yield called outside a fiber"))))

;; Park WITHOUT re-enqueuing: the fiber is not runnable until sa-fiber-resume.
;; Internal for R1 — this is the park shape R3's channel waiters use (a take!
;; whose callback resumes the fiber) — and what makes sa-fiber-resume real.
(define (jolt-fiber-park!)
  (let ((f (jolt-current-fiber)))
    (if f
        (begin (jolt-fiber-state-set! f 'parked)
               (jolt-fiber-to-scheduler! f))
        (error 'jolt-fiber-park! "park called outside a fiber"))))

;; (sa-fiber-resume f) -> void. Make a PARKED fiber runnable again (enqueue).
;; A no-op when the fiber is already runnable — a double wakeup (a value and a
;; timeout both firing is exactly the R4 alts! commit race) must not corrupt
;; the queue.
(define (sa-fiber-resume f)
  (when (eq? (jolt-fiber-state f) 'parked)
    (jolt-fiber-state-set! f 'ready)
    (jolt-fiber-enqueue! f)))

;; (sa-fiber-spawn thunk) -> fiber. Create a fiber running THUNK and make it
;; runnable; return the record. Spawning inside a fiber is legal. The child's
;; slice CONVEYS the parent's current dynamic state (the carrier's live values
;; at spawn — reading the params in the parent's context), exactly as
;; async-go-spawn snapshots (dyn-binding-stack) for a thread today; *txn* is
;; always #f so a child spawned inside a dosync cannot join the parent's
;; transaction (ref-sets into the parent's log would be committed by the
;; parent, not the child).
(define (sa-fiber-spawn thunk)
  (let ((f (make-jolt-fiber
            'ready thunk #f #f #f #f
            (make-jolt-dslice (jolt-slice-stack-param)
                              (jolt-slice-ns-param)
                              #f))))
    (jolt-fiber-enqueue! f)
    f))

;; --- the scheduler ----------------------------------------------------------
;; Resume (or first-run) fiber f, returning to the loop when f parks,
;; finishes, or dies.
(define (jolt-fiber-run f)
  (set-virtual-register! jolt-vreg-current-fiber f)
  (call/1cc
    (lambda (k)
      (set! jolt-sched-k k)
      ;; scheduler -> fiber: restore the incoming fiber's slice BEFORE running
      ;; it (for a resume, before its continuation re-enters — the dynamic-wind
      ;; before-thunks then re-fire over the restored values)
      (jolt-fiber-slice-restore! (jolt-fiber-slice f))
      (jolt-fiber-resume* f)))
  ;; Back on the scheduler: whatever escape brought us here is over.
  (jolt-park-unwinding-set! #f)
  ;; The fiber parked, finished, or died: its setter-written dynamic state
  ;; (binding frames, current ns) is still live on the carrier — a continuation
  ;; escape does not undo a setter write (R0(a)). fiber -> scheduler: revert to
  ;; the scheduler's slice so the carrier between fibers is the CALLER's state.
  (jolt-fiber-slice-restore! jolt-sched-slice))

;; Per-fiber exception isolation: the guard frame sits BELOW the fiber's own
;; frames and is part of the fiber's captured continuation, so it catches a
;; raise whether the fiber is on its first run or resumed from a park — and a
;; raise the fiber's own handlers do not catch kills the fiber, not the
;; scheduler. R0(b) verified guard chains ride the continuation correctly.
;; The discriminator is the continuation, not the state: a fiber that yielded
;; is 'ready AND holds a captured k, so it must be resumed at the park point —
;; re-applying the thunk would re-run it from scratch (an infinite loop). Only
;; a 'ready fiber with NO k is a first run. 'parked fibers are never dequeued:
;; sa-fiber-resume moves them to 'ready before enqueue.
(define (jolt-fiber-resume* f)
  (case (jolt-fiber-state f)
    ((ready)
     (if (jolt-fiber-k f)
         ((jolt-fiber-k f))
         (begin
           (jolt-fiber-state-set! f 'running)
           (let ((r (guard (e (#t (jolt-fiber-dead! f e)))
                      ((jolt-fiber-thunk f)))))
             (jolt-fiber-done! f r)))))
    (else (error 'jolt-fiber-run "fiber in unexpected state"
                 (jolt-fiber-state f)))))

;; Completion paths: mark the fiber, drop the consumed continuation, clear the
;; current-fiber vreg (the scheduler owns the CPU now — a stale vreg would make
;; a later yield from a non-fiber context enqueue a dead fiber and invoke the
;; consumed sched-k), then hand control back to the scheduler.
(define (jolt-fiber-done! f r)
  (jolt-fiber-state-set! f 'done)
  (jolt-fiber-result-set! f r)
  (jolt-fiber-k-set! f #f)
  (jolt-fiber-slice-set! f #f)
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (jolt-sched-k))

(define (jolt-fiber-dead! f e)
  (jolt-fiber-state-set! f 'dead)
  (jolt-fiber-error-set! f e)
  (jolt-fiber-k-set! f #f)
  (jolt-fiber-slice-set! f #f)
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (jolt-sched-k))

;; (sa-fiber-run-all) -> void. Run the carrier's run queue until it drains —
;; the scheduler shape the plan names ("run ready fibers until the queue
;; drains, then block in the poller"); the poll step is R8's. A fiber that
;; parks (jolt-fiber-park!) stops the drain until resumed. The scheduler's
;; slice is captured at entry — the caller's dynamic state, which every park
;; restores onto the carrier.
(define (sa-fiber-run-all)
  (jolt-sched-slice-capture!)
  (let loop ()
    (let ((f (jolt-fiber-dequeue!)))
      (when f
        (jolt-fiber-run f)
        (loop)))))

;; --- the R4 carrier (epic jolt-nvpr.5) ---------------------------------------
;; R3 found that sa-fiber-run-all is a ONE-SHOT drain, not a scheduler: a
;; cross-thread wake lands a fiber on the queue after the drain returned and
;; nothing runs it (the R3 gate had to pump). R4's go-on-fibers therefore
;; needs a carrier that LOOPS. Exactly ONE carrier thread, started lazily on
;; the first :fiber go spawn (jolt-fiber-ensure-carrier!, called from
;; jolt-fiber-go-spawn in fibers-async.ss) and parked on jolt-fiber-q-cv when
;; the run queue is empty — never a spin; a wake (enqueue) signals it. The
;; carrier pool and the blocking policy are R5's, not this round's.
;;
;; The loop is run-all-then-park: drain the queue, and if it is empty, wait on
;; the condition. The check and the wait both hold q-mu, so an enqueue cannot
;; slip between them: it either lands before the check (the carrier sees a
;; non-empty queue and does not wait) or signals the condition the carrier is
;; (or is about to be) waiting on.
(define (jolt-fiber-carrier-loop)
  (let loop ()
    (sa-fiber-run-all)
    (mutex-acquire jolt-fiber-q-mu)
    (unless jolt-fiber-q-head
      (condition-wait jolt-fiber-q-cv jolt-fiber-q-mu))
    (mutex-release jolt-fiber-q-mu)
    (loop)))

;; Start the carrier exactly once, on the first :fiber go spawn. Double-start
;; is guarded by its own mutex (the started? flag); the carrier thread inherits
;; the spawner's thread parameters at fork, which is irrelevant here — every
;; run-all re-captures the scheduler slice at entry.
(define jolt-fiber-carrier-mu (make-mutex))
(define jolt-fiber-carrier-started? #f)
(define (jolt-fiber-ensure-carrier!)
  (mutex-acquire jolt-fiber-carrier-mu)
  (unless jolt-fiber-carrier-started?
    (set! jolt-fiber-carrier-started? #t)
    (fork-thread jolt-fiber-carrier-loop))
  (mutex-release jolt-fiber-carrier-mu))
