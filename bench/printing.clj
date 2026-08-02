;; printing — a PRINT-PATH stress test. The suite otherwise has no print axis,
;; so the per-item work the printers do between values (resolving the dynamic
;; vars that steer them) never showed up in a measurement.
;;
;; Three regimes, all of which reach the printer once per VALUE rather than once
;; per call, so per-item overhead dominates:
;;   - pr-str over scalars: hits *print-readably* per string/char
;;   - print-str into a rebound *out*: hits the *out* lookup per write
;;   - pr-str over namespaced maps: hits *print-namespace-maps* per map
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh printing 300
(ns printing)

(defn build-scalars [n]
  (mapv (fn [i]
          (case (mod i 5)
            0 (str "s" i)
            1 (keyword (str "k" i))
            2 (char (+ 97 (mod i 26)))
            3 (symbol (str "sym" i))
            (long i)))
        (range n)))

(defn build-ns-maps [n]
  (mapv (fn [i]
          {:app/id i :app/name (str "n" i) :app/tag (keyword (str "t" (mod i 7)))})
        (range n)))

;; one printer entry per element, not one per collection
(defn pr-scalars [xs]
  (loop [s (seq xs) n 0]
    (if s
      (recur (next s) (+ n (count (pr-str (first s)))))
      n)))

(defn print-into-writer [xs]
  (let [w (java.io.StringWriter.)]
    (binding [*out* w]
      (loop [s (seq xs)]
        (when s
          (print (first s))
          (recur (next s)))))
    (count (str w))))

(defn pr-ns-maps [ms]
  (loop [s (seq ms) n 0]
    (if s
      (recur (next s) (+ n (count (pr-str (first s)))))
      n)))

(defn run [iters scalars ns-maps]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (+ acc
                (pr-scalars scalars)
                (print-into-writer scalars)
                (pr-ns-maps ns-maps)))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 300)
        scalars (build-scalars 500)
        ns-maps (build-ns-maps 200)]
    (dotimes [_ 2] (run (max 1 (quot iters 4)) scalars ns-maps))   ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run iters scalars ns-maps)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "printing iters" iters "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
