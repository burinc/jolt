;; lazy-threads — LAZY REALIZATION AFTER A THREAD HAS EXISTED. Three lazy
;; workloads — many short chains (a few cells per iteration), one long pipeline
;; (every stage a fresh lazy seq), and a user `lazy-seq` body per element — timed
;; after a Thread has been started and joined. It need not be alive: the first
;; fork is what flips the runtime into its multi-threaded mode for the rest of
;; the process, and `seqs` measures the same machinery WITHOUT that flip.
;;
;; What it watches: a lazy cell publishes its forced tail through one word and is
;; claimed for forcing by compare-and-swap, so a thread having existed costs a
;; reader nothing. A mutex per cell — what this runtime did until 0.8.6 — reads
;; here as ~3-5x the `seqs`-style cost, most of it in the collector, which has to
;; visit every mutex it allocated. `make lazyscaling` gates the ratio inside one
;; process; this is the throughput view against the JVM, which shows no effect.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh lazy-threads 100000
(ns lazy-threads)

(def MOD 1000000007)

;; many short lazy chains: a few cells per iteration, allocated and dropped
(defn- cells [n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (+ acc (count (vec (map inc (take 3 (iterate inc i)))))))
      acc)))

;; one long chain, every stage a fresh lazy seq with a per-element closure call
(defn- pipeline [n]
  (reduce (fn [a x] (mod (+ a x) MOD)) 0
          (map (fn [x] (mod (* x 7) MOD))
               (filter odd? (map inc (range n))))))

;; a user lazy-seq body per element: the node a `lazy-seq` form makes
(defn- user-lazy [n]
  (letfn [(gen [i] (lazy-seq (when (< i n) (cons i (gen (inc i))))))]
    (reduce (fn [a x] (mod (+ a x) MOD)) 0 (gen 0))))

(defn run [n]
  (+ (cells n) (pipeline (* 4 n)) (user-lazy (* 4 n))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 100000)]
    ;; the point of this benchmark: a thread has EXISTED before anything is
    ;; timed, warmup included
    (let [t (Thread. (fn [] nil))] (.start t) (.join t))
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
      (println "lazy-threads n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
