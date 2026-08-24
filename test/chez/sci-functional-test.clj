;; Functional SCI gate: the source-loading gate proves broad compatibility,
;; while this file proves that the supported dependency path yields usable,
;; persistent SCI contexts.
(ns sci-functional-test
  (:require [sci.core :as sci]))

(defn- check= [label expected actual]
  (when-not (= expected actual)
    (throw (ex-info (str label ": expected " (pr-str expected)
                         ", got " (pr-str actual))
                    {:label label :expected expected :actual actual}))))

(let [ctx (sci/init {})]
  (check= "basic evaluation" 3
          (sci/eval-string* ctx "(+ 1 2)"))

  (sci/eval-string* ctx "(def x 41)")
  (check= "definitions persist" 42
          (sci/eval-string* ctx "(+ x 1)"))

  (sci/eval-string* ctx "(defn twice [n] (* n 2))")
  (check= "defined functions persist" 42
          (sci/eval-string* ctx "(twice 21)"))
  (check= "closures evaluate" 42
          (sci/eval-string* ctx "((let [n 40] (fn [x] (+ n x))) 2)"))
  (check= "collection operations evaluate" {:a 2 :b 3}
          (sci/eval-string* ctx "(update {:a 1 :b 3} :a inc)"))
  (check= "lazy sequences realize with vec" [1 2 3 4]
          (sci/eval-string* ctx "(vec (map inc (range 4)))"))

  (sci/eval-string* ctx "(def y (twice x))")
  (check= "successive evaluations share context state" 82
          (sci/eval-string* ctx "y")))

(let [a (sci/init {})
      b (sci/init {})]
  (sci/eval-string* a "(def isolated 7)")
  (check= "first independent context retains its definition" 7
          (sci/eval-string* a "isolated"))
  (check= "independent contexts do not share definitions" :missing
          (try
            (sci/eval-string* b "isolated")
            :shared
            (catch Throwable _ :missing))))

(println "SCI-FUNCTIONAL-TEST OK")
