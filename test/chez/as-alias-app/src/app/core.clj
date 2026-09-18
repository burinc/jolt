(ns app.core
  (:require [app.other :as-alias o]))
;; ::o/x resolves through the alias at READ time, so it works without the target
;; ever being loaded — the point of :as-alias.
(def k ::o/x)
(def m #::o{:x 1})
(defn -main [& _]
  (println :kw k :map (get m :app.other/x)
           :aliased (some? (get (ns-aliases 'app.core) 'o))))
