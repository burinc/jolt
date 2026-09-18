;; coll-dispatch — KIND DISPATCH on small collections. Every `get`, `assoc`,
;; `conj`, `first`, `next`, `count`, `nth` and `=` starts with a chain of type
;; tests (is it a map? a vector? a list cell? a lazy node? …) before it does any
;; work, and on a 4-key map or an 8-element list the work after the chain is a
;; few nanoseconds, so the chain is a large share of the op. This row keeps the
;; per-op work that small on purpose: it isolates the dispatch that stands in
;; front of every collection operation, which `collections` (large tries, where
;; the trie walk dominates) and `keyed-lookup` (key hashing dominates) do not.
;;
;; The shape is an interpreter's or a formatter's: a small fixed-key map per
;; node read and rewritten a field at a time, short argument lists walked cell
;; by cell with first/next, small vectors compared and indexed. Nothing here
;; allocates beyond the op's own result.
;;
;; What it watches in jolt: the record predicates and accessors behind that
;; chain are open-coded (scheme-adapter-runtime.ss define-record-type), and the
;; collection layouts load ahead of the dispatchers so the open-coding applies
;; to them (values.ss). `make recordinline` gates the mechanism; this row says
;; what it is worth end to end.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh coll-dispatch 200000
(ns coll-dispatch)

(def small-map {:tag :node :line 12 :col 4 :depth 1})
(def short-list (list 1 2 3 4 5 6 7 8))
(def short-vec [1 2 3 4 5 6 7 8])
(def vec-a [1 2 3])
(def vec-b [1 2 3])
(def keys-hit [:tag :line :col :depth])
(def keys-miss [:name :end-line :end-col :parent])

;; --- map: get hit / miss, keyword invoke, assoc of an existing key --------------
(defn map-ops [m i]
  (let [a (get m :line)
        b (get m :missing 0)
        c (:col m)
        d (if (contains? m :depth) 1 0)
        m2 (assoc m :line i)
        m3 (assoc m2 :col (unchecked-add i 1))]
    (unchecked-add (unchecked-add a b) (unchecked-add c (unchecked-add d (get m3 :col))))))

;; --- list: a first/next walk, count, conj, peek/pop ---------------------------
(defn list-walk [l]
  (loop [s (seq l) acc 0]
    (if s
      (recur (next s) (unchecked-add acc (first s)))
      acc)))

(defn list-ops [l i]
  (let [l2 (conj l i)]
    (unchecked-add (unchecked-add (list-walk l) (count l2))
                   (unchecked-add (peek l2) (count (pop l2))))))

;; --- vector: nth, count, conj, =, contains? ---------------------------------
(defn vec-ops [v i]
  (let [v2 (conj v i)
        x (nth v (bit-and i 7))
        y (nth v2 8)
        eq (if (= vec-a vec-b) 1 0)
        ne (if (= vec-a v) 1 0)
        c (if (contains? v 3) 1 0)]
    (unchecked-add (unchecked-add x y) (unchecked-add (unchecked-add eq ne) (unchecked-add c (count v2))))))

;; --- a miss-heavy key scan, the honeysql/formatter "which keys are here" walk ---
(defn key-scan [m]
  (unchecked-add
   (reduce (fn [acc k] (if (get m k) (unchecked-add acc 1) acc)) 0 keys-hit)
   (reduce (fn [acc k] (if (get m k) (unchecked-add acc 1) acc)) 0 keys-miss)))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add acc
                            (unchecked-add (unchecked-add (map-ops small-map i) (list-ops short-list i))
                                           (unchecked-add (vec-ops short-vec i) (key-scan small-map)))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 200000)]
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
