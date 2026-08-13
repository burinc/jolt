;; vecops — VECTOR CONCATENATION AND SLICING, the axis no other suite measures.
;; collections churns one vector with conj/assoc; this suite makes vectors OUT
;; OF vectors: pairwise `into` concatenation, `subvec` windows consumed by
;; reduce, and a split-at-then-rejoin loop (the classic RRB workload). Today
;; every one of these is linear per operation on jolt; when pvec grows RRB
;; concat/slice AND core's `into`/`subvec` are wired through it (the follow-up
;; beads to the rrb epic), these rows are where the change shows. On the JVM,
;; `into` is linear too (core Clojure has no RRB) and `subvec` is an O(1) view
;; that retains its parent — the ratio columns stay honest about both.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh vecops 60000
(ns vecops)

;; pairwise concat: fold k chunk-vectors into one. Linear in total elements per
;; fold step today — quadratic overall in k; O(k log n) with RRB-backed into.
(defn concat-chunks [k chunk]
  (let [c (vec (range chunk))]
    (loop [i 0 acc []]
      (if (< i k)
        (recur (inc i) (into acc c))
        acc))))

;; sliding windows: subvec a big vector at striding offsets, reduce each
;; window. Measures slice construction AND read-through-a-slice.
(defn window-sums [v win stride]
  (let [n (count v)]
    (loop [i 0 acc 0]
      (if (<= (+ i win) n)
        (recur (+ i stride)
               (+ acc (reduce + 0 (subvec v i (+ i win)))))
        acc))))

;; split + rejoin: cut the vector at a moving point and join the halves
;; swapped — both halves rebuilt today, structural sharing with RRB.
(defn split-rejoin [v rounds]
  (let [n (count v)]
    (loop [i 0 v v]
      (if (< i rounds)
        (let [at (inc (mod (* (inc i) 2654435761) (dec n)))]
          (recur (inc i) (into (subvec v at) (subvec v 0 at))))
        (reduce + 0 v)))))

(defn run [n]
  (let [chunk 512
        k (quot n chunk)
        big (concat-chunks k chunk)]
    (+ (count big)
       (window-sums big 1024 512)
       (split-rejoin (vec (range (quot n 4))) 48))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 60000)]
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
      (println "vecops n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
