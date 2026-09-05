(ns input)

(defn f [x]
  (loop [i 0]
    (try
      (/ x i)
      (catch Exception e
        (recur (inc i))))))

(println :compiled)
