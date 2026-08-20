;; literals — FIXED PER-CALL OVERHEAD inside a library's inner function: the
;; constant collection literals in its body, and the cheap type predicates it
;; guards with. No algorithm here at all — every function is a handful of
;; constructions and predicate calls, repeated.
;;
;; Nothing else in the suite sees this. `collections`, `seqs` and `transducers`
;; measure work that scales with the data; this measures what a call costs before
;; it touches any. Two costs, both found profiling honeysql's format loop:
;;
;;   - a LITERAL collection in a fn body. `{:a 1}`, `#{:for 'for}`, `[:a 'b]` are
;;     compile-time constants and the reference compiler emits them into the
;;     class's constant pool, built once. Rebuilding one per evaluation makes a
;;     membership test against a set literal cost an allocation plus a hash per
;;     element; `pset-conj` was 11% of samples in the honeysql profile, all of it
;;     set literals rebuilt per call. Hoisting must be PER SITE, not interned
;;     across sites — two textually identical literals are distinct objects in
;;     the reference, and `=` short-circuits on identity — and a literal holding
;;     a LOCAL is not constant and must still be built per call, which
;;     `dynamic-pair` here is the control for.
;;   - `true?`/`false?`/`boolean?`. Spelled `(= true x)`, a mixed-type `=` misses
;;     every fast clause and walks the equality arm registry, so a library that
;;     registers an arm makes an unrelated `boolean?` slower. The reference
;;     bodies are identity checks, and `identical?` is an inline op.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh literals 100000
(ns literals)

;; --- constant collection literals in a fn body ------------------------------

;; a 12-key options map, the shape a formatter carries defaults in
(defn default-opts []
  {:dialect :ansi :quoted false :inline false :checking :none
   :numbered false :quoted-snake false :pretty false :values nil
   :registry nil :params nil :cache nil :aliases nil})

;; a small set literal used as a membership test — the honeysql shape, and the
;; one that showed up in the profile
(defn special-clause? [k]
  (contains? #{:for :lateral :values :columns} k))

;; the same test, but the set holds QUOTED SYMBOLS as well as keywords, so the
;; literal is only constant if quoted forms hoist too
(defn special-or-sym? [k]
  (contains? #{:for 'for :lateral 'lateral} k))

;; a vector and a map literal holding quoted symbols
(defn sym-pair [] ['and 'or])
(defn sym-map [] {:op 'select :from 'table})

;; the control: an element is a LOCAL, so this genuinely constructs per call
(defn dynamic-pair [x] [:clause x])

;; two textually identical literals at DIFFERENT sites stay distinct objects
(defn site-a [] #{:x :y})
(defn site-b [] #{:x :y})

;; --- cheap type predicates ---------------------------------------------------

(def probes [true false nil :marker "s" 42 'sym [1] false true])

(defn classify [xs]
  (reduce (fn [acc x]
            (unchecked-add
             acc
             (unchecked-add
              (unchecked-add (if (true? x) 1 0) (if (false? x) 1 0))
              (unchecked-add (if (boolean? x) 1 0)
                             (if (identical? x :marker) 1 0)))))
          0 xs))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add
                (unchecked-add (count (default-opts))
                               (if (special-clause? :values) 1 0))
                (unchecked-add (if (special-or-sym? 'for) 1 0)
                               (unchecked-add (count (sym-pair)) (count (sym-map)))))
               (unchecked-add
                (unchecked-add (count (dynamic-pair i))
                               (if (identical? (site-a) (site-b)) 0 1))
                (classify probes)))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 100000)]
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
