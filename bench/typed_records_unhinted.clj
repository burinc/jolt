;; typed-records-unhinted — the twin of `typed-records` with every type hint
;; removed. Same records, same work, same sizes; no `^double`/`^long`/`^String`
;; on the fields, no `^Row` on the reader, no primitive return tags.
;;
;; Why the suite carries both. A type-hint codegen round can only make the HINTED
;; path faster, and a scorecard that measures only that path cannot tell the
;; difference between "hints now specialize" and "hints now specialize and the
;; generic path got slower paying for it". Most code in the wild is this file, not
;; its twin: hints are the exception. Kept as a separate suite entry rather than a
;; phase inside `typed-records` because ci/bench-gate.sh compares a ratio PER
;; BENCHMARK, so the two paths need two rows for the gate to watch them
;; independently.
;;
;; The pair is only meaningful if the work is otherwise identical, so this file is
;; a transcription of typed_records.clj and should be edited with it. What differs
;; is exactly the tags.
;;
;; Portable Clojure (jolt + JVM Clojure). On the JVM the fields here are Object
;; fields and the arithmetic is boxed, which is the reference this is measured
;; against.
;;   bench/run.sh typed-records-unhinted 100000
(ns typed-records-unhinted)

(defrecord Vec3 [x y z])
(defrecord Row [id name score])

;; --- construction ------------------------------------------------------------
;; The `sink` write is what makes this measure a CONSTRUCTOR at all: a record that
;; never leaves the loop is removed outright by scalar-replace. Storing into an
;; array makes it escape, so the allocation is real. (Same reason as the hinted
;; twin; the note is repeated because deleting it here would quietly turn this
;; benchmark into one that times nothing.)
(defn make-vecs [n]
  (let [sink (object-array 1)]
    (loop [i 0 acc 0.0]
      (if (< i n)
        (let [v (->Vec3 i (+ i 1) 2.5)
              w (->Vec3 (:x v) (:y v) (:z v))]
          (aset sink 0 w)
          (recur (inc i) (+ acc (:z w))))
        acc))))

;; --- reads -------------------------------------------------------------------
;; No receiver hint, so no field read can be typed: every `:id`/`:name`/`:score`
;; answers "unknown" and the arithmetic and interop below take the dynamic path.
;; That is the point of this file.
(defn row-work [r]
  (let [id (:id r)
        nm (:name r)
        sc (:score r)]
    (+ (* sc 1.5)
       (* 1.0e-6
          (unchecked-add
           (unchecked-add (unchecked-multiply id 3) (.length nm))
           (unchecked-add (count nm)
                          (unchecked-add (.indexOf nm "-")
                                         (count (.toUpperCase nm)))))))))

(defn walk-rows [rows passes]
  (loop [p 0 acc 0.0]
    (if (< p passes)
      (recur (inc p)
             (+ acc (reduce (fn [a r] (+ a (row-work r))) 0.0 rows)))
      acc)))

(def rows (mapv (fn [i] (->Row i (str "row-name-" i) (* i 0.25))) (range 32)))

(defn run [n]
  (+ (make-vecs n) (walk-rows rows (quot n 32))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 100000)]
    (dotimes [_ 2] (run (quot n 2)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "typed-records-unhinted n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
