;; test/chez/thread-tables.clj — the runtime's shared side-tables must survive
;; concurrent access. Run through jolt (wired into host/chez/smoke.sh).
;;
;; WHY THIS EXISTS. A Chez hashtable is not thread-safe. jolt keeps per-value
;; side-tables — metadata (natives-meta.ss) and the variadic fixed-arity registry
;; (seq.ss) among them — written from whatever thread the program runs on.
;; Unsynchronized mutation corrupts the table's internals, and the damage surfaces
;; later somewhere that names nothing: `nonrecoverable invalid memory reference`
;; faulting inside S_do_gc, or a hang. It presented as a hard crash of core.async's
;; own pipeline_test and predates the fibers epic.
;;
;; The workload is a pipeline sweep, because that is what actually reproduced:
;; many short-lived worker threads, per-element transducer work touching the
;; side-tables, and enough allocation that automatic collections land while a
;; write is in flight. Synthetic table hammering from threads does NOT reproduce
;; — that version was tried, passed with the mutexes reverted, and was dropped for
;; being vacuous.
(ns thread-tables
  (:require [clojure.core.async :as a]))

;; A hand-rolled transducer whose reducing fn has a VARIADIC arity. This is the
;; trigger, and it is not incidental: the variadic arity makes every creation
;; register in the fixed-arity table and every application read it back through
;; apply, from each worker thread. The built-in (map f) has no variadic arity and
;; does NOT reproduce — that version was tried first and passed unfixed.
(defn mapping [f]
  (fn [f1]
    (fn ([] (f1))
        ([result] (f1 result))
        ([result input] (f1 result (f input)))
        ([result input & inputs] (f1 result (apply f input inputs))))))

(defn pipeline-sweep
  "One pipeline through PF with N workers over SIZE inputs; returns the drained seq."
  [pf n size]
  (let [cin (a/to-chan! (range size))
        cout (a/chan 1)]
    (pf n cout (mapping identity) cin)
    (a/<!! (a/go-loop [acc []]
             (if-let [v (a/<! cout)]
               (recur (conj acc v))
               acc)))))

(defn run! []
  (doseq [[pf nm] [[a/pipeline "pipeline"] [a/pipeline-blocking "blocking"]]
          [n size] [[1 0] [1 10] [10 10] [20 10] [5 1000]]]
    (let [got (pipeline-sweep pf n size)]
      (when-not (= (range size) got)
        (println (str "THREAD-TABLES MISMATCH " nm " n=" n " size=" size))
        (System/exit 1))))
  ;; pipeline-async spawns a thread per element, the heaviest churn of the three
  (let [got (pipeline-sweep (fn [n out _ in] (a/pipeline-async n out
                                               (fn [v ch] (a/thread (a/>!! ch v) (a/close! ch)))
                                               in))
                            5 200)]
    (when-not (= (range 200) got)
      (println "THREAD-TABLES MISMATCH async")
      (System/exit 1)))
  (println "THREAD-TABLES OK"))

;; run as a script (host/chez/smoke.sh greps for the OK line)
(run!)
