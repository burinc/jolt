;; The issue #1046 gate: a garbage collection that a thread parked in a
;; non-:blocking foreign call keeps from starting SAYS SO, on stderr, after
;; two seconds — instead of the process going quiet with nothing to read.
;;
;; Every thread running jolt code reaches a collection safe point within
;; microseconds. A thread inside a foreign call that is not :blocking stays
;; ACTIVE for the collector and never reaches one, so the collection every
;; other thread is waiting on cannot start until that call returns; when the
;; call is itself waiting for one of those threads (a :collect-safe callback
;; producing its answer) the two wait for each other for good, and nothing
;; surfaces unless the C side happens to carry a deadline. The runtime can see
;; the stall from the rendezvous every waiting thread passes through
;; (sa-gc-install-stall-watch!), and reports it once per stalled request.
;;
;; Three rows, one process. The .sh reads this process's stderr and pins the
;; count and the content of the reports; stdout marks the rows.
(ns ffi-gc-stall-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))

;; libc's sleep, bound twice: the one difference is the option.
(ffi/defcfn c-sleep-active   "sleep" [:uint] :uint)
(ffi/defcfn c-sleep-blocking "sleep" [:uint] :uint :blocking)

;; Enough allocation to reach several collect trip points.
(defn churn [] (dotimes [_ 400] (dorun (map str (range 2000)))))

;; ROW 1 — main parks three seconds in an unmarked sleep while a future
;; allocates. The future's first collection cannot start until the sleep
;; returns: one report, at two seconds, naming one thread and no callback.
(println "row 1: unmarked sleep, a future allocates")
(let [f (future (churn) :churned)]
  (c-sleep-active 3)
  (check "row 1: the future finished once the sleep returned" (= :churned @f)))

;; ROW 2 — the same three seconds, :blocking. The sleeping thread deactivates,
;; the future collects on its own schedule, and nothing is reported.
(println "row 2: :blocking sleep, a future allocates")
(let [f (future (churn) :churned)]
  (c-sleep-blocking 3)
  (check "row 2: the future finished" (= :churned @f)))

;; ROW 3 — the #973 / #1046 shape, on ffi-foreign-thread-helper.c: the
;; library's own thread calls back into jolt with a :collect-safe callback
;; that allocates, while the caller is parked in svc_call — unmarked, with a
;; 3.5 s deadline. The callback's collection waits for svc_call and svc_call
;; waits for the callback's answer. The report has to say that a :collect-safe
;; callback is in progress: that is the whole diagnosis.
(println "row 3: a :collect-safe callback behind an unmarked call")
(ffi/load-library (System/getenv "JOLT_FFI_FOREIGN_THREAD_HELPER"))
(ffi/defcfn svc-start "svc_start" [:pointer] :int)
(ffi/defcfn req-path "req_path" [:pointer] :string)
(ffi/defcfn svc-call-active "svc_call" [:pointer :int] :int)
(ffi/defcfn svc-call-blocking "svc_call" [:pointer :int] :int :blocking)
(def served (atom []))
(defn handle [request]
  (let [path (req-path request)]
    (churn)
    (swap! served conj path)
    200))
(def callback (ffi/foreign-callable handle [:pointer] :int :collect-safe))
(check "the library's dispatch thread started" (zero? (svc-start callback)))
(def path (ffi/string->ptr "/users/1/profile"))
(check "row 3: the unmarked call stalls until its own deadline (#973)"
       (= -1 (svc-call-active path 3500)))
;; Drain: the :blocking form lets the stalled callback collect and answer.
(check "row 3: :blocking drains the stalled callback"
       (= 200 (svc-call-blocking path 60000)))
(check "row 3: the callback ran twice on the foreign thread"
       (= 2 (count @served)))

;; ROW 4 — row 3 with the race that makes it the COMMON shape: the caller's own
;; allocation trips a collect request on the way into the unmarked call, past
;; its last safe point. The callback's thread is then activated with the
;; request already pending and traps in the callable's prologue — before any
;; jolt code on that thread has run, so before it has counted itself in — and
;; waits there. Forced here by raising the request flag by hand right before
;; the call (what S_fire_collector does from the allocator, minus the
;; allocation); the report still has to name the callback, this time from the
;; waiting thread's own continuation.
(println "row 4: the same, with the request pending before the callback's thread starts")
(jolt.host/scheme-eval-string "(#%$set-top-level-value! '$collect-request-pending #t)")
(check "row 4: the unmarked call stalls until its own deadline"
       (= -1 (svc-call-active path 3500)))
(check "row 4: :blocking drains the stalled callback"
       (= 200 (svc-call-blocking path 60000)))
(check "row 4: the callback ran twice more"
       (= 4 (count @served)))

(if (empty? @failures)
  (do (println "FFI-GC-STALL-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
