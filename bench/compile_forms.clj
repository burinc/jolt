;; compile-forms — COMPILE THROUGHPUT: `load-string` of n ordinary top-level
;; defns (the shape of a namespace) and of ONE `deftest` holding n `is` forms
;; (the shape where the cost concentrates — each `is` splices its form five
;; times, and a def's constant pool is one lexical scope). Every other row in
;; the suite measures a program running; this one measures jolt compiling it,
;; which is what dominates a test suite's wall clock and every `jolt run`.
;;
;; What it watches: the quoted-constant pool keyed by form IDENTITY (one
;; constant per source form however many times a macro mentions it, as
;; Compiler.registerConstant does), constant collection literals hoisted and
;; ordered as constants, and the per-form front-end cost. `make compilescaling`
;; gates the complexity class inside one process; this is the absolute time
;; against the reference, which builds bytecode here and generates no native
;; code at all.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh compile-forms 200
(ns compile-forms
  (:require [clojure.string :as str]
            [clojure.test]))

;; n ordinary defns, each with a let, a branch and some arithmetic
(defn- small-forms [n]
  (str/join "\n"
            (map (fn [i]
                   (str "(defn cf-" i " [x] (let [y (+ x " i ")] "
                        "(if (pos? y) (* y 2) (- y))))"))
                 (range n))))

;; n `is` inside one deftest
(defn- one-deftest [n]
  (str "(clojure.test/deftest cf-big "
       (str/join " " (map (fn [i] (str "(clojure.test/is (= " i " (+ " i " 0)))")) (range n)))
       ")"))

(defn run [[a b]]
  (load-string a)
  (load-string b)
  (count a))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 200)
        state [(small-forms n) (one-deftest n)]]
    (dotimes [_ 2] (run state))                          ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run state)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "compile-forms n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
