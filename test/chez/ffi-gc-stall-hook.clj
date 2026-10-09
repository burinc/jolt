;; jolt.ffi/on-gc-stall (#1292): a program takes the stalled-collection report
;; itself. The stall of ffi-gc-stall-quiet.clj, with JOLT_GC_STALL unset and a
;; reporter installed at 1.5 s: the reporter gets one map, stderr gets nothing
;; (ffi-gc-stall-test.sh reads it), and (on-gc-stall nil) puts the default back
;; so a second stall reaches neither.
(ns ffi-gc-stall-hook)

(require '[jolt.ffi :as ffi])

(ffi/defcfn c-sleep-active "sleep" [:uint] :uint)

(defn churn [] (dotimes [_ 400] (dorun (map str (range 2000)))))
(defn stall [] (let [f (future (churn) :churned)] (c-sleep-active 3) @f))

(def reports (atom []))
(def failures (atom []))
(defmacro check [label expr] `(when-not ~expr (swap! failures conj ~label)))

(check "the watch is installed" (true? (ffi/on-gc-stall #(swap! reports conj %) {:seconds 1.5})))
(check "the stall resolved" (= :churned (stall)))
(check "one report" (= 1 (count @reports)))
(let [r (first @reports)]
  (check "the report's threshold" (= 1.5 (:seconds r)))
  (check "the report's thread count" (= 1 (:threads r)))
  (check "no callback in progress" (= 0 (:callbacks r)))
  (check "the message is the runtime's"
         (and (string? (:message r))
              (.contains ^String (:message r) "has been waiting 1.5 s for 1 thread"))))

(check "nil restores the default" (true? (ffi/on-gc-stall nil)))
(check "the second stall resolved" (= :churned (stall)))
(check "the removed reporter is not called" (= 1 (count @reports)))

(check "a bad threshold is refused"
       (try (ffi/on-gc-stall identity {:seconds -1}) false
            (catch IllegalArgumentException _ true)))

(if (empty? @failures)
  (do (println "FFI-GC-STALL-HOOK OK") (flush) (System/exit 0))
  (do (doseq [f @failures] (println "FAIL:" f)) (println "reports:" @reports) (flush) (System/exit 1)))
