;; Class reflection gate (epic jolt-of08.3) — the minimal reflective surface
;; over the modeled class hierarchy: getSuperclass / getInterfaces /
;; isAssignableFrom / isInterface, and java.lang.Object as a real token.
;; Everything answers from the ONE jch graph (class-hierarchy.ss), so a class
;; a library grafts on is reflectable with no core change.
;; Run: bin/jolt run test/chez/class-reflect-test.clj (smoke.sh greps for
;; "CLASS-REFLECT-TEST OK").
(ns class-reflect-test)

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; java.lang.Object is a real token
(check-eq "Object resolves to a Class" (class Object) java.lang.Class)
(check-eq "Object names itself" (.getName Object) "java.lang.Object")
(check-eq "isa? reaches Object" (isa? String Object) true)

;; getSuperclass walks the class (not interface) edge of the graph
(check-eq "String's superclass" (.getSuperclass String) Object)
(check-eq "Object has no superclass" (.getSuperclass Object) nil)
(check-eq "an interface has no superclass" (.getSuperclass clojure.lang.ISeq) nil)
(check-eq "exception chain: Arithmetic -> Runtime"
          (.getSuperclass ArithmeticException) RuntimeException)
(check-eq "exception chain: Runtime -> Exception"
          (.getSuperclass RuntimeException) Exception)
(check-eq "exception chain: Exception -> Throwable"
          (.getSuperclass Exception) Throwable)
(check-eq "exception chain: Throwable -> Object"
          (.getSuperclass Throwable) Object)
(check-eq "a concrete collection's superclass is the abstract base"
          (.getSuperclass clojure.lang.PersistentVector) clojure.lang.APersistentVector)

;; getInterfaces: the direct super-interfaces (order is the graph's; compare as a set)
(check-eq "String's direct interfaces"
          (set (map #(.getName %) (.getInterfaces String)))
          #{"java.lang.CharSequence" "java.lang.Comparable"})
(check-eq "Object has no interfaces" (seq (.getInterfaces Object)) nil)

;; isInterface
(check-eq "String is not an interface" (.isInterface String) false)
(check-eq "List is an interface" (.isInterface java.util.List) true)
(check-eq "ISeq is an interface" (.isInterface clojure.lang.ISeq) true)

;; isAssignableFrom: the graph's isa?, argument order as the JVM has it
(check-eq "Object assignable from String" (.isAssignableFrom Object String) true)
(check-eq "String not assignable from Object" (.isAssignableFrom String Object) false)
(check-eq "CharSequence assignable from String" (.isAssignableFrom CharSequence String) true)
(check-eq "reflexive" (.isAssignableFrom String String) true)
(check-eq "Throwable assignable from ex-info's class"
          (.isAssignableFrom Throwable clojure.lang.ExceptionInfo) true)

;; a defrecord grafts into the graph and reflects like any modeled class
(defrecord ReflectProbe [x])
(check-eq "record class assignable to IPersistentMap"
          (.isAssignableFrom clojure.lang.IPersistentMap ReflectProbe) true)
(check-eq "record class assignable to Object" (.isAssignableFrom Object ReflectProbe) true)

(if (empty? @failures)
  (println "CLASS-REFLECT-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "CLASS-REFLECT-TEST FAILED:" (count @failures))))
