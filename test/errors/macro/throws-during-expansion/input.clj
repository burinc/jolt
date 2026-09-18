(ns input)

(defmacro boom []
  (throw (ex-info "macro blew up" {:while :expanding})))

(defn f [] (boom))
