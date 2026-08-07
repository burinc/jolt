;; image-refs — jolt.image dump + restore of a ref-heavy graph: n refs holding
;; small vectors inside one map. Times the write-side walk (descriptor
;; substitution), fasl, and the restore-side re-mint — the cold path the
;; refs-travel-by-value work touches directly.
;;
;; jolt-only (jolt.host image seam).
;;   bench/run.sh image-refs 10000
(ns image-refs)

(def path "/tmp/jolt-bench-image-refs.jimg")

(defn run [n]
  (let [g (loop [i 0 acc {}]
            (if (< i n)
              (recur (inc i) (assoc acc i (ref [i (inc i)])))
              acc))]
    (jolt.host/image-write! path g)
    (let [r (jolt.host/image-read path)]
      @(get r (dec n)))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 10000)]
    (dotimes [_ 1] (run (quot n 4)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "image-refs n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
