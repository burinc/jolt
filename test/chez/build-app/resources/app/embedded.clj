(ns app.embedded
  "Linked into the image AND embedded as a resource (deps.edn :embed
   [\"resources\"]) — the shape of every app namespace in a build whose
   :jolt/build :embed names its own source root, kmet's `src` among them.

   A runtime (require 'app.embedded) must dedup to a no-op: the image already
   loaded and ran this file. Unmarked, the loader finds THIS embedded source
   and re-evaluates the namespace in place — the forward-reference shape below
   flips, exactly the runtime half of #451 (the emit walk is not involved on a
   runtime require).")

;; A fresh Object per evaluation: -main reads it, requires this namespace, and
;; reads it again — a re-evaluation shows as a changed identity.
(def loaded-stamp (Object.))

;; Compiled BEFORE the same-ns `get` redefinition below, so its bare `get` is
;; clojure.core/get in an in-order load. A re-evaluation happens against the
;; namespace already holding `get`, so the reloaded fwd-get would call the
;; request helper backwards and throw (String cannot be cast to Associative).
(defn fwd-get [env k] (get env k))

#_{:clj-kondo/ignore [:redefined-var]}
(defn get [url opts] (assoc opts :url url :method :get))
