;; string-build — the STRING-ASSEMBLY workload: a StringBuilder appended to in a
;; loop, plus the transducer-over-`join` shape libraries actually use to render
;; text. Per-iteration work is one append and one small render, so interop dispatch
;; and string allocation dominate.
;;
;; Neither `seqs` nor `transducers` reaches this: their reducing functions do
;; arithmetic, so they measure the seq and transducer machinery with a free rf. Here
;; the rf calls a HOST METHOD, which on jolt is the most expensive interop shape
;; there is — a jhost method call finds its method table by hashing the tag string,
;; finds the handler by hashing the method name, and passes rest args as a vector
;; that is converted back to a list for apply. A proven-StringBuilder target skips
;; all of it, and this is what measures that.
;;
;; The shape is honeysql's again: honey.sql.util/join builds with a StringBuilder
;; under a `transduce`, and honey.sql/format-entity calls it about three times per
;; format call. It was 45% of format-entity on jolt.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh string-build 60000
(ns string-build)

(def parts ["some" "qualified" "entity" "name"])
(def words (mapv (fn [i] (str "w" i)) (range 24)))

;; --- the honeysql join: a StringBuilder under a transduce, separator-aware -----
;; The builder is a LET-BOUND constructor call with no type hint in the source,
;; which is the shape every string-building loop in Clojure has.
(defn join-xf [separator xform coll]
  (let [sb (StringBuilder.)
        sep (str separator)]
    (transduce xform
               (fn ([] false)
                   ([_] (.toString sb))
                   ([add-sep? x]
                    (when add-sep? (.append sb sep))
                    (.append sb (str x))
                    true))
               false coll)))

;; --- a plain append loop, no transducer in the way ---------------------------
(defn build-loop [xs]
  (let [sb (StringBuilder.)]
    (loop [ys (seq xs)]
      (if ys
        (do (.append sb (first ys)) (.append sb "/") (recur (next ys)))
        (.toString sb)))))

;; --- the fluent chain: append's return value threaded, not the builder --------
(defn build-fluent [a b c]
  (let [sb (StringBuilder.)]
    (.toString (.append (.append (.append sb a) b) c))))

;; --- reading back: length and charAt on the same builder ----------------------
(defn build-and-measure [xs]
  (let [sb (StringBuilder.)]
    (reduce (fn [_ x] (.append sb x)) nil xs)
    (+ (.length sb) (int (.charAt sb 0)))))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add (count (join-xf "." (map identity) parts))
                              (count (build-loop parts)))
               (unchecked-add (count (build-fluent "a" "b" "c"))
                              (build-and-measure words)))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 60000)]
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
