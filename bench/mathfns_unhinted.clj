;; mathfns-unhinted — the twin of `mathfns` with the numeric hints removed. Same
;; two kernels, same calls, same sizes; no `^double`/`^long` on parameters or
;; returns.
;;
;; Without a proven operand nothing here can lower to a native Chez op: every
;; java.lang.Math call goes through the generic string-keyed host-static dispatch,
;; which finds the class's method table and then the method by name, per
;; invocation, and boxes across it. That is the path most code takes, and it is
;; what this row watches.
;;
;; Kept as its own suite entry, not a phase inside `mathfns`, because
;; ci/bench-gate.sh compares a ratio PER BENCHMARK: two rows are what let it see a
;; round that speeds the proven path while slowing the generic one.
;;
;; A transcription of mathfns.clj — edit the two together; what differs is exactly
;; the tags.
;;
;; Portable Clojure (jolt + JVM Clojure). The JVM still intrinsifies these; what
;; it loses without the hints is the primitive signature, so the reference is an
;; honest one for the same question.
;;   bench/run.sh mathfns-unhinted 1000000
(ns mathfns-unhinted)

(defn kernel [n]
  (loop [i 1 acc 0.0]
    (if (<= i n)
      (let [x (* i 1.0e-6)]
        (recur (inc i)
               (+ acc
                  (Math/sqrt x)
                  (Math/sin x)
                  (Math/cos x)
                  (Math/log (+ x 1.0))
                  (Math/pow x 2.0)
                  (Math/atan2 x 1.0))))
      acc)))

;; the integer half, equally unproven: nothing tells the compiler these are longs
(defn int-kernel [n]
  (loop [i 1 acc 0]
    (if (<= i n)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add (Math/abs (- i 7)) (Math/min i 1000))
               (unchecked-add (Math/max i 3)
                              (unchecked-add (Math/floorDiv i 3)
                                             (Math/floorMod i 7))))))
      acc)))

(defn run [n]
  (+ (kernel n) (* 1.0e-9 (int-kernel n))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 1000000)]
    (dotimes [_ 2] (run (quot n 2)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "mathfns-unhinted n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
