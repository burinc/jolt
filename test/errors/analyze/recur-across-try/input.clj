(ns input)

(defn f [x]
  (try
    (recur x)
    (catch Exception e nil)))

(println :compiled)
