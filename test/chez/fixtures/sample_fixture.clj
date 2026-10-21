(ns sample-fixture)

(defn spin [n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (+ acc (bit-and i 7)))
      acc)))

(defn hot [n] (inc (spin (* 3 n))))

(defn cold [n] (inc (spin n)))

(defn driver [n] (+ (hot n) (cold n)))
