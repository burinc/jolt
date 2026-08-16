;; sorted-access — SHAPE-ANSWERED COLLECTION READS. Every operation here is one
;; the collection's structure can answer without walking it, and every one of
;; them was a full traversal in jolt until 2026-08:
;;
;;   (count (seq v))      the backing vector's count less the cell's index
;;   (drop k (seq v))     an index jump, not k steps
;;   (rseq v)             a reverse view; Clojure documents it as constant time
;;   (first sorted-map)   the tree's leftmost node, one spine walk
;;   (subseq sm > k)      descend to k, then walk only what is asked for
;;
;; The JVM says all of this structurally: PersistentVector$ChunkedSeq implements
;; Counted and IDrop, RT.countFrom short-circuits on the first Counted cell, and
;; PersistentTreeMap.min() walks a spine. jolt walked in every case, which is
;; invisible to a value test — the answers were right, just derived the long way.
;;
;; This benchmark exists so a return to walking shows up as a large, obvious
;; regression rather than as a slightly slower line elsewhere: the loop performs
;; a fixed number of reads against collections that KEEP GROWING, so a
;; shape-answered implementation is roughly flat in the collection size and a
;; walking one is quadratic in the work it does.
;;
;; test/complexity_test.clj gates the same properties as a pass/fail shape; this
;; is the throughput view of them.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh sorted-access 40000
(ns sorted-access)

;; reads whose cost must not depend on how big the collection is
(defn- shape-reads [v s sm ss iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (-> acc
                 (+ (count s))                     ; Counted
                 (+ (first (drop (- (count v) 3) s))) ; IDrop, then one element
                 (+ (first (rseq v)))              ; constant-time reverse view
                 (+ (key (first sm)))              ; leftmost node
                 (+ (first ss))))                  ; leftmost node
      acc)))


;; NOT measured here: (subseq sm > k). It is still O(n) — subseq runs through the
;; eager entry vector — and at 2000 iterations over 40k entries it outweighed
;; everything above by ~100x, which would hide a regression in any of the ops
;; this benchmark exists to watch. It is bead jolt-r8tz.7; when it lands, add a
;; window-read section here.

;; Collections are built ONCE, outside the measured region, because this
;; benchmark is about the cost of READING them. Building a sorted collection is
;; its own (much larger) gap — ~50us per insert against the reference's ~0.4us,
;; because the red-black nodes are persistent vectors, so every insert allocates
;; a trie object per level of the path (bead jolt-r8tz.8). Leaving construction
;; inside the timing made it 99% of the measurement and hid the reads entirely.
(defn run [state iters]
  (let [[v s sm ss] state]
    (shape-reads v s sm ss iters)))

(defn build [n]
  (let [v (vec (range n))]
    [v (seq v)
     (into (sorted-map) (map (fn [i] [i i]) (range n)))
     (into (sorted-set) (range n))]))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 40000)
        state (build n)
        iters 20000]
    (dotimes [_ 2] (run state (quot iters 4)))           ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run state iters)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "sorted-access n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
