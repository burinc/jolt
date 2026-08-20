;; hash-eq — HASHING AND EQUALITY OF COMPOSITE VALUES: vectors, maps, sets,
;; records, seqs and functions, hashed repeatedly, used as map/set keys, and
;; compared with `=`. Per-iteration work is one hash or one compare, so the hash
;; engine and the equality fast paths dominate.
;;
;; This is the regime `keyed-lookup` does not reach. That benchmark measures
;; SCALAR keys — keywords, symbols, strings — which carry (or memoise) their own
;; hash, so its cost is the lookup shape. Here every key is a COMPOSITE value
;; whose hash is derived from its contents, which is a different engine:
;;
;;   - a collection's hasheq is a fold over its elements, so without a cache
;;     every `(hash v)` re-walks the whole thing, and every collection-keyed map
;;     op pays that walk. Vectors, maps and sets each carry a lazily filled
;;     hasheq field; a seq caches on its head object; a record caches in an
;;     instance slot. This measures the repeat-hash (cache-hit) path.
;;   - `=` and `hash` on a collection used to fall through to a linear walk of
;;     the equality/hash arm registries before reaching their base cases, so the
;;     cost grew as libraries loaded. Vectors, maps, sets and records are
;;     answered ahead of that walk now.
;;   - two collections with DIFFERENT cached hashes are unequal without a
;;     structural walk. The equal case still walks, so both are timed.
;;   - a FUNCTION as a hash key. Chez's `equal-hash` gives every procedure the
;;     same constant, so an fn-keyed map degenerated to one bucket and lookups
;;     went quadratic in the number of keys; procedures get an identity hasheq
;;     from a weak side table now.
;;
;; The shapes come from the field: instaparse's GLL msg-cache is keyed
;; `[listener index]` — a vector holding a closure — and honeysql's format path
;; compares and hashes small maps and vectors per call.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh hash-eq 2000
(ns hash-eq)

(defrecord Point [x y z w])

;; --- data, all built OUTSIDE the timed region -------------------------------

(def big-vec (vec (range 1000)))
(def big-vec-eq (vec (range 1000)))                        ; equal, different object
(def big-vec-ne (assoc (vec (range 1000)) 999 -1))         ; differs in the last slot

(def big-map (zipmap (mapv (fn [i] (keyword (str "k" i))) (range 100)) (range 100)))
(def big-map-eq (zipmap (mapv (fn [i] (keyword (str "k" i))) (range 100)) (range 100)))
(def big-map-ne (assoc big-map :k99 -1))

(def big-set (set (range 200)))
(def big-list (apply list (range 500)))
;; a seq caches its hasheq on the HEAD object, so the head is held here — a
;; freshly allocated seq per iteration would measure the fold, not the cache.
(def big-seq (seq (vec (range 500))))

;; every collection whose hash the equality section relies on is in here, so the
;; caches are warm by the time the compares run.
(def hashables [big-vec big-vec-eq big-vec-ne big-map big-map-eq big-map-ne
                big-set big-list big-seq])

;; instaparse's msg-cache shape: a small vector key holding a scalar and a
;; keyword, hashed and compared on every cache probe.
(def composite-keys
  (vec (for [i (range 256)] [i (keyword (str "p" (mod i 8)))])))
(def composite-map (zipmap composite-keys (range 256)))
(def composite-set (set composite-keys))

(def records (mapv (fn [i] (->Point i (inc i) (+ i 2) (+ i 3))) (range 128)))
(def record-map (zipmap records (range 128)))

;; distinct closures, used as map keys
(def fns (mapv (fn [i] (fn [x] (+ x i))) (range 64)))
(def fn-map (zipmap fns (range 64)))

;; --- 1. repeat hash: the hasheq cache ---------------------------------------
(defn hash-colls [colls]
  (reduce (fn [acc c] (unchecked-add acc (hash c))) 0 colls))

;; --- 2. composite keys: vector keys in a map and a set ----------------------
(defn lookup-composite [m ks]
  (reduce (fn [acc k] (unchecked-add acc (long (get m k 0)))) 0 ks))

(defn probe-composite [s ks]
  (reduce (fn [acc k] (if (contains? s k) (inc acc) acc)) 0 ks))

;; --- 3. record keys: hash, lookup, and building a record-keyed map ----------
(defn hash-records [rs]
  (reduce (fn [acc r] (unchecked-add acc (hash r))) 0 rs))

(defn lookup-records [m rs]
  (reduce (fn [acc r] (unchecked-add acc (long (get m r 0)))) 0 rs))

;; --- 4. fn keys -------------------------------------------------------------
(defn lookup-fns [m ks]
  (reduce (fn [acc k] (unchecked-add acc (long (get m k 0)))) 0 ks))

;; --- 5. equality: the walking case and the hash-reject case -----------------
;; `a` vs `b` are equal and distinct objects, so this is the structural compare;
;; `a` vs `c` differ, and both carry a cached hasheq, so it answers on the hash.
(defn compare-pairs [a b c]
  (unchecked-add (if (= a b) 1 0) (if (= a c) 0 1)))

;; --- 6. hash-heavy collection ops over composite keys -----------------------
(defn set-of [ks] (count (set ks)))
(defn distinct-of [ks] (count (distinct ks)))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add
                (unchecked-add (hash-colls hashables)
                               (lookup-composite composite-map composite-keys))
                (unchecked-add (probe-composite composite-set composite-keys)
                               (hash-records records)))
               (unchecked-add
                (unchecked-add (lookup-records record-map records)
                               (lookup-fns fn-map fns))
                (unchecked-add
                 (unchecked-add (compare-pairs big-vec big-vec-eq big-vec-ne)
                                (compare-pairs big-map big-map-eq big-map-ne))
                 (unchecked-add (set-of composite-keys)
                                (distinct-of composite-keys)))))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 2000)]
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
