;; Complexity gates: operations that must NOT be linear in the collection's size.
;;
;; Each of these was O(n) in jolt while the reference answers it from the shape,
;; and every one is invisible to a value test — the results were correct all
;; along, just derived by walking. Over 200k elements:
;;
;;   (count (seq v))        18.8ms   JVM 166ns   PersistentVector$ChunkedSeq is Counted
;;   (drop k (seq v))       18.5ms   JVM 625ns   ...and IDrop
;;   (rseq v)               19.8ms   JVM 209ns   rseq is documented as constant time
;;   (first sorted-map)      190ms   JVM 416ns   PersistentTreeMap.min() walks one spine
;;   (first sorted-set)       94ms   JVM 542ns
;;
;; The gate is the SHAPE, measured in one process: run each op at n and at 4n and
;; compare. A constant-time op holds near 1.0 and an O(log n) one barely moves
;; (4x the elements is two more levels of a ~17-deep tree); the linear versions
;; these replaced all sat near 4.0, so the ceiling has a wide margin either side
;; and does not depend on absolute timings, which differ per machine and flake
;; under parallel CI.
;;
;; Ops are repeated so the fast cases clear jolt's ~1us timer granularity —
;; several of them now measure as zero for a single call.

(ns complexity-test)

(def ^:private n1 50000)
(def ^:private n2 200000)
(def ^:private reps 2000)
(def ^:private max-ratio 2.0)

(defn- timed [f]
  (let [t (System/nanoTime)]
    (f)
    (- (System/nanoTime) t)))

(defn- best-of [k f]
  (f)                                     ; warm
  (reduce min (map (fn [_] (timed f)) (range k))))

(def ^:private failures (atom 0))

(defn- judge [label t1 t4 detail]
  (let [ratio (double (/ (max 1 t4) (max 1 t1)))]
    (println (format "complexity %-22s %5dms at n, %5dms at 4n, ratio %5.2f (flat ~1.0, linear ~4.0, ceiling %.1f)"
                     label (quot t1 1000000) (quot t4 1000000) ratio max-ratio))
    (when (> ratio max-ratio)
      (println (str "FAIL complexity " label ": " detail))
      (swap! failures inc))))

(defn -main [& _]
  (let [v1 (vec (range n1))            v2 (vec (range n2))
        s1 (seq v1)                    s2 (seq v2)
        sm1 (into (sorted-map) (map (fn [i] [i i]) (range n1)))
        sm2 (into (sorted-map) (map (fn [i] [i i]) (range n2)))
        ss1 (into (sorted-set) (range n1))
        ss2 (into (sorted-set) (range n2))]

    ;; values first — a ratio over wrong answers would mean nothing
    (when-not (and (= (count s1) n1) (= (count s2) n2)
                   (= (first (drop (- n1 2) s1)) (- n1 2))
                   (= (first (rseq v1)) (dec n1))
                   (= (last (rseq v1)) 0)
                   (= (first sm1) [0 0]) (= (first ss1) 0)
                   (= (first (sorted-map)) nil) (= (first (sorted-set)) nil))
      (println "FAIL complexity: wrong values before timing")
      (System/exit 1))

    (judge "count vector-seq"
           (best-of 3 #(dotimes [_ reps] (count s1)))
           (best-of 3 #(dotimes [_ reps] (count s2)))
           "count is walking a vector-backed seq instead of subtracting its index from the backing vector's count (collections.ss)")

    (judge "drop vector-seq"
           (best-of 3 #(dotimes [_ reps] (drop (- n1 5) s1)))
           (best-of 3 #(dotimes [_ reps] (drop (- n2 5) s2)))
           "drop is stepping instead of jumping to the index (jolt-drop, seq.ss)")

    (judge "rseq vector"
           (best-of 3 #(dotimes [_ reps] (rseq v1)))
           (best-of 3 #(dotimes [_ reps] (rseq v2)))
           "rseq is materializing the vector — Clojure documents it as constant time (jolt-rseq, natives-seq.ss)")

    (judge "first sorted-map"
           (best-of 3 #(dotimes [_ reps] (first sm1)))
           (best-of 3 #(dotimes [_ reps] (first sm2)))
           "first on a sorted map is materializing the tree instead of walking to its leftmost node (25-sorted.clj :first, routed via host-table.ss)")

    (judge "first sorted-set"
           (best-of 3 #(dotimes [_ reps] (first ss1)))
           (best-of 3 #(dotimes [_ reps] (first ss2)))
           "first on a sorted set is materializing the tree instead of walking to its leftmost node (25-sorted.clj :first)")

    (if (pos? @failures)
      (do (println (str "complexity: " @failures " section(s) failed"))
          (System/exit 1))
      (println "complexity: passed"))))

(-main)
