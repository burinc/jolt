(ns app.other)
;; A load-time side effect, so the gate can tell whether this namespace was pulled
;; into the binary. :as-alias must NOT pull it in.
(println "as-alias-app: app.other was loaded")
(def marker :loaded)
