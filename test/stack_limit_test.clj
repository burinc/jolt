;; The stack depth limit (host/chez/rt.ss jolt-install-stack-limit!), end to
;; end through a built jolt. Run by `make stacklimit`
;; (test/chez/stack-limit-smoke.sh), one process per mode since the limit is
;; read once at startup from JOLT_STACK_LIMIT.
;;
;; Chez grows a stack on the heap without bound, so before the limit a runaway
;; non-tail recursion allocated until the kernel killed the process. The JVM
;; throws java.lang.StackOverflowError at a few thousand frames; jolt throws the
;; same Error, but only past a limit sized from memory (80% of the process's
;; memory limit by default), so legitimately deep recursion keeps working.
(ns stack-limit-test)

(defn runaway [x] (inc (runaway x)))
(defn depth [n] (if (zero? n) 0 (inc (depth (dec n)))))

(def failures (atom 0))
(defn check [label ok?]
  (when-not ok?
    (swap! failures inc)
    (println "FAIL" label)))

(defn overflow []
  (try (runaway 1) :returned
       (catch StackOverflowError e e)))

(defn runaway-mode []
  (let [t0 (System/currentTimeMillis)
        e (overflow)]
    (check "runaway recursion throws java.lang.StackOverflowError"
           (= java.lang.StackOverflowError (class e)))
    (check "it is an Error and a VirtualMachineError, not an Exception"
           (and (instance? Error e) (instance? VirtualMachineError e)
                (instance? Throwable e) (not (instance? Exception e))))
    (check "(catch Exception e) does not catch it, (catch Throwable e) does"
           (= :throwable
              (try (try (runaway 1) (catch Exception _ :exception))
                   (catch Throwable _ :throwable))))
    (check "the message names the knob"
           (some-> (ex-message e) (.contains "JOLT_STACK_LIMIT")))
    (check "the trace names the recursing fn"
           (some #(.contains (.getClassName %) "runaway") (.getStackTrace e)))
    (check "a normal call works afterwards" (= 10000 (depth 10000)))
    ;; Each overflow holds about a limit's worth of stack until it unwinds. Ten
    ;; of them, with every throwable KEPT, under a heap ceiling of six limits:
    ;; that only fits if the unwind gives the stack back and a caught
    ;; StackOverflowError does not hold on to the frames it was thrown from.
    (let [kept (vec (repeatedly 10 overflow))]
      (check "ten overflows in a row each throw StackOverflowError"
             (every? #(= java.lang.StackOverflowError (class %)) kept)))
    (check "on another thread: the future's deref raises it"
           (= java.lang.StackOverflowError
              (try @(future (runaway 1)) :returned
                   (catch Throwable t (class (or (.getCause t) t))))))
    (check "and the process still runs deep legitimate recursion"
           (= 100000 (depth 100000)))
    (println "elapsed-ms" (- (System/currentTimeMillis) t0))))

(defn -main [mode & _]
  (case mode
    "runaway" (runaway-mode)
    ;; the effective limit: bytes, or nil when disabled
    "limit" (prn (jolt.host/stack-limit))
    ;; the stack limit and the heap ceiling it defaults from (Long/MAX_VALUE: none)
    "limits" (prn [(jolt.host/stack-limit) (.maxMemory (Runtime/getRuntime))])
    ;; 1M frames under whatever limit is in effect
    "deep" (prn (depth 1000000))
    ;; 10M frames (~100MB of stack): over a 16m limit, inside no limit. Well over:
    ;; the limit is checked at collections, so it can overshoot by a nursery
    "bounded" (prn (try (depth 10000000) (catch StackOverflowError _ :stack-overflow))))
  (when (pos? @failures)
    (println @failures "failed")
    (System/exit 1))
  (println mode "ok")
  ;; the future's pool worker would otherwise hold the process up, as on the JVM
  (shutdown-agents))

(apply -main *command-line-args*)
