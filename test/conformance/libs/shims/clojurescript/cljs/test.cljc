;; cljs.test stub, for conformance runs only. See tagged_literals.cljc beside it
;; for why the cljs namespaces are not resolvable on jolt at all.
;;
;; The real cljs.test is a macro namespace built on the ClojureScript compiler —
;; its :clj branch requires cljs.analyzer and cljs.env. A JVM Clojure suite that
;; wants a custom `is` assertion for both hosts registers it twice, once on
;; clojure.test/assert-expr and once on cljs.test/assert-expr; edamame's
;; test-utils does exactly that. Only the clojure.test method is ever dispatched
;; when the suite runs here — this one exists so the defmethod has a multimethod
;; to attach to and the namespace compiles.
(ns cljs.test)

;; Same dispatch as the real one: the head symbol of the assertion form.
(defmulti assert-expr
  (fn [_menv _msg form]
    (cond (nil? form) :always-fail
          (seq? form) (first form)
          :else :default)))

(defmethod assert-expr :default [_menv _msg form] form)

;; Referenced from inside the syntax-quoted expansions the registered methods
;; emit. Those expansions are never evaluated on this host.
(defn do-report [m] m)
