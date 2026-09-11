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

;; Java interop inside interpreted code. SCI resolves every method call through
;; clojure.lang.Reflector (getMethods → its own matching → Method.invoke), so a
;; library jolt runs through SCI rather than compiling — an extension, a
;; dependency — cannot touch a host class without these. Static calls, instance
;; calls and constructors are three distinct lookups; each is exercised where
;; the REFLECTOR is what resolves it, and so is a class whose methods jolt
;; models as a cond over the receiver (String) rather than as enumerable data.
(let [ctx (sci/init {:classes {'java.lang.System java.lang.System
                               'java.lang.Integer java.lang.Integer
                               'java.lang.Math java.lang.Math
                               'java.lang.Character java.lang.Character
                               'java.io.File java.io.File
                               'java.net.URI java.net.URI
                               'java.util.ArrayList java.util.ArrayList}
                     :imports {'System 'java.lang.System
                               'Integer 'java.lang.Integer
                               'Character 'java.lang.Character
                               'Math 'java.lang.Math
                               'File 'java.io.File
                               'URI 'java.net.URI
                               'ArrayList 'java.util.ArrayList}})]
  (check= "static method, no args" true
          (pos? (sci/eval-string* ctx "(System/currentTimeMillis)")))
  (check= "static method, one arg" (System/getenv "HOME")
          (sci/eval-string* ctx "(System/getenv \"HOME\")"))
  (check= "static method, two args" (System/getProperty "os.name" "?")
          (sci/eval-string* ctx "(System/getProperty \"os.name\" \"?\")"))
  (check= "static returning a primitive" 42
          (sci/eval-string* ctx "(Integer/parseInt \"42\")"))
  (check= "static returning a boolean" false
          (sci/eval-string* ctx "(Character/isWhitespace \\a)"))
  (check= "static method on a class modeled as a cond" 2
          (sci/eval-string* ctx "(Math/round 1.6)"))
  (check= "constructor" "b.txt"
          (sci/eval-string* ctx "(.getName (File. \"/a/b.txt\"))"))
  (check= "instance method on a host object" "https"
          (sci/eval-string* ctx "(.getScheme (URI. \"https://x.dev\"))"))
  (check= "instance method on a native string" 2
          (sci/eval-string* ctx "(.indexOf \"abcdef\" \"cd\")"))
  (check= "instance method with a marshalled argument" "cdef"
          (sci/eval-string* ctx "(.substring \"abcdef\" 2)"))
  (check= "instance method after a mutating call" 1
          (sci/eval-string* ctx "(let [l (ArrayList.)] (.add l \"x\") (.size l))"))
  (check= "an unknown method surfaces with the method named" :threw
          (try
            (sci/eval-string* ctx "(.noSuchMethod (File. \"/a\"))")
            :no-throw
            (catch Throwable e
              (if (re-find #"noSuchMethod" (ex-message e)) :threw :wrong-message)))))

(println "SCI-FUNCTIONAL-TEST OK")
