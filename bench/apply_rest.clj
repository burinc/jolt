;; apply-rest — `apply` over a LONG rest: the core variadics `+ max min < <=`,
;; a leading argument ahead of the rest, and a user variadic whose `& xs`
;; arrives as a seq, each over a million-element range.
;;
;; What it watches: apply hands a registered variadic its rest LAZILY and the
;; native folds one element at a time, so the cost is a walk and nothing is
;; materialized; `(apply max (range))` runs in constant space where a
;; materializing apply allocates the whole list first (and never returns on an
;; unbounded seq — `make applyscaling` gates that shape). A value-position
;; `max` is its var's root, so the root reached through `apply` is the same
;; streaming procedure the compiled call is.
;;
;; Every sum stays inside fixnum range, so the time is the walk and not bignum
;; promotion.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh apply-rest 1000000
(ns apply-rest)

;; a user variadic: its rest arrives as the seq apply hands it
(defn- sum-all [& xs] (reduce + 0 xs))

(defn run [n]
  (let [r (range n)]
    (+ (apply + r)
       (apply max r)
       (apply min 5 r)                        ; a leading argument ahead of the rest
       (if (apply < r) 1 0)                   ; a chain that walks every element
       (if (apply <= 0 r) 1 0)
       (apply sum-all r))))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 1000000)]
    (dotimes [_ 2] (run (quot n 4)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "apply-rest n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
