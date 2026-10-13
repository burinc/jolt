(ns input)

(defn f []
  (binding [*later* 5] *later*))

(def ^:dynamic *later* 1)
