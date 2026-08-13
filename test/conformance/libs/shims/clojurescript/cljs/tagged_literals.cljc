;; cljs.tagged-literals stub, for conformance runs only.
;;
;; jolt drops org.clojure/clojurescript from a dependency graph on purpose (see
;; intrinsic-dep? in jolt/deps.clj) — there is no ClojureScript compiler here and
;; the coordinate drags in the closure toolchain — so a JVM suite that reaches
;; into the cljs namespaces has nothing to load.
;;
;; edamame's suite requires this namespace on the :clj branch for exactly one
;; thing: *cljs-data-readers*, which it hands to parse-string-all so a parse of
;; cljs.core's source does not stop at #js/#queue/#inst/#uuid. The readers below
;; behave like the real ones for that purpose. JSValue is the type the #js reader
;; wraps its form in; the suite only touches it on the :cljs branch.
(ns cljs.tagged-literals
  (:require [clojure.instant :as inst]))

(defn read-queue [form]
  (when-not (vector? form)
    (throw (RuntimeException. "Queue literal expects a vector for its elements.")))
  (list 'cljs.core/into 'cljs.core.PersistentQueue.EMPTY form))

(defn read-uuid [form]
  (when-not (string? form)
    (throw (RuntimeException. "UUID literal expects a string as its representation.")))
  (try
    (java.util.UUID/fromString form)
    (catch Throwable e
      (throw (RuntimeException. (.getMessage e))))))

(defn read-inst [form]
  (when-not (string? form)
    (throw (RuntimeException. "Instance literal expects a string for its timestamp.")))
  (try
    (inst/read-instant-date form)
    (catch Throwable e
      (throw (RuntimeException. (.getMessage e))))))

(defn valid-js-literal-key? [k]
  (or (string? k)
      (and (keyword? k) (nil? (namespace k)))))

(deftype JSValue [val])

(defn read-js [form]
  (when-not (or (vector? form) (map? form))
    (throw (RuntimeException. "JavaScript literal must use map or vector notation")))
  (when-not (or (not (map? form))
                (every? valid-js-literal-key? (keys form)))
    (throw (RuntimeException. "JavaScript literal keys must be strings or unqualified keywords")))
  (JSValue. form))

(def ^:dynamic *cljs-data-readers*
  (merge *data-readers*
         {'queue read-queue
          'uuid read-uuid
          'inst read-inst
          'js read-js}))
