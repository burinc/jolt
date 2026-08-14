;; jolt.fibers — the fiber primitive as a public API, side by side with
;; core.async. core.async runs go bodies ON fibers when asked
;; (*go-backend* :fiber, io-thread); this namespace hands out the fiber
;; itself: spawn a body, join its value, watch its completion. Channels stay
;; in core.async — a fiber taking or putting parks through the same waiter
;; protocol whichever API spawned it, and deref on a promise/future parks
;; rather than pinning the carrier.
;;
;; What the runtime pins (host/chez/fibers.ss) and this API inherits:
;;   - a fiber is bound to its carrier (an OS thread of the pool) for life;
;;     a blocking foreign call or Thread/sleep in a body pins that carrier
;;     and strands the fibers queued behind it. Park-capable waits — channel
;;     ops, deref, jolt.socket IO — are the ones to use inside a body.
;;   - spawn conveys the caller's dynamic bindings; *txn* never conveys (a
;;     child cannot join the parent's STM transaction).
;;   - a body that throws kills its fiber: join rethrows the original error,
;;     monitor! receives it, (state f) answers :dead.
;;   - preemption is always on (a compute-bound body cannot starve its
;;     carrier); the quantum is set-preempt-ticks!, floored, never zero.
(ns jolt.fibers)

(defn spawn
  "Run (f) on a fiber and return the fiber handle immediately. The body runs
  on the carrier pool; its value or error is read back with join or
  monitor!. The caller's dynamic bindings convey; *txn* does not."
  [f]
  (jolt.host/fiber-spawn f))

(defn fiber?
  "True when x is a fiber handle."
  [x]
  (jolt.host/fiber-instance? x))

(defn current-fiber
  "The running fiber's handle, or nil when called off a fiber."
  []
  (jolt.host/current-fiber))

(defn in-fiber?
  "True when the caller is running on a fiber."
  []
  (jolt.host/fiber?))

(defn yield
  "Reschedule the current fiber behind the others on its carrier and return
  when it runs again. Rarely needed — preemption already time-slices — but a
  cooperative point in a long computation costs less than a preempt. Throws
  when called off a fiber."
  []
  (if (jolt.host/fiber?)
    (jolt.host/fiber-yield)
    (throw (ex-info "yield called off a fiber" {}))))

(defn state
  "The fiber's scheduling state: :ready (queued), :running, :parked (waiting
  to be resumed), :done (completed), or :dead (its body threw)."
  [fib]
  (jolt.host/fiber-state fib))

(defn monitor!
  "Call (cb err) exactly once when fib finishes: err is nil for a clean
  completion, the thrown error for a death. A fiber that already finished
  fires cb inline — registration cannot race the completion. The callback
  runs on the fiber's carrier; keep it short and never block in it."
  [fib cb]
  (jolt.host/fiber-monitor! fib cb))

(defn- completion
  "A promise settled with {:val v} or {:err e} when fib finishes."
  [fib]
  (let [p (promise)]
    (jolt.host/fiber-monitor! fib
      (fn [err]
        (deliver p (if err {:err err} {:val (jolt.host/fiber-result fib)}))))
    p))

(defn join
  "Wait for fib to finish; return its body's value, or rethrow its error.
  On a fiber the wait parks (the carrier keeps running other fibers); on a
  thread it blocks. With a timeout, returns timeout-val if fib is still
  running when timeout-ms elapse. Joining the current fiber throws — it
  could never finish while waiting on itself."
  ([fib]
   (when (identical? fib (jolt.host/current-fiber))
     (throw (ex-info "a fiber cannot join itself" {})))
   (let [r @(completion fib)]
     (if-let [err (:err r)]
       (throw err)
       (:val r))))
  ([fib timeout-ms timeout-val]
   (when (identical? fib (jolt.host/current-fiber))
     (throw (ex-info "a fiber cannot join itself" {})))
   (let [r (deref (completion fib) timeout-ms ::timeout)]
     (cond
       (identical? r ::timeout) timeout-val
       (:err r) (throw (:err r))
       :else (:val r)))))

(defn carrier-count
  "The carrier pool's size: the pinned count if set, else the machine's
  processor count."
  []
  (jolt.host/fiber-carrier-count))

(defn set-carrier-count!
  "Pin the carrier pool to n OS threads (nil restores the machine default).
  Read once, at the pool's first spawn — set it before spawning anything."
  [n]
  (jolt.host/fiber-carrier-count-set! n))

(defn preempt-ticks
  "The preemption quantum, in engine ticks (~0.45 ms per million)."
  []
  (jolt.host/fiber-preempt-ticks))

(defn set-preempt-ticks!
  "Set the preemption quantum in ticks; nil restores the default. Floored —
  there is no way to turn preemption off (a cooperative-only pool is an
  unbounded starvation window); effectively-cooperative wants a very large
  quantum instead."
  [n]
  (jolt.host/fiber-preempt-ticks-set! n))
