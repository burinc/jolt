;; stm — ref/STM throughput: ref creation, transactional ref-set/alter, and
;; plain deref in a tight loop. Isolates the ref record allocation and the
;; txn log/commit path; the image-format work (refs travel by value) must not
;; move any of these.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh stm 200000
(ns stm)

(defn run [n]
  ;; creation: n fresh refs, keep a few alive so allocation is real
  (let [rs (loop [i 0 acc []]
             (if (< i 32) (recur (inc i) (conj acc (ref 0))) acc))
        r (first rs)]
    (loop [i 0]
      (when (< i n)
        (ref 0)
        (recur (inc i))))
    ;; txn writes: one ref-set + one alter per iteration
    (loop [i 0]
      (when (< i n)
        (dosync (ref-set r i) (alter r inc))
        (recur (inc i))))
    ;; reads: plain deref (no txn) over the batch
    (loop [i 0 acc 0]
      (if (< i n)
        (recur (inc i) (+ acc @r @(peek rs)))
        acc))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 200000)]
    (dotimes [_ 2] (run (quot n 4)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "stm n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
