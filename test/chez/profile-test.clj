;; jolt.profile gate — the execution-count profiler over Chez's compile-profile
;; counters. The fixture's line numbers are part of the expectations: fib(15)
;; makes 1973 calls, 986 of them recursive; sum-to 100 tests its loop 101 times.
;; Run: bin/jolt run test/chez/profile-test.clj (smoke.sh greps "PROFILE-TEST OK").
(ns profile-test
  (:require [clojure.string :as str]
            [jolt.profile :as prof]))

(def failures (atom []))
(defn check [label got want]
  (when-not (= got want)
    (swap! failures conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(def fixture "test/chez/fixtures/profile_fixture.clj")
(defn fixture? [m] (str/ends-with? (str (:file m)) "profile_fixture.clj"))
(defn hits-at [rows line]
  (some #(when (and (fixture? %) (= line (:line %))) (:hits %)) rows))
(defn fn-row [rows sym] (first (filter #(= sym (:fn %)) rows)))

(check "off at start" (prof/instrumenting?) false)
(check "instrument! on" (prof/instrument!) true)
(check "on after instrument!" (prof/instrumenting?) true)
(load-file fixture)
(prof/instrument! false)
(check "off after instrument! false" (prof/instrumenting?) false)
;; loading ran each defn form once, but that is top-level code: no fn has run yet
(check "a loaded fn that never ran has no fn row"
       (fn-row (prof/fn-counts) 'profile-fixture/sum-to) nil)
(prof/clear!)

((resolve 'profile-fixture/fib) 15)
((resolve 'profile-fixture/sum-to) 100)

(def lines (prof/line-counts))
(check "if line runs once per call" (hits-at lines 4) 1973)
(check "recursive line" (hits-at lines 6) 986)
(check "loop test" (hits-at lines 10) 101)
(check "recur line" (hits-at lines 11) 100)
(check "lines sorted by hits" (= (map :hits lines) (sort > (map :hits lines))) true)
(check "line rows name their fn" (:fn (first (filter #(and (fixture? %) (= 6 (:line %))) lines)))
       'profile-fixture/fib)
;; this file was compiled before instrument!, so none of it carries a counter
(check "uninstrumented code has no rows"
       (some #(str/ends-with? (str (:file %)) "profile-test.clj") lines) nil)

(def fns (prof/fn-counts))
(check "fib hits" (:hits (fn-row fns 'profile-fixture/fib)) 1973)
(check "sum-to hits" (:hits (fn-row fns 'profile-fixture/sum-to)) 101)
(check "fib line" (:line (fn-row fns 'profile-fixture/fib)) 3)
(check "fib evals exceed hits" (> (:evals (fn-row fns 'profile-fixture/fib)) 1973) true)

(def report (with-out-str (prof/report)))
(check "report names fib" (str/includes? report "profile-fixture/fib") true)
(check "report shows the count" (str/includes? report "1973") true)

(def annotated (with-out-str (prof/annotate fixture)))
(check "annotate prints the hot line with its count"
       (boolean (some #(and (str/includes? % "1973") (str/includes? % "(if (< n 2)"))
                      (str/split-lines annotated)))
       true)

(prof/clear!)
(check "clear! drops every count" (hits-at (prof/line-counts) 4) nil)
((resolve 'profile-fixture/fib) 5)
(check "counting resumes after clear!" (hits-at (prof/line-counts) 4) 15)

;; code compiled with instrumentation off counts nothing
(load-file fixture)
(prof/clear!)
((resolve 'profile-fixture/fib) 15)
(check "recompiled uninstrumented" (hits-at (prof/line-counts) 4) nil)

(let [m (prof/measure (reduce + (range 100000)))]
  (check "measure result" (:result m) 4999950000)
  (check "measure fields"
         (every? #(and (number? (m %)) (>= (m %) 0))
                 [:real-ms :cpu-ms :allocated-bytes :gc-count :gc-ms])
         true))
(check "measure counts allocation"
       (> (:allocated-bytes (prof/measure (vec (range 100000)))) 100000) true)

(if (empty? @failures)
  (println "PROFILE-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "PROFILE-TEST FAILED:" (count @failures))))
