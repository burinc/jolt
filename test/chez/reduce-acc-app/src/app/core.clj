(ns app.core)

;; A 0.0-seeded accumulator whose closure always returns a flonum keeps its
;; :double seed, so the closure body still lowers to fl+/fl* (build-smoke greps
;; flat.ss for it) — the fixpoint below must not cost this shape its unboxing.
(defn sumsq [v]
  (reduce (fn [acc x] (+ acc (* x x))) 0.0 v))

;; The accumulator crosses a fn boundary: the closure hands it to a defn, so the
;; whole-program fixpoint types pick's b from this call site — it must see the
;; converged accumulator, not the nil init, or (nil? b) folds inside pick too.
(defn pick [b x] (if (or (nil? b) (< x b)) x b))

(defn -main [& _]
  ;; The accumulator of a reduce closure is the init on the FIRST call only; after
  ;; that it is whatever the closure returned. Inference seeded it from the init
  ;; alone, so under --opt a nil init proved acc :nil and nil?/some? folded to
  ;; constants, and a string init proved acc :str and string? folded true with
  ;; count lowered to string-length. These printed 7, [3] and crashed on
  ;; (string-length 3) instead of 1, [1 2 3] and 8.
  (println (reduce (fn [b x] (if (or (nil? b) (< x b)) x b)) nil [5 3 9 1 7]))
  (println (reduce (fn [acc x] (if (some? acc) (conj acc x) [x])) nil [1 2 3]))
  (println (reduce (fn [acc x] (if (string? acc) (count acc) (+ acc x))) "abc" [1 2 3]))
  (println (sumsq [1.0 2.0 3.0]))
  ;; a 0.0 init whose closure sometimes returns a long: the :double seed put a
  ;; ^double hint on acc, so the long came back coerced and this printed 2.0 where
  ;; the JVM answers (+ 0 2) = 2.
  (println (reduce (fn [acc x] (if (pos? x) (+ acc x) 0)) 0.0 [1.0 -1.0 2]))
  (println (reduce (fn [b x] (pick b x)) nil [5 3 9 1 7]))
  ;; nested: the inner reduce's init is the outer accumulator
  (println (reduce (fn [b xs] (reduce (fn [b x] (if (or (nil? b) (< x b)) x b)) b xs))
                   nil [[5 3] [9 1 7]]))
  ;; the loop analogue: a nil-initialized loop var rebound by recur (loop vars are
  ;; typed :any by design; this pins that the same fold never reaches them)
  (println (loop [b nil xs [5 3 9 1 7]]
             (if (empty? xs)
               b
               (recur (if (or (nil? b) (< (first xs) b)) (first xs) b) (rest xs))))))
