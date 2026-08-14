(ns clojurestar.deps
  "Dialect-neutral dynamic dependency loading."
  (:require
   ;; :jolt ahead of :bb — jolt's reader matches both, and this facade must
   ;; bind to jolt.deps there, not babashka.deps.
   #?(:jolt [jolt.deps :as implementation]
      :bb [babashka.deps :as implementation]
      :glj [glojure.deps :as implementation]
      :lg [let-go.deps :as implementation]
      :clj [grenadine.jvm :as implementation])))

(defn add-deps
  "Add the Maven dependencies in a deps.edn map to the running dialect.

  This portable facade deliberately returns nil. Use the dialect-specific
  dependency namespace when backend-specific options or results are needed."
  [deps-map]
  (implementation/add-deps deps-map)
  nil)
