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
;; The slice: the record carries a `slice` field that R1 leaves #f — R2 owns
;; the dynamic-binding work (per the round split, dyn-binding.ss is NOT
;; touched here; the field is the place R2 fills).
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
;; next: intrusive run-queue link. slice: R2's per-fiber dynamic slice (#f).
(define-record-type jolt-fiber
  (fields (mutable state)
          thunk
          (mutable k)
          (mutable result)
          (mutable error)
          (mutable next)
          (mutable slice))
  (nongenerative jolt-fiber-v1))

;; The virtual-register slot holding the current fiber record (0 = not on a
;; fiber — a fresh thread starts every slot at fixnum 0, NOT #f). Allocated
;; with the other vregs in rt.ss (jolt-vreg-site 2 / catch-line 3 /
;; print-readably 4); this duplicate definition keeps the file self-contained
;; for the standalone gate and is a harmless re-define under the full boot.
(define jolt-vreg-current-fiber 0)

;; The single carrier's intrusive run queue (head/tail; the `next` link lives
;; in each fiber record). R5 makes this per-carrier; R1 has one carrier.
(define jolt-fiber-q-head #f)
(define jolt-fiber-q-tail #f)

;; The scheduler's resume continuation, captured fresh by jolt-fiber-run for
;; each fiber it starts and invoked exactly once when that fiber parks,
;; finishes, or dies. A global is safe because R0(d) pinned carriers: a fiber
;; can only park while ITS carrier's scheduler is running it, so there is
;; never a second writer.
(define jolt-sched-k #f)

(define (jolt-current-fiber)
  (let ((r (virtual-register jolt-vreg-current-fiber)))
    (if (eq? r 0) #f r)))

(define (jolt-fiber-enqueue! f)
  (if jolt-fiber-q-tail
      (begin (jolt-fiber-next-set! jolt-fiber-q-tail f)
             (set! jolt-fiber-q-tail f))
      (begin (set! jolt-fiber-q-head f)
             (set! jolt-fiber-q-tail f))))

(define (jolt-fiber-dequeue!)
  (let ((f jolt-fiber-q-head))
    (when f
      (set! jolt-fiber-q-head (jolt-fiber-next f))
      (unless jolt-fiber-q-head (set! jolt-fiber-q-tail #f))
      ;; clear the link so a completed fiber does not retain the queue
      (jolt-fiber-next-set! f #f))
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
;; runnable; return the record. Spawning inside a fiber is legal. The slice
;; field starts #f (R2 conveys the parent's bindings).
(define (sa-fiber-spawn thunk)
  (let ((f (make-jolt-fiber 'ready thunk #f #f #f #f #f)))
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
      (jolt-fiber-resume* f))))

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
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (jolt-sched-k))

(define (jolt-fiber-dead! f e)
  (jolt-fiber-state-set! f 'dead)
  (jolt-fiber-error-set! f e)
  (jolt-fiber-k-set! f #f)
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (jolt-sched-k))

;; (sa-fiber-run-all) -> void. Run the carrier's run queue until it drains —
;; the scheduler shape the plan names ("run ready fibers until the queue
;; drains, then block in the poller"); the poll step is R8's. A fiber that
;; parks (jolt-fiber-park!) stops the drain until resumed.
(define (sa-fiber-run-all)
  (let loop ()
    (let ((f (jolt-fiber-dequeue!)))
      (when f
        (jolt-fiber-run f)
        (loop)))))
