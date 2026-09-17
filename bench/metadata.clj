;; metadata — METADATA on collections: attaching it, reading it, and carrying it
;; through the ops that preserve it. `with-meta`/`meta`/`vary-meta` on vectors,
;; maps and lists, `assoc`/`conj`/`into` on a collection that has meta (the
;; result carries it, so each op reads the source's meta and stamps the result),
;; and the analyzer shape: a nested form tree whose every node carries
;; `{:line :col}`, rebuilt bottom-up with the meta preserved — what a code
;; walker, rewrite-clj, a spec conformer or a macro that keeps `&form`'s
;; position does per node.
;;
;; None of the other rows attaches metadata, so none of them notices what it
;; costs. In the reference every collection carries its `_meta` in a field;
;; jolt does the same (a slot on the collection record, natives-meta.ss), so
;; `meta` is a field read and a carry is a slot copy. Before that it was an
;; identity-keyed side table that every op probed and every `with-meta` wrote
;; under one process-wide mutex — 214 ns for a `with-meta`, and every op on a
;; meta-bearing collection paid the probe.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh metadata 100000
(ns metadata)

(def pos {:line 7 :col 3})
(def tagged-vec (with-meta [1 2 3 4] pos))
(def tagged-map (with-meta {:a 1 :b 2 :c 3} pos))
(def tagged-list (with-meta (list 1 2 3 4) pos))

;; --- attach / read / vary ---------------------------------------------------------
(defn attach-read [v i]
  (let [v2 (with-meta v {:line i :col 1})
        m (meta v2)
        v3 (vary-meta v2 assoc :end-line (unchecked-add i 1))]
    (unchecked-add (:line m) (:end-line (meta v3)))))

;; --- carry: the result of an op on a meta-bearing collection keeps the meta -------
(defn carry [i]
  (let [v (conj tagged-vec i)
        m (assoc tagged-map :d i)
        l (conj tagged-list i)
        w (into tagged-vec [i i])
        d (dissoc tagged-map :a)]
    (unchecked-add
     (unchecked-add (:line (meta v)) (:line (meta m)))
     (unchecked-add (:line (meta l)) (unchecked-add (:line (meta w)) (:line (meta d)))))))

;; --- the form tree: every node positioned, rebuilt with its position kept ---------
;; (f a [b c] (g d {:k e})) nested three deep, ~40 nodes
(defn tag [form line col]
  (if (instance? clojure.lang.IObj form)
    (with-meta form {:line line :col col})
    form))

(defn make-tree [depth line]
  (if (zero? depth)
    (tag (list 'f 'a (tag ['b 'c] line 8) (tag {:k 'e} line 12)) line 1)
    (tag (list 'g (make-tree (dec depth) (inc line)) (tag ['x (make-tree (dec depth) (+ line 2))] line 5))
         line 1)))

(def tree (make-tree 3 1))

;; rebuild every node bottom-up, keeping each node's meta: the walker's contract
(defn rebuild [form]
  (cond
    (seq? form) (with-meta (apply list (map rebuild form)) (meta form))
    (vector? form) (with-meta (mapv rebuild form) (meta form))
    (map? form) (with-meta (into {} (map (fn [[k v]] [k (rebuild v)])) form) (meta form))
    :else form))

;; how many nodes still carry their position after the rebuild (must be all)
(defn count-positioned [form]
  (cond
    (seq? form) (reduce + (if (:line (meta form)) 1 0) (map count-positioned form))
    (vector? form) (reduce + (if (:line (meta form)) 1 0) (map count-positioned form))
    (map? form) (reduce + (if (:line (meta form)) 1 0) (map count-positioned (vals form)))
    :else 0))

(def positioned (count-positioned tree))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add acc
                            (unchecked-add (attach-read tagged-vec i)
                                           (unchecked-add (carry i)
                                                          (if (zero? (bit-and i 63))
                                                            (count-positioned (rebuild tree))
                                                            0)))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 100000)]
    (when (not= positioned (count-positioned (rebuild tree)))
      (println "rebuild lost metadata:" positioned "->" (count-positioned (rebuild tree))))
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
