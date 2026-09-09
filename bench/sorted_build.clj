;; sorted-build — CONSTRUCTING sorted maps and sets: `into` a sorted-map in key
;; order and out of it (half the keys arriving twice), `into` a sorted-set, a
;; sorted-map-by with a Clojure comparator, and a replace-every-key pass over a
;; built map. `sorted-access` deliberately keeps construction out of its timed
;; region because it dwarfed the reads it measures; this is that cost on its own.
;;
;; What it watches: an insert is ONE tree walk (PersistentTreeMap.add reports a
;; found key through a box; jolt's tree-ins answers nil and fills a volatile),
;; a replace is two, and the comparator is called exactly as often as the
;; reference calls it — the corpus pins the call counts, this is their time.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh sorted-build 20000
(ns sorted-build)

(defn- build-asc [n]
  (into (sorted-map) (map (fn [i] [i i]) (range n))))

;; keys arrive out of order, and every key arrives twice: half the inserts are
;; replaces, so both walk counts are in the number
(defn- build-scrambled [n]
  (into (sorted-map) (map (fn [i] [(mod (* i 7919) n) i]) (range (* 2 n)))))

(defn- build-set [n]
  (into (sorted-set) (range n)))

;; a Clojure fn as the comparator: every comparison is a call into user code,
;; so the walk count is what this row costs
(defn- build-by [n]
  (into (sorted-map-by (fn [a b] (compare b a))) (map (fn [i] [i i]) (range n))))

;; every key present: find it, then replace its value
(defn- replace-all [sm n]
  (loop [i 0 m sm]
    (if (< i n) (recur (inc i) (assoc m i (- i))) m)))

(defn run [n]
  (let [a (build-asc n) s (build-scrambled n) ss (build-set n) b (build-by n)
        r (replace-all a n)]
    (+ (count a) (count s) (count ss) (count b)
       (key (first a)) (key (first b)) (val (first r)) (first ss))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 20000)]
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
      (println "sorted-build n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
