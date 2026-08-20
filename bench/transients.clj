;; transients — the TRANSIENT WRITE PATH for maps and sets. Builds the same
;; collections four ways: `into` (which drives a transient under the hood), an
;; explicit `assoc!`/`conj!` loop, and the removal side (`dissoc!`/`disj!`), with
;; a transient VECTOR build as the control.
;;
;; `collections` measures the PERSISTENT write path — `assoc`/`conj` one at a
;; time, path-copying per write — and its read side. This measures the bulk-build
;; path libraries and core actually use: `into`, `zipmap`, `frequencies`,
;; `group-by`, `set` and `mapv` all run transient-backed.
;;
;; The axis is whether a transient map/set is a real editable trie. Backed by a
;; plain hashtable instead, a transient does not avoid the path-copying build —
;; it DEFERS it, and adds a hashtable on top, so `persistent!` folds every entry
;; through the ordinary insert and rebuilds the trie from scratch. That is
;; strictly more work than the persistent build it is supposed to beat, and it
;; is invisible to a value test. A write should claim each node on its path into
;; an editable copy and mutate in place; `persistent!` should freeze the claimed
;; spine and keep untouched subtrees by pointer.
;;
;; Transient VECTORS were always a tail-array append and are here as the
;; control: if the map/set rows move and the vector row does not, the change is
;; in the trie edit path and not in the surrounding reduce.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh transients 50000
(ns transients)

;; keys built OUTSIDE the timed region — this measures the write path, not
;; keyword construction (see `keyed-lookup` for that).
(def kws (mapv (fn [i] (keyword (str "k" i))) (range 50000)))

(defn- take-kws [n] (subvec kws 0 (min n (count kws))))

;; --- into: the transducing bulk build ---------------------------------------
(defn into-map [n]
  (count (into {} (map (fn [i] [i (* i 2)])) (range n))))

(defn into-set [n]
  (count (into #{} (map (fn [i] (mod i (quot (inc n) 2)))) (range n))))

;; the control: a transient vector build over the same source
(defn into-vec [n]
  (count (into [] (map (fn [i] (* i 2))) (range n))))

;; --- explicit transient loops ------------------------------------------------
(defn assoc-loop [ks]
  (count (persistent!
          (reduce (fn [t k] (assoc! t k 1)) (transient {}) ks))))

(defn conj-loop [ks]
  (count (persistent!
          (reduce (fn [t k] (conj! t k)) (transient #{}) ks))))

;; --- the removal side --------------------------------------------------------
(defn dissoc-loop [m ks]
  (count (persistent!
          (reduce (fn [t k] (dissoc! t k)) (transient m) ks))))

(defn disj-loop [s ks]
  (count (persistent!
          (reduce (fn [t k] (disj! t k)) (transient s) ks))))

;; --- core fns that are transient-backed in the reference ---------------------
(defn build-zipmap [ks] (count (zipmap ks ks)))
(defn build-freqs [n] (count (frequencies (map (fn [i] (mod i 512)) (range n)))))
(defn build-groups [n] (count (group-by (fn [i] (mod i 512)) (range n))))

(defn run [n]
  (let [ks (take-kws n)
        half (subvec ks 0 (quot (count ks) 2))
        m (zipmap ks ks)
        s (set ks)]
    (unchecked-add
     (unchecked-add
      (unchecked-add (into-map n) (into-set n))
      (unchecked-add (into-vec n) (assoc-loop ks)))
     (unchecked-add
      (unchecked-add (conj-loop ks) (dissoc-loop m half))
      (unchecked-add
       (unchecked-add (disj-loop s half) (build-zipmap ks))
       (unchecked-add (build-freqs n) (build-groups n)))))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 50000)]
    (dotimes [_ 2] (run (quot n 4)))                     ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run n)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))))
