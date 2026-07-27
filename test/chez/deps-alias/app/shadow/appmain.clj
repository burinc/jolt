;; Shadows src/appmain.clj. The :shadow alias puts this directory on the roots
;; as an :extra-path, which the clj CLI orders BEFORE the project's :paths — so
;; requiring appmain must load this copy, not src/appmain.clj.
(ns appmain)
(defn -main [& args] (println "shadowed"))
