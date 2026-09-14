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


;; Type-hinted interop. SCI resolves a ^Hint to a Class at ANALYSIS time and
;; asks that Class whether it is a functional interface to adapt
;; (sci.impl.analyzer/resolve-tag-class -> reflector/maybe-fi-method ->
;; .isAnnotationPresent). jolt answered that question by looking for a STATIC of
;; the hinted class, so a hinted instance call could not be analyzed at all — it
;; died with RFC 0014's "No dependency provides java.lang.StringBuilder" for a
;; class jolt fully supplies, and an extension carrying one ^StringBuilder loop
;; would not load (jolt#983). The unhinted call worked, which is what made it
;; look like a missing class rather than a missing Class method.
(defn- hinted-ctx []
  (let [ctx (sci/init {:classes {:allow :all}})]
    (sci/add-class! ctx 'java.lang.StringBuilder java.lang.StringBuilder)
    (sci/add-class! ctx 'StringBuilder java.lang.StringBuilder)
    ctx))

(check= "hinted instance method" "x"
        (sci/eval-string* (hinted-ctx)
          "(defn f [^StringBuilder sb] (.append sb \"x\")) (str (f (StringBuilder.)))"))
(check= "hinted zero-arg instance method" 3
        (sci/eval-string* (hinted-ctx)
          "(defn f [^StringBuilder sb] (.length sb)) (f (StringBuilder. \"abc\"))"))
(check= "fully-qualified hint" "y"
        (sci/eval-string* (hinted-ctx)
          "(defn f [^java.lang.StringBuilder sb] (.append sb \"y\")) (str (f (StringBuilder.)))"))
(check= "hinted loop binding" "012"
        (sci/eval-string* (hinted-ctx)
          "(loop [i 0 ^StringBuilder sb (StringBuilder.)] (if (< i 3) (recur (inc i) (.append sb i)) (str sb)))"))
(check= "unhinted call still dispatches dynamically" "x"
        (sci/eval-string* (hinted-ctx)
          "(defn f [sb] (.append sb \"x\")) (str (f (StringBuilder.)))"))


;; A value with its own value-semantics seam (java.time) as an interop ARGUMENT.
;; sci.impl.reflector/box-arg casts every argument to its reflected parameter
;; type, and jolt — carrying no signatures — reports every parameter as
;; java.lang.Object, so an argument only survives the call if
;; (.cast java.lang.Object v) is the identity. It was not for java.time values:
;; their instance? arm answered a definitive false for the root type and the
;; cast threw ClassCastException, so any interpreted call taking one died (#985).
;; Receivers are not boxed, which is why (.getYear d) worked all along and only
;; arguments failed.
(let [ctx (sci/init {:classes {'java.time.LocalDate java.time.LocalDate
                               'java.time.Duration java.time.Duration
                               'java.lang.Object java.lang.Object}
                     :imports {'LocalDate 'java.time.LocalDate
                               'Duration 'java.time.Duration}})]
  (check= "java.time value as an instance-method argument" true
          (sci/eval-string* ctx "(.isAfter (LocalDate/of 2021 1 1) (LocalDate/of 2020 1 1))"))
  (check= "java.time values as static-method arguments" "PT24H"
          (sci/eval-string* ctx "(str (Duration/between (LocalDate/of 2020 1 1) (LocalDate/of 2020 1 2)))"))
  (check= "a java.time value is an Object" true
          (sci/eval-string* ctx "(instance? java.lang.Object (LocalDate/of 2020 3 5))")))

(println "SCI-FUNCTIONAL-TEST OK")
