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
;; --- holding a channel mutex against preemption -----------------------------
;; async.ss states the R3 invariant: never yield while holding a channel mutex,
;; because a fiber that suspends holding it strands every later op on that
;; channel. The fiber ops honour it by hand — they release before they park.
;; PREEMPTION BREAKS THAT, since the timer suspends a fiber wherever it happens
;; to be, including mid-section.
;;
;; And it does not fail as a clean deadlock, which is what makes it dangerous.
;; Fibers on one carrier share an OS thread and Chez mutexes are recursive per
;; thread, so the next fiber's acquire SUCCEEDS and walks straight into a section
;; another fiber is halfway through. Measured before this guard existed: a
;; 4-producer/1-consumer run on one carrier stalled at 802 of 1600 values with a
;; short quantum, and hung outright with a shorter one.
;;
;; So these ops disable interrupts for exactly as long as they hold the mutex.
;; Chez defers a timer raised in here and delivers it at the enable, so the
;; preemption is postponed rather than lost. Release BEFORE re-enabling: the
;; other order reopens the window.
(define (jolt-chan-lock! ch)
  (disable-interrupts)
  (mutex-acquire (async-chan-mu ch)))
(define (jolt-chan-unlock! ch)
  (mutex-release (async-chan-mu ch))
  (enable-interrupts))

(define (jolt-chan-locked-give! ch v)
  (if (async-chan-xrf ch)
      (guard (e (#t (jolt-chan-unlock! ch) (raise e)))
        (ac-try-give!/locked ch v))
      (ac-try-give!/locked ch v)))

;; (jolt-fiber-<! ch) -> value | nil (closed). Fiber-side take: a buffered
;; value, a waiting putter, or a closed channel complete immediately (no
;; capture); an empty open channel registers an alt-taker and parks.
(define (jolt-fiber-<! ch)
  (jolt-chan-lock! ch)
  (let ((r (ac-poll!/locked ch)))
    (if (eq? r ac-poll-empty)
        (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
          (async-chan-alt-takers-set! ch (append (async-chan-alt-takers ch) (list h)))
          (ac-notify! ch)
          (if (vector-ref (alt-handler-mailbox h) 0)
              (let ((v (vector-ref (alt-handler-mailbox h) 1)))
                (jolt-chan-unlock! ch)
                v)
              (begin
                (jolt-chan-unlock! ch)
                (vector-ref (jolt-fiber-waiter-wait! h) 1))))
        (begin
          (jolt-chan-unlock! ch)
          r))))

;; (jolt-fiber->! ch v) -> #t | #f (closed). Fiber-side put: room or a waiting
;; taker completes immediately (no capture); a full channel registers an
;; alt-putter and parks.
(define (jolt-fiber->! ch v)
  (async-check-put! v)                   ; throws — keep it outside the mutex
  (jolt-chan-lock! ch)
  (let ((r (jolt-chan-locked-give! ch v)))
    (cond
      ((eq? r 'ok) (jolt-chan-unlock! ch) #t)
      ((eq? r 'closed) (jolt-chan-unlock! ch) #f)
      (else
       (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
         (async-chan-alt-putters-set! ch
           (append (async-chan-alt-putters ch) (list (cons h v))))
         (ac-notify! ch)
           (if (vector-ref (alt-handler-mailbox h) 0)
               (let ((ok (vector-ref (alt-handler-mailbox h) 1)))
                 (jolt-chan-unlock! ch)
                 ok)
              (begin
                (jolt-chan-unlock! ch)
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
    (jolt-go-chan-fiber-set! w
      (sa-fiber-spawn
       (lambda ()
         (*txn* #f)
         (let ((r (guard (e (#t (cons #f e))) (cons #t (jolt-invoke thunk)))))
           (if (car r)
               (when (not (jolt-nil? (cdr r))) (jolt-async-give w (cdr r)))
               (begin
                 (async-report-uncaught! "go/fiber body (channel closed)" (cdr r))
                 ;; Record it so a monitor can see it. This guard is what keeps a
                 ;; throwing body from killing the fiber, which is right — the
                 ;; channel still has to be closed — but it also means the fiber
                 ;; reaches jolt-fiber-done! looking like a success, and without
                 ;; this the failure would be unobservable. The sm backend
                 ;; (sm.ss jolt-sm-drive) reaches jolt-fiber-dead! instead, which
                 ;; sets the same field, so both backends report alike.
                 (jolt-fiber-error-set! (jolt-current-fiber) (cdr r))))
           (jolt-async-close! w)))))
    (jolt-fiber-ensure-carrier!)
    w))

;; --- monitoring a go block --------------------------------------------------
;; go returns its result CHANNEL, not the fiber, so a caller has no handle to
;; monitor. Rather than change what go returns (every existing program reads
;; that channel), the channel is mapped to its fiber here.
;;
;; WEAK, and keyed by the channel: a strong table would pin every go channel and
;; every fiber it ever ran for the life of the process, which on a server
;; spawning a go per request is an unbounded leak. A dropped channel takes its
;; entry with it, and the only thing lost is the ability to monitor a go block
;; nobody holds a handle to any more.
(define jolt-go-chan-fibers (make-weak-eq-hashtable))
(define jolt-go-chan-fibers-mu (make-mutex))
(define (jolt-go-chan-fiber-set! ch f)
  (with-mutex jolt-go-chan-fibers-mu (hashtable-set! jolt-go-chan-fibers ch f)))
(define (jolt-go-chan-fiber ch)
  (with-mutex jolt-go-chan-fibers-mu (hashtable-ref jolt-go-chan-fibers ch #f)))

;; (fiber-monitor ch) -> channel. Yields the throwable if the go body died, and
;; CLOSES (nil) if it completed normally — which is what makes a throwing body
;; distinguishable from one that returned nil, the whole point of this.
;;
;; A promise-style buffered(1) channel, so the value is there whether the caller
;; takes before or after the fiber finishes. Answers a closed channel for a
;; :thread-backend go or an unknown channel, so callers get nil rather than an
;; error for "not monitorable".
(define (jolt-fiber-monitor-chan ch)
  (let ((m (ac-make 1 'fixed #f))
        (f (jolt-go-chan-fiber ch)))
    (if (not f)
        (jolt-async-close! m)
        (jolt-fiber-monitor!
         f
         (lambda (err)
           (when err (jolt-async-give m (jolt-unwrap-throw err)))
           (jolt-async-close! m))))
    m))
(def-var! "clojure.core.async" "fiber-monitor" jolt-fiber-monitor-chan)

;; The R3 park, generalized to return the handler's mailbox (value + port) —
;; the alts! fiber await needs the port; <! / >! need only the value.
;; Contract unchanged otherwise: call with the channel mutex RELEASED; the
;; commit-to-park decision is atomic with alt-deliver!'s mailbox write.
(define (jolt-fiber-waiter-wait! h)
  (let ((f (jolt-current-fiber)))
    (unless f
      (error 'jolt-fiber-waiter-wait! "channel wait outside a fiber"))
    ;; Commit and park are ONE region with interrupts disabled — see
    ;; jolt-sm-commit!. The park records the depth (swish's pcb-sic) and the
    ;; resume is restored to it, so the resumed path must NOT enable again; only
    ;; the no-park path does.
    (disable-interrupts)
    (let ((park?
           (with-mutex (alt-handler-wmu h)
             (if (vector-ref (alt-handler-mailbox h) 0)
                 #f
                 (begin (jolt-fiber-state-set! f 'parked) #t)))))
      (when park?
        (jolt-fiber-bump-chan-parks! f)
        (jolt-fiber-to-scheduler! f))
      ;; Balances the disable above on BOTH paths: the park returns here when the
      ;; fiber is resumed (restored to the depth it parked at), so it owes the
      ;; same enable the no-park path does.
      (enable-interrupts)
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
