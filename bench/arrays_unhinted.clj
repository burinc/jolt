;; arrays-unhinted — the twin of `arrays` with every array and numeric hint
;; removed. Same arrays, same loops, same sizes; no `^doubles`/`^objects`/
;; `^longs` on the parameters, no `^long`/`^double` returns.
;;
;; This is the generic `nth` path: an unhinted (aget a i) nil-checks the index,
;; coerces it, and walks vector/string/seq/record before it reaches the array arm,
;; and the surrounding arithmetic stays boxed. Most code that touches an array in
;; the wild looks like this file, not like its twin.
;;
;; The pair exists so a codegen round cannot make the hinted path faster while the
;; generic path pays for it unnoticed: `arrays` went 229.7 -> 1272.6ms once with
;; every ci target and every library green, and only the suite saw it. Kept as its
;; own suite entry because ci/bench-gate.sh compares a ratio PER BENCHMARK.
;;
;; A transcription of arrays.clj — edit the two together; what differs is exactly
;; the tags.
;;
;; Portable Clojure (jolt + JVM Clojure). On the JVM these are still primitive
;; arrays, but every element read boxes and every call is reflective, which is the
;; reference this is measured against.
;; Sized 1000 rather than the hinted twin's 40000: without ^doubles the JVM's
;; aget is reflective, and at 40000 the reference side alone runs about seven
;; minutes a pass. The two rows' millisecond columns are therefore NOT directly
;; comparable — the hinted-versus-unhinted figure is measured separately at
;; matched sizes and quoted in bench/README.md.
;;   bench/run.sh arrays-unhinted 1000
(ns arrays-unhinted)

(defn fill! [a n]
  (loop [i 0]
    (when (< i n)
      (aset a i (double (+ (* i 0.5) 1.0)))
      (recur (inc i))))
  a)

(defn dot [a b n]
  (loop [i 0 acc 0.0]
    (if (< i n)
      (recur (inc i) (+ acc (* (aget a i) (aget b i))))
      acc)))

;; --- reference arrays --------------------------------------------------------
(defn ofill! [a n]
  (loop [i 0]
    (when (< i n)
      (aset a i (inc i))
      (recur (inc i))))
  a)

(defn osum [a n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (unchecked-add acc (aget a i)))
      acc)))

(defn lfill! [a n]
  (loop [i 0]
    (when (< i n)
      (aset a i (* i 3))
      (recur (inc i))))
  a)

(defn lsum [a n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (unchecked-add acc (aget a i)))
      acc)))

;; Same shape as the hinted twin: the arrays are filled once (the aset path) then
;; read every pass (the aget path), and the reference arrays are walked the same
;; number of times.
(defn run [passes]
  (let [n 1000
        a (fill! (double-array n) n)
        b (fill! (double-array n) n)
        o (ofill! (object-array n) n)
        l (lfill! (long-array n) n)]
    (loop [p 0 acc 0.0]
      (if (< p passes)
        (recur (inc p) (+ acc (dot a b n)
                          (* 1.0e-9 (unchecked-add (osum o n) (lsum l n)))))
        acc))))

(defn -main [& args]
  (let [passes (if (seq args) (Integer/parseInt (first args)) 40000)]
    (dotimes [_ 2] (run (quot passes 2)))                ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run passes)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "arrays-unhinted passes" passes "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
