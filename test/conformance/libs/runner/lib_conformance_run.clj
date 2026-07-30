;; In-process test runner for a third-party library's clojure.test suite.
;;
;; Invoked by run.clj as `-m lib-conformance-run <timeout-ms> <preload-csv>
;; <ns>...`, where preload-csv is "-" when there is nothing to preload. Loads each
;; test namespace separately so a namespace that will not load is reported as a
;; LOAD-FAIL against its own name instead of aborting the whole suite, then runs
;; the loaded namespaces one at a time so counts are attributable.
;;
;; A preload is a jolt-side namespace the library needs in place before it loads —
;; typically one that registers a host class the library reaches for through
;; interop. It is required first and is not a test namespace, so it never counts.
;;
;; Machine-readable lines the driver greps (everything else is suite output kept
;; for triage):
;;   NS <ns> LOAD-FAIL <message>
;;   NS <ns> tests=N pass=N fail=N error=N
;;   TOTAL tests=N pass=N fail=N error=N load-fail=N
(ns lib-conformance-run
  (:require [clojure.string]
            [clojure.test :as t]))

(defn- msg-of [e]
  (or (ex-message e)
      (try ((resolve 'jolt.host/condition-message) e) (catch :default _ nil))
      (pr-str e)))

(defn- watchdog!
  "A suite that hangs must not hang the gate: exit 3 after ms with a marker the
  driver can see. The sleeping thread is a plain future — nothing joins it."
  [ms]
  (when (pos? ms)
    (future
      (Thread/sleep ms)
      (println "TIMEOUT after" ms "ms")
      (flush)
      (System/exit 3))))

(defn -main [& args]
  (let [[t-ms preload & nses] args
        timeout (try (Long/parseLong t-ms) (catch :default _ 0))]
    (watchdog! timeout)
    (doseq [p (remove empty? (clojure.string/split (or preload "-") #","))
            :when (not= p "-")]
      (try (require (symbol p))
           (catch :default e (println "PRELOAD" p "FAILED" (msg-of e)))))
    (let [loaded (reduce (fn [acc n]
                           (let [sym (symbol n)]
                             (try (require sym)
                                  (conj acc sym)
                                  (catch :default e
                                    (println "NS" n "LOAD-FAIL" (msg-of e))
                                    acc))))
                         [] nses)
          totals (reduce (fn [acc sym]
                           (let [r (try (t/run-tests sym)
                                        (catch :default e
                                          (println "NS" sym "LOAD-FAIL" (msg-of e))
                                          nil))]
                             (if r
                               (do (println (str "NS " sym
                                                 " tests=" (:test r) " pass=" (:pass r)
                                                 " fail=" (:fail r) " error=" (:error r)))
                                   (merge-with + acc (select-keys r [:test :pass :fail :error])))
                               acc)))
                         {:test 0 :pass 0 :fail 0 :error 0}
                         loaded)]
      (println (str "TOTAL"
                    " tests=" (:test totals) " pass=" (:pass totals)
                    " fail=" (:fail totals) " error=" (:error totals)
                    " load-fail=" (- (count nses) (count loaded))))
      (flush)
      (System/exit 0))))
