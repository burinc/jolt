;; parallel-colls — the SAME per-call work on eight threads at once, each on its
;; own values: a small-map `assoc`, a vector `conj`, `swap!` on the thread's own
;; atom, `str` of a number, `hash` of a fresh string, `re-find` with a literal
;; pattern, and `with-meta`. Nothing is shared between the threads, so the row
;; measures what the RUNTIME shares behind their backs: a lock or a global
;; table on any of those paths serializes eight threads that have no reason to
;; wait for each other. The one-thread time is printed above `mean:` for the
;; per-thread slowdown; `mean:` is the eight-thread wall clock.
;;
;; Eight threads always, whatever the core count, so the row means the same
;; thing on every machine (oversubscribed on a 4-core runner, which is fine for
;; a ratio between two binaries on that runner).
;;
;; What it watches in jolt: the four process-wide locks that were on these
;; paths (the metadata side table, the continuation registry, the regex cache
;; hit, Chez's `format` under `number->string`), the atom's CAS instead of a
;; per-atom mutex, and metadata as a field instead of a table write. Eight
;; threads ran 12-34x slower per thread than one on those ops before; ~2x now,
;; the rest of which is Chez's allocator lock.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh parallel-colls 200000
(ns parallel-colls)

(def threads 8)

(defn work [iters seed]
  (let [a (atom 0)
        m0 {:tag :node :line seed :col 4 :depth 1}
        v0 [1 2 3 4]
        pos {:line seed :col 1}]
    (loop [i 0 acc 0]
      (if (< i iters)
        (let [m (assoc m0 :line i)
              v (conj v0 i)
              s (str (unchecked-add seed i))
              h (hash (str "k" i))
              r (if (re-find #"[0-9]+" s) 1 0)
              w (with-meta v pos)]
          (swap! a unchecked-add i)
          (recur (inc i)
                 (unchecked-add acc
                                (unchecked-add (unchecked-add (get m :line) (count v))
                                               (unchecked-add (unchecked-add (count s) (bit-and h 1))
                                                              (unchecked-add r (:line (meta w))))))))
        (unchecked-add acc @a)))))

(defn run-threads [n iters]
  (let [fs (mapv (fn [t] (future (work iters t))) (range n))]
    (reduce (fn [acc f] (unchecked-add acc @f)) 0 fs)))

(defn timed [f]
  (let [t0 (System/currentTimeMillis)
        r (f)
        el (- (System/currentTimeMillis) t0)]
    (when (zero? r) (println "unexpected zero"))
    el))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 200000)]
    (dotimes [_ 2] (run-threads threads (quot iters 4)))  ; warmup
    (let [one (timed #(run-threads 1 iters))
          runs 3
          ts (mapv (fn [_] (timed #(run-threads threads iters))) (range runs))
          mean (quot (reduce + ts) runs)]
      (println "one thread:" one "ms; per-thread slowdown at" threads "threads:"
               (format "%.2fx" (/ (double mean) (max one 1))))
      (println "runs:" ts)
      (println "mean:" mean "ms")
      (shutdown-agents))))
