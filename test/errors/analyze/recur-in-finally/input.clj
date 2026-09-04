(ns input)

(defn f []
  (loop [i 0]
    (try
      i
      (finally
        (recur (inc i))))))

(println :compiled)
