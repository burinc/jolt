;; coll-shapes — OPERATIONS CLOJURE ANSWERS FROM A COLLECTION'S SHAPE. Each one
;; here is O(1), O(log n) or O(k) on the JVM and was O(n) in jolt until 2026-10,
;; where n is the size of a collection the operation barely touches:
;;
;;   (into v (list x))        TransientVector shares v's trie; jolt copied all of v
;;   (into v [x])             a one-chunk append, not an RRB concat
;;   (pop q) at the boundary  the rear vector becomes the front; jolt reversed a list
;;   (hash q)                 cached, like every other persistent collection
;;   (difference small big)   walks the smaller set
;;   (count list)             PersistentList stores its count
;;   (count (range n))        LongRange, RSeq, StringSeq are Counted
;;   (= v longer-list)        Counted on both sides: a size mismatch answers at once
;;   (first hash-map)         NodeSeq is lazy; jolt filled a vector of every entry
;;   (first sorted-map)       PersistentTreeMap$Seq is a stack walk, (rseq sm) too
;;   (hash sorted-map)        cached, and = compares counts before walking
;;   (nthrest v k)            IDrop: an index jump on vectors, ranges, strings
;;   (case s ...)             a hash switch, not one test per branch
;;
;; Every loop does a FIXED number of operations against collections of size n,
;; so a shape-answered implementation is roughly flat in n and a walking one is
;; linear per operation (quadratic for the accumulator loops). A return to
;; walking shows up as a large regression in the release bench gate rather than
;; as noise elsewhere. test/complexity_test.clj and the per-area gates
;; (transient, values, arraymap, sortedcoll) pin the same properties pass/fail;
;; this is the throughput view.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh coll-shapes 4000
(ns coll-shapes
  (:require [clojure.set :as set]))

(defmacro ^:private string-case
  "A case over k string constants \"s0\" .. \"s<k-1>\" answering the index."
  [x k]
  `(case ~x
     ~@(mapcat (fn [i] [(str "s" i) i]) (range k))
     -1))

(defn- case-dispatch [x] (string-case x 64))

(defn- build [n]
  {:v    (vec (range n))
   :q    (into clojure.lang.PersistentQueue/EMPTY (range n))
   :big  (set (range n))
   :l    (apply list (range n))
   :lv   (vec (range (inc n)))
   :m    (zipmap (range n) (range n))
   :sm   (into (sorted-map) (map (fn [i] [i i]) (range n)))
   :ss   (into (sorted-set) (range n))
   :ss2  (into (sorted-set) (range (inc n)))
   :s    (apply str (repeat n "x"))
   :keys (mapv (fn [i] (str "s" (mod i 64))) (range 64))})

;; accumulators: one small step onto a growing vector, n times
(defn- accumulate [n]
  (let [a (volatile! [])]
    (dotimes [i n] (vswap! a into (list i)))
    (+ (count @a)
       (count (reduce (fn [v i] (into v [i])) [] (range n))))))

;; the first/disj worklist: drains a set by repeatedly taking its first element
(defn- drain [s]
  (loop [s s c 0]
    (if-let [x (first s)] (recur (disj s x) (inc c)) c)))

(defn- shape-reads [{:keys [v q big l lv m sm ss ss2 s keys]} iters]
  (let [half (quot (count v) 2)
        acc (volatile! 0)
        add! (fn [x] (vswap! acc + x))]
    (dotimes [i iters]
      (add! (count (pop q)))
      (add! (if (zero? (hash q)) 0 1))
      (add! (count (set/difference #{1 2 -1} big)))
      (add! (count l))
      (add! (count (range half)))
      (add! (count (rseq v)))
      (add! (count (seq s)))
      (add! (if (= v lv) 0 1))
      (add! (key (first m)))
      (add! (key (first (seq sm))))
      (add! (key (first (rseq sm))))
      (add! (count (take 3 sm)))
      (add! (if (zero? (hash sm)) 0 1))
      (add! (if (= ss ss2) 0 1))
      (add! (first (nthrest v half)))
      (add! (first (nthnext (range (count v)) half)))
      (add! (count (drop half s)))
      (add! (case-dispatch (nth keys (mod i 64)))))
    @acc))

(defn run [state n iters]
  (+ (shape-reads state iters)
     (accumulate n)
     (drain (:big state))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 4000)
        state (build n)
        iters 150]
    (dotimes [_ 2] (run state (quot n 4) (quot iters 4)))   ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run state n iters)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "coll-shapes n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
