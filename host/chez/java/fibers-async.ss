;; host/chez/java/fibers-async.ss — fiber-aware <! / >! over the ONE channel
;; waiter protocol (R3, epic jolt-nvpr.4). Loaded by rt.ss AFTER async.ss and
;; fibers.ss.
;;
;; The bet: fibers consume core.async's existing callback protocol; channels
;; are not rewritten. A fiber's <! is a take that registers an alt-taker
;; handler whose `wake` is the fiber (alt-handler-alloc f); a thread's pending
;; op keeps the condvar wake. The channel core commits via claim+mailbox
;; (async.ss) and alt-deliver! decides how to wake — it never learns what a
;; fiber is. The alt-takers/alt-putters lists are the shared waiter lists.
;;
;; The immediate-completion path captures NO continuation: if the non-blocking
;; poll (take) or give (put) succeeds — a buffered value, a waiting putter, a
;; waiting taker — the fiber returns without parking, and the park counter
;; below (what the R3 gate asserts on) does not move.
;;
;; The park path closes the deliver-vs-park race with the handler's wmu: the
;; commit ("set 'parked") happens under the SAME wmu that alt-deliver! writes
;; the mailbox and resumes under. A deliver that beat the commit is seen by the
;; commit's mailbox check (no park, no capture); one that follows it observes
;; 'parked and enqueues. The capture+switch happens after releasing the wmu and
;; never re-consults the fiber state — the resume's 'ready flip only means
;; "already on the queue", and the one-shot continuation is set before the
;; switch, so run-all picks it up correctly whether it was enqueued before or
;; after the capture.
;;
;; The channel mutex is released before the park, always — never yield while
;; holding it (the R3 invariant; a fiber that parks holding the channel mutex
;; deadlocks its carrier).
;;
;; alts! is unchanged this round; R4 replaces it with a wait set.

;; The capture counter the gate asserts on — how many continuation captures
;; happened in fiber channel ops — is (jolt-fiber-chan-parks), summed over the
;; carriers in fibers.ss. Bumped here through jolt-fiber-bump-chan-parks!, which
;; touches only the parking fiber's own carrier. The immediate path never
;; touches it.

;; A waiter handler whose wake is fiber f — the fiber-wake strategy.
(define (jolt-fiber-waiter f) (alt-handler-alloc f))

;; ac-try-give!/locked can THROW — a nil value, or a transducer step raising — and
;; this path holds the channel mutex BY HAND, because it has to be able to release
;; it before parking and with-mutex cannot do that. A throw would otherwise escape
;; with the mutex held and deadlock every later op on that channel.
;; jolt-async-give is unaffected: its with-mutex releases on the unwind.
;;
;; The guard is CONDITIONAL because guard costs a call/cc per entry and this sits
;; on every fiber put. Both callers run async-check-put! before taking the mutex
;; (that hoist is what makes this safe — do not remove it), so with the nil check
;; already done the only thrower left inside ac-try-give!/locked is the transducer
;; step; the rest is a buffer push and a notify. A channel with no xform cannot
;; raise here and does not pay for the frame. The redundant async-check-put! that
;; ac-try-give!/locked still does is left alone: it guards the OTHER callers.
(define (jolt-chan-locked-give! ch v)
  (if (async-chan-xrf ch)
      (guard (e (#t (mutex-release (async-chan-mu ch)) (raise e)))
        (ac-try-give!/locked ch v))
      (ac-try-give!/locked ch v)))

;; (jolt-fiber-<! ch) -> value | nil (closed). Fiber-side take: a buffered
;; value, a waiting putter, or a closed channel complete immediately (no
;; capture); an empty open channel registers an alt-taker and parks.
(define (jolt-fiber-<! ch)
  (mutex-acquire (async-chan-mu ch))
  (let ((r (ac-poll!/locked ch)))
    (if (eq? r ac-poll-empty)
        (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
          (async-chan-alt-takers-set! ch (append (async-chan-alt-takers ch) (list h)))
          (ac-notify! ch)
          (if (vector-ref (alt-handler-mailbox h) 0)
              (let ((v (vector-ref (alt-handler-mailbox h) 1)))
                (mutex-release (async-chan-mu ch))
                v)
              (begin
                (mutex-release (async-chan-mu ch))
                (vector-ref (jolt-fiber-waiter-wait! h) 1))))
        (begin
          (mutex-release (async-chan-mu ch))
          r))))

;; (jolt-fiber->! ch v) -> #t | #f (closed). Fiber-side put: room or a waiting
;; taker completes immediately (no capture); a full channel registers an
;; alt-putter and parks.
(define (jolt-fiber->! ch v)
  (async-check-put! v)                   ; throws — keep it outside the mutex
  (mutex-acquire (async-chan-mu ch))
  (let ((r (jolt-chan-locked-give! ch v)))
    (cond
      ((eq? r 'ok) (mutex-release (async-chan-mu ch)) #t)
      ((eq? r 'closed) (mutex-release (async-chan-mu ch)) #f)
      (else
       (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
         (async-chan-alt-putters-set! ch
           (append (async-chan-alt-putters ch) (list (cons h v))))
         (ac-notify! ch)
           (if (vector-ref (alt-handler-mailbox h) 0)
               (let ((ok (vector-ref (alt-handler-mailbox h) 1)))
                 (mutex-release (async-chan-mu ch))
                 ok)
              (begin
                (mutex-release (async-chan-mu ch))
                (vector-ref (jolt-fiber-waiter-wait! h) 1))))))))

;; The fiber wakeup strategy — alt-deliver! dispatches through this hook so
;; async.ss (loaded before fibers.ss) never forward-references a fiber
;; primitive. Installed here, after both files are loaded; no channel op can
;; run before the boot finishes loading, so the hook is always live in use.
(set! jolt-fiber-wake-fn sa-fiber-resume)

;; --- R4: go on fibers, and alts! as a wait set (epic jolt-nvpr.5) -------------
;;
;; jolt-fiber-go-spawn is the :fiber backend of clojure.core.async/go-spawn
;; (the dispatcher lives in async.ss; thread stays the :thread backend). It
;; spawns the body as a fiber on the R5 carrier pool — N OS threads, each
;; looping drain-then-park (fibers.ss). Parking inside the body works ACROSS
;; function boundaries, which the JVM's state-machine go structurally cannot
;; do: any <! / >! the body (or a function it calls) hits dispatches through
;; the redefs below to jolt-fiber-<! / jolt-fiber->!, which park the fiber via
;; the R3 handler protocol.
;;
;; The pool's size is clojure.core.async/*fiber-carrier-count*, defined and
;; read in fibers.ss (host setter jolt-fiber-carrier-count-set! for tests);
;; jolt-fiber-ensure-carrier! starts it at the first :fiber go spawn.

;; (jolt-fiber-go-spawn thunk) -> buffered(1) channel. Conveys the parent's
;; dynamic slice (sa-fiber-spawn reads the spawner's bindings; *txn* is never
;; conveyed — a child spawned inside a dosync cannot join the parent's txn,
;; the same rule async-go-spawn-thread enforces for threads).
(define (jolt-fiber-go-spawn thunk)
  (let ((w (ac-make 1 'fixed #f)))
    (sa-fiber-spawn
     (lambda ()
       (*txn* #f)
       (let ((r (guard (e (#t (cons #f e))) (cons #t (jolt-invoke thunk)))))
         (if (car r)
             (when (not (jolt-nil? (cdr r))) (jolt-async-give w (cdr r)))
             (async-report-uncaught! "go/fiber body (channel closed)" (cdr r)))
         (jolt-async-close! w))))
    (jolt-fiber-ensure-carrier!)
    w))

;; The R3 park, generalized to return the handler's mailbox (value + port) —
;; the alts! fiber await needs the port; <! / >! need only the value.
;; Contract unchanged otherwise: call with the channel mutex RELEASED; the
;; commit-to-park decision is atomic with alt-deliver!'s mailbox write.
(define (jolt-fiber-waiter-wait! h)
  (let ((f (jolt-current-fiber)))
    (unless f
      (error 'jolt-fiber-waiter-wait! "channel wait outside a fiber"))
    (let ((park?
           (with-mutex (alt-handler-wmu h)
             (if (vector-ref (alt-handler-mailbox h) 0)
                 #f
                 (begin (jolt-fiber-state-set! f 'parked) #t)))))
      (when park?
        (jolt-fiber-bump-chan-parks! f)
        (jolt-fiber-to-scheduler! f))
      (alt-handler-mailbox h))))

;; The fiber alts! await: park on the already-registered shared handler and
;; return [val port]. Registered by async.ss's __do-alts with wake = the
;; fiber, so alt-deliver! resumes the fiber; this is the mirror of the thread
;; waiter's condition-wait on the same mailbox.
(define (jolt-fiber-alt-await h)
  (let ((mb (jolt-fiber-waiter-wait! h)))
    (jolt-vector (vector-ref mb 1) (vector-ref mb 2))))

;; <! / >! / <!! / >!! dispatch on "am I on a fiber?" — the vreg read (R0's 2ns
;; dispatch). On a fiber they park (the R3 primitives, and — R5's decision —
;; <!! / >!! park exactly the same way: parking a blocking take preserves its
;; observable semantics without holding the OS thread, so on a fiber there is
;; no difference between <! and <!!, or between >! and >!!); on a plain thread
;; they are the blocking ops of today, so :thread-backend go bodies (real
;; threads), bare <!! on a thread, and the conformance gate's expectations are
;; byte-for-byte unchanged.
(cca-def! "<!" (lambda (ch) (if (jolt-current-fiber) (jolt-fiber-<! ch) (jolt-async-take ch))))
(cca-def! ">!" (lambda (ch v) (if (jolt-current-fiber) (jolt-fiber->! ch v) (jolt-async-give ch v))))
(cca-def! "<!!" (lambda (ch) (if (jolt-current-fiber) (jolt-fiber-<! ch) (jolt-async-take ch))))
(cca-def! ">!!" (lambda (ch v) (if (jolt-current-fiber) (jolt-fiber->! ch v) (jolt-async-give ch v))))

;; Install the alts! fiber-await hook (see async.ss).
(set! jolt-fiber-alt-await-fn jolt-fiber-alt-await)

;; --- R8: the IO-parking host seams (epic jolt-nvpr.8) -------------------------
;; jolt.socket (stdlib, Clojure over jolt.ffi) parks a fiber on an EAGAIN by
;; asking "am I on a fiber?", registering readiness with its poller (also
;; Clojure), committing to park under the poller's table lock, then switching.
;; These names are the entire fiber surface the Clojure layer needs, and the
;; discipline is exactly the channel waiters':
;;   - the 'parked commit (fiber-park-commit!) and the wake's state read inside
;;     sa-fiber-resume are serialized by the CALLER's lock — for the poller
;;     that is its table lock, a new leaf in the lock chain (nothing the
;;     fiber-park path does takes the run-queue mutex; the poller's wake runs
;;     sa-fiber-resume AFTER releasing the table lock, so pm -> carrier-mu and
;;     the channel chain wmu -> carrier-mu share no cycle).
;;   - fiber-to-scheduler! runs OUTSIDE that lock (a fiber that parks holding
;;     the table lock deadlocks its carrier), mirroring the R3 "release before
;;     park" invariant.
(def-var! "jolt.host" "fiber?" (lambda () (if (jolt-current-fiber) #t #f)))
(def-var! "jolt.host" "current-fiber" (lambda () (or (jolt-current-fiber) jolt-nil)))
(def-var! "jolt.host" "fiber-park-commit!" (lambda () (jolt-fiber-state-set! (jolt-current-fiber) 'parked)))
;; jolt-fiber-to-scheduler! takes the fiber (it clears the current-fiber vreg
;; before capturing, so the record has to be passed in, not read afterwards).
(def-var! "jolt.host" "fiber-to-scheduler!"
  (lambda () (jolt-fiber-to-scheduler! (jolt-current-fiber))))
(def-var! "jolt.host" "fiber-resume" sa-fiber-resume)
;; Unguarded full collect for the R8 gate: System/gc swallows Chez's
;; "cannot collect when multiple threads are active" refusal (the JVM-faithful
;; guarded no-op), but the gate must SEE that refusal when the poller's blocking
;; wait is not collect-safe — a collect that fails proves it.
(def-var! "jolt.host" "gc-full!" (lambda () (sa-gc-collect)))
