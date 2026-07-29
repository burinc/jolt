(ns app.core
  (:require [app.other :as-alias o]))
;; ::o/x resolves through the alias at READ time, so it works without the target
;; ever being loaded — the point of :as-alias.
(def k ::o/x)
(defn -main [& _]
  (println :kw k :aliased (some? (get (ns-aliases 'app.core) 'o))))
