;; clojure.pprint dispatch-fn gate: simple-dispatch and code-dispatch must be
;; real multimethods on class so libraries can extend them. The driver is
;; core.logic's nominal namespace, which does
;;   (. clojure.pprint/simple-dispatch addMethod Tie pprint-tie)
;; and dies with "No matching method addMethod found for clojure.pprint$simple
;; _dispatch" while those vars are plain functions.
;;
;; Not a corpus row: it requires loading clojure.pprint and registering methods,
;; which the corpus runner never does. Runs through the real CLI like the
;; instant / cl-format suites; emits PPRINT-DISPATCH OK / FAIL for smoke.sh.
;;
;; The built-in arms are asserted against the exact strings the old plain-fn case
;; form produced (captured before this change). A defrecord still prints as a
;; bare map: pprint routes it through IPersistentMap, as it does on the JVM --
;; pr is the one that prints #ns.R{...}, so changing that here would be a
;; regression, not a fix.
;;
;; Order matters: the addMethod / defmethod tests below MUTATE the global
;; dispatch table (that is what they exist to test). On the unfixed code
;; (defmethod on a plain fn redefines the var as a fresh, near-empty
;; multimethod), so anything that reads simple-dispatch's table must run first.
;; The no-ambiguity check therefore leads, on the pristine dispatch; the
;; mutation tests come last.
(ns pprint-dispatch-gate
  (:require [clojure.pprint :refer [pprint]]))

(def ^:private fails (atom []))
(def ^:private passes (atom 0))

(defn- ok= [got want label]
  (if (= got want)
    (swap! passes inc)
    (swap! fails conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(defn- ok [thunk label]
  (try (thunk) (swap! passes inc)
       (catch Throwable e (swap! fails conj (str label ": threw " (.getMessage e))))))

(defn- out [obj] (with-out-str (pprint obj)))

(defrecord R [a])

;; --- no dispatch ambiguity across the full type space (read first, pristine) ----
;; On the unfixed code simple-dispatch is a plain fn, so this branch records one
;; failure ("is a multimethod" => false) and skips -- the run then fails only on
;; that plus the addMethod/defmethod cases below. On the fixed code it fires and
;; demands get-method resolve to a real method for every type's class; get-method
;; throws "Multiple methods" on any value matching two arms -- the ordering hazard
;; the task warned about (a record is IPersistentMap + IRecord; a map and a vector
;; are both Associative). The method bodies never run, so this is pure dispatch
;; resolution, not a pretty-writer check.
(let [multifn? (instance? clojure.lang.MultiFn clojure.pprint/simple-dispatch)]
  (ok= multifn? true "simple-dispatch is a multimethod")
  (when multifn?
    (doseq [[label obj] [["vector" [1 2]] ["array-map" (array-map :a 1)]
                         ["hash-map" {:b 2}] ["sorted-map" (sorted-map :c 3)]
                         ["hash-set" #{1}] ["sorted-set" (sorted-set 2)]
                         ["queue" (into clojure.lang.PersistentQueue/EMPTY [1])]
                         ["list" (list 1)] ["lazy-seq" (lazy-seq (cons 1 nil))]
                         ["vec-seq" (seq [1])] ["map-seq" (seq {:a 1})]
                         ["record" (->R 1)] ["nil" nil] ["atom" (atom 1)]
                         ["string" "x"] ["keyword" :k]]]
      (ok= (some? (get-method clojure.pprint/simple-dispatch (class obj))) true
           (str "simple-dispatch resolves a " label " without ambiguity"))
      (ok= (some? (get-method clojure.pprint/code-dispatch (class obj))) true
           (str "code-dispatch resolves a " label " without ambiguity")))))

;; --- built-in arms print exactly what the old case form produced ---------------
(ok= (out [1 2 3])      "[1 2 3]\n" "vector arm")
(ok= (out {:a 1})       "{:a 1}\n"  "map arm")
(ok= (out #{1})         "#{1}\n"    "set arm")
(ok= (out (list 1 2 3)) "(1 2 3)\n" "seq arm")
(ok= (out nil)          "nil\n"     "nil arm")
(ok= (out (->R 1))      "{:a 1}\n"  "record prints as a bare map")

;; --- code-dispatch: the Symbol arm honours *print-suppress-namespaces* ---------
;; Read before the mutation tests; it binds *print-pprint-dispatch* to code-dispatch
;; but does not alter the dispatch tables.
(ok= (binding [clojure.pprint/*print-pprint-dispatch* clojure.pprint/code-dispatch
               clojure.pprint/*print-suppress-namespaces* true]
       (out 'foo.bar/baz))
     "baz\n"
     "code-dispatch drops a symbol's namespace under *print-suppress-namespaces*")
(ok= (binding [clojure.pprint/*print-pprint-dispatch* clojure.pprint/code-dispatch]
       (out 'foo.bar/baz))
     "foo.bar/baz\n"
     "code-dispatch keeps a symbol's namespace without suppression")

;; --- the interop form core.logic uses: (. simple-dispatch addMethod Type f) -----
;; These mutate the dispatch table. On a record's class (an IPersistentMap) the
;; exact-class method must win over the built-in IPersistentMap arm.
(defrecord Widget [n])
(def widget-class (class (->Widget 0)))
(ok #(do (. clojure.pprint/simple-dispatch addMethod widget-class
            (fn [x] (print (str "W-" (:n x)))))
         nil)
    "simple-dispatch addMethod interop registers without error")
(ok= (out (->Widget 7)) "W-7\n" "a Widget pprint routes through its addMethod method")

;; --- defmethod against simple-dispatch -----------------------------------------
(defrecord Gadget [n])
(def gadget-class (class (->Gadget 0)))
(ok #(do (defmethod clojure.pprint/simple-dispatch gadget-class [x]
           (print (str "G-" (:n x))))
         nil)
    "defmethod against simple-dispatch registers without error")
(ok= (out (->Gadget 4)) "G-4\n" "a Gadget pprint routes through its defmethod method")

;; --- verdict -------------------------------------------------------------------
(let [n @passes f @fails]
  (doseq [m f] (println "pprint-dispatch FAIL " m))
  (println "PPRINT-DISPATCH-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "PPRINT-DISPATCH OK" "PPRINT-DISPATCH FAIL"))
  (flush))
