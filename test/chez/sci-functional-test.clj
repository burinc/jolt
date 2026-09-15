;; Functional SCI gate: the source-loading gate proves broad compatibility,
;; while this file proves that the supported dependency path yields usable,
;; persistent SCI contexts.
(ns sci-functional-test
  (:require [sci.core :as sci]
            [sci.impl.types]))

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




;; A host protocol shared into an SCI context, implemented from inside it.
;;
;; SCI has one model of a protocol: a map {:methods #{multimethod ..} :ns
;; <sci namespace>} whose methods are multimethods dispatching on
;; sci.impl.types/type-impl, which is what its defrecord/deftype/extend-type
;; register into (a defmethod per method). A host protocol var copied in as-is
;; (sci/copy-var*) is not that shape on ANY host — jolt's map has no :ns and its
;; methods are plain fns; the JVM's has no :ns either and a :var SCI cannot
;; alter-var-root — so a record implementing it dies in analysis (jolt#1000).
;; The embedder shares a host protocol the way babashka shares
;; clojure.core.protocols: one multimethod per method whose :default answers
;; through the host protocol, a SCI-side protocol map naming them, and — for the
;; other direction, a host caller handed a value SCI built — the host protocol
;; extended to SCI's record and type classes, routing back through the
;; multimethods. This is that recipe, run end to end on jolt.
(defprotocol Shape
  (area [this])
  (scaled [this k]))
(defrecord HostSquare [s]
  Shape
  (area [_] (* s s))
  (scaled [_ k] (->HostSquare (* s k))))

;; SCI-side methods: dispatch on SCI's notion of a value's type; a value SCI did
;; not build (a host record, a string) falls to the host protocol.
(defmulti sci-area sci.impl.types/type-impl)
(defmulti sci-scaled sci.impl.types/type-impl)
(defmethod sci-area :default [x] (area x))
(defmethod sci-scaled :default [x k] (scaled x k))

;; the other direction: a SCI record or type reaching the HOST protocol answers
;; through the SCI method its defrecord/deftype registered. Only a method the
;; type actually registered counts — the :default is the host protocol itself,
;; and answering through it here would loop.
(defn- sci-method [mm this]
  (let [f (get-method mm (sci.impl.types/type-impl this))]
    (when-not (identical? f (get-method mm :default)) f)))
(defn- via-sci [mm]
  (fn [this & args]
    (if-let [f (sci-method mm this)]
      (apply f this args)
      (throw (IllegalArgumentException.
              (str "No implementation of method: " mm " for SCI type: "
                   (sci.impl.types/type-impl this)))))))
(doseq [c [sci.impl.records.SciRecord sci.impl.deftype.SciType]]
  (extend c Shape {:area (via-sci sci-area) :scaled (via-sci sci-scaled)}))

(def shapes-ns (sci/create-ns 'shapes))
(def shapes-ctx
  (sci/init {:classes {:allow :all}
             :namespaces {'shapes {'Shape (sci/new-var 'shapes/Shape
                                                       {:methods #{sci-area sci-scaled}
                                                        :ns shapes-ns
                                                        :name 'shapes/Shape
                                                        :protocol Shape}
                                                       {:ns shapes-ns})
                                   'area (sci/copy-var* #'sci-area shapes-ns)
                                   'scaled (sci/copy-var* #'sci-scaled shapes-ns)
                                   'host-square (sci/copy-var* #'->HostSquare shapes-ns)}}}))

(check= "defrecord implementing the host protocol, called inside SCI" 9
        (sci/eval-string* shapes-ctx
          "(defrecord Sq [s] shapes/Shape (area [_] (* s s)) (scaled [_ k] (->Sq (* s k))))
           (shapes/area (->Sq 3))"))
(check= "a second method, with an extra argument" 16
        (sci/eval-string* shapes-ctx "(shapes/area (shapes/scaled (->Sq 2) 2))"))
;; deftype: SCI emits (do (-create-type ..) ~@(map analyze methods)) and analyzes
;; each method only as the evaluator reaches it, after the type exists — which
;; needs ~@ to be as lazy as the JVM's (seq (concat ..)) (corpus "~@ is lazy").
(check= "deftype implementing the host protocol, called inside SCI" 12
        (sci/eval-string* shapes-ctx
          "(deftype Rect [w h] shapes/Shape (area [_] (* w h)) (scaled [_ k] (->Rect (* w k) (* h k))))
           (shapes/area (->Rect 3 4))"))
(check= "a host record reaching the SCI method falls to the host protocol" 25
        (sci/eval-string* shapes-ctx "(shapes/area (shapes/host-square 5))"))
(check= "extend-type on a host class inside SCI" 3
        (sci/eval-string* shapes-ctx
          "(extend-type String shapes/Shape (area [s] (count s)) (scaled [s k] (apply str (repeat k s))))
           (shapes/area (shapes/scaled \"a\" 3))"))
(check= "extend-protocol to nil and Object inside SCI" [0 -1]
        (sci/eval-string* shapes-ctx
          "(extend-protocol shapes/Shape
              nil (area [_] 0) (scaled [_ _] nil)
              Object (area [_] -1) (scaled [o _] o))
           [(shapes/area nil) (shapes/area 42)]"))
(check= "satisfies? inside SCI sees the record, the type and the extension" [true true true]
        (sci/eval-string* shapes-ctx
          "[(satisfies? shapes/Shape (->Sq 1)) (satisfies? shapes/Shape (->Rect 1 1)) (satisfies? shapes/Shape \"s\")]"))

;; host side: values SCI built, handed to the host protocol
(let [sq (sci/eval-string* shapes-ctx "(->Sq 3)")
      rect (sci/eval-string* shapes-ctx "(->Rect 2 5)")]
  (check= "the host protocol on a SCI record" 9 (area sq))
  (check= "the host protocol on a SCI type" 10 (area rect))
  (check= "a host caller scaling a SCI record gets a SCI record back" 36
          (area (scaled sq 2)))
  (check= "a SCI record satisfies the host protocol" true (satisfies? Shape sq)))
(let [other (sci/eval-string* shapes-ctx "(defrecord Plain [x]) (->Plain 1)")]
  (check= "a SCI record whose type does not implement the protocol is refused, not looped"
          :refused
          (try (area other) :answered
               (catch IllegalArgumentException _ :refused))))
(println "SCI-FUNCTIONAL-TEST OK")
