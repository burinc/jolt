;; keyed-lookup — the SCALAR-KEY workload: hashing and comparing keywords, symbols
;; and strings, and looking them up in small maps. Minimal per-iteration work
;; besides the key operations, so the hash engine and the equality fast paths
;; dominate rather than any collection algorithm.
;;
;; This is the regime none of the other benchmarks reach. `collections` churns
;; large HAMTs, where the cost is trie structure and the per-key hash is amortised
;; across 32-way nodes; here the maps are 3-8 entries, every iteration hashes a key,
;; and the trie is one level deep. Two things only show up at that size:
;;
;;   - a SYMBOL key built for one lookup and discarded. Keywords are interned and
;;     carry a precomputed hash; symbols are not interned, so a fresh one pays a
;;     full Murmur3 over its name every time. jolt-hasheq and jolt=2 answering
;;     symbols on their fast paths, and symbol-t carrying a khash field, are what
;;     this measures.
;;   - a COLLECTION or a keyword-valued LOCAL in head position, (m k) and (k m),
;;     rather than the literal (:k m) the back end lowers directly.
;;
;; The shape is honeysql's, which is where it came from. honey.sql/format-dsl walks
;; 92 clause keys per format call and, for each key NOT in the statement map, does
;; (get leftover (kw->sym k)) — a keyword converted to a freshly allocated symbol
;; and used as a map key. That one line was ~40% of a format call on jolt.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh keyed-lookup 3000
(ns keyed-lookup)

;; 92 keys, honeysql's clause-order count, so the miss-heavy walk below has a
;; realistic ratio of misses to hits.
(def clause-keys
  (mapv (fn [i] (keyword (str "clause-" i))) (range 92)))

;; the "statement map": a handful of the keys are present, the rest miss
(def statement
  {:clause-3 [:*] :clause-17 [:table] :clause-41 [:= :id 7]})

(defn kw->sym
  "honeysql's kw->sym, the branch jolt takes: a keyword to a symbol, retaining the
  namespace. Allocates a symbol per call by construction."
  [k]
  (if-let [n (namespace k)]
    (symbol n (name k))
    (symbol (name k))))

;; --- the walk: keyword hit, then symbol fallback on a miss -------------------
;; (k m) puts a keyword-valued LOCAL in head position; (get m sym) uses a
;; freshly built symbol as the key. Both are the shapes that were slow.
(defn clause-walk [m ks]
  (reduce (fn [acc k]
            (if-some [v (if-some [v (k m)] v (get m (kw->sym k)))]
              (inc acc)
              acc))
          0 ks))

;; --- key operations in isolation --------------------------------------------
(defn hash-keywords [ks]
  (reduce (fn [acc k] (unchecked-add acc (hash k))) 0 ks))

(defn hash-fresh-symbols [ks]
  (reduce (fn [acc k] (unchecked-add acc (hash (kw->sym k)))) 0 ks))

(defn compare-symbols [ks]
  (reduce (fn [acc k]
            (let [a (kw->sym k) b (kw->sym k)]
              (if (= a b) (inc acc) acc)))
          0 ks))

;; a MAP in head position, and a keyword-valued local — not the literal (:k m)
(defn invoke-collections [m ks]
  (reduce (fn [acc k] (if (m k) (inc acc) (if (k m) (inc acc) acc))) 0 ks))

(defn run [iters]
  (let [ks clause-keys m statement]
    (loop [i 0 acc 0]
      (if (< i iters)
        (recur (inc i)
               (unchecked-add
                acc
                (unchecked-add
                 (unchecked-add (clause-walk m ks) (hash-keywords ks))
                 (unchecked-add (unchecked-add (hash-fresh-symbols ks)
                                               (compare-symbols ks))
                                (invoke-collections m ks)))))
        acc))))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 3000)]
    (dotimes [_ 2] (run (quot iters 4)))                 ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run iters)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))))
