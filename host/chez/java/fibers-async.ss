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

;; The capture counter the gate asserts on: how many continuation captures
;; happened in fiber channel ops. The immediate path never touches it.
(define jolt-fiber-chan-parks 0)

;; A waiter handler whose wake is fiber f — the fiber-wake strategy.
(define (jolt-fiber-waiter f) (alt-handler-alloc f))

;; Park on an already-registered handler whose channel mutex is RELEASED.
;; Returns mailbox slot 1: the value for a <!, #t/#f for a >!.
;; The commit-to-park decision is made under h's wmu (atomic with alt-deliver!'s
;; mailbox write + resume); the capture+switch follows outside the wmu.
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
        (set! jolt-fiber-chan-parks (+ jolt-fiber-chan-parks 1))
        (jolt-fiber-to-scheduler! f))
      (vector-ref (alt-handler-mailbox h) 1))))

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
                (jolt-fiber-waiter-wait! h))))
        (begin
          (mutex-release (async-chan-mu ch))
          r))))

;; (jolt-fiber->! ch v) -> #t | #f (closed). Fiber-side put: room or a waiting
;; taker completes immediately (no capture); a full channel registers an
;; alt-putter and parks.
(define (jolt-fiber->! ch v)
  (mutex-acquire (async-chan-mu ch))
  (let ((r (ac-try-give!/locked ch v)))
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
               (jolt-fiber-waiter-wait! h))))))))

;; The fiber wakeup strategy — alt-deliver! dispatches through this hook so
;; async.ss (loaded before fibers.ss) never forward-references a fiber
;; primitive. Installed here, after both files are loaded; no channel op can
;; run before the boot finishes loading, so the hook is always live in use.
(set! jolt-fiber-wake-fn sa-fiber-resume)
