;; char-scan-unhinted — the twin of `char-scan` with the declared tags removed.
;; Same four shapes, same string, same sizes; no `^String` on a target and no
;; `^long` on a parameter or return.
;;
;; The casts written INSIDE the loops stay, because they are the code under
;; measurement: honeysql's `alphanumeric?` is written that way, and what the
;; original benchmark exists to price is what those casts cost. What goes is every
;; tag that let the compiler prove the receiver or the index ahead of them, so
;; `.charAt` and `.length` reach the generic dispatcher.
;;
;; Kept as its own suite entry because ci/bench-gate.sh compares a ratio PER
;; BENCHMARK: with one row, a round that speeds the proven path while slowing the
;; generic one nets out to roughly nothing and is invisible.
;;
;; A transcription of char_scan.clj — edit the two together; what differs is
;; exactly the tags. The phase names are kept verbatim so a row here is obviously
;; comparable to the row there, which is why `count-digits-hinted` still carries
;; that name with nothing declared on it.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh char-scan-unhinted 40000
(ns char-scan-unhinted)

(def entities ["table" "some_column" "a" "x1" "SELECT" "order_by_2" "_leading" "42"])
(def sentence "the quick brown fox jumps over the lazy dog 0123456789")

;; --- honeysql's alphanumeric?, verbatim in shape ------------------------------
;; `^(?:[0-9_]+|[A-Za-z_][A-Za-z0-9_]*)$` as a state machine. The three casts per
;; character — the index, the char, and the widening — are the point.
(defn alphanumeric? [s]
  (let [leading-underscore 1
        numeric 2
        identifier 3
        dead 4
        n (long (.length s))]
    (loop [i (unchecked-long 0)
           state (unchecked-long 0)]
      (if (or (= state dead) (>= i n))
        (or (= state leading-underscore) (= state numeric) (= state identifier))
        (let [c  (.charAt s (unchecked-int i))
              c  (unchecked-long (unchecked-int c))
              ni (unchecked-inc i)]
          (case state
            0 (cond (or (and (>= c 65) (<= c 90)) (and (>= c 97) (<= c 122)))
                    (recur ni identifier)
                    (and (>= c 48) (<= c 57)) (recur ni numeric)
                    (= c 95) (recur ni leading-underscore)
                    :else (recur ni dead))
            1 (cond (or (and (>= c 65) (<= c 90)) (and (>= c 97) (<= c 122)))
                    (recur ni identifier)
                    (and (>= c 48) (<= c 57)) (recur ni identifier)
                    (= c 95) (recur ni leading-underscore)
                    :else (recur ni dead))
            2 (if (or (and (>= c 48) (<= c 57)) (= c 95))
                (recur ni numeric)
                (recur ni dead))
            3 (if (or (and (>= c 65) (<= c 90)) (and (>= c 97) (<= c 122))
                      (and (>= c 48) (<= c 57)) (= c 95))
                (recur ni identifier)
                (recur ni dead))
            (recur ni dead)))))))

;; --- the same walk with no state machine: casts and .charAt only --------------
(defn sum-code-points [s]
  (let [n (long (.length s))]
    (loop [i 0 acc 0]
      (if (>= i n)
        acc
        (recur (unchecked-inc i)
               (unchecked-add acc (unchecked-long (unchecked-int (.charAt s (unchecked-int i))))))))))

;; --- the checked casts, which are the ones ordinary code writes ---------------
(defn count-digits [s]
  (let [n (int (.length s))]
    (loop [i 0 acc 0]
      (if (>= i n)
        acc
        (let [c (long (int (.charAt s (int i))))]
          (recur (inc i) (if (and (>= c 48) (<= c 57)) (inc acc) acc)))))))

;; --- the same walk with the index passed, not cast per use -------------------
;; Nothing is declared, so the parameter carries no promise and the body is
;; generic arithmetic over it — the contrast the hinted twin's row measures.
(defn count-digits-hinted [s from]
  (let [n (.length s)]
    (loop [i from acc 0]
      (if (>= i n)
        acc
        (let [c (long (int (.charAt s i)))]
          (recur (inc i) (if (and (>= c 48) (<= c 57)) (inc acc) acc)))))))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add (reduce (fn [a e] (if (alphanumeric? e) (inc a) a)) 0 entities)
                              (sum-code-points sentence))
               (unchecked-add (count-digits sentence)
                              (count-digits-hinted sentence 0)))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 40000)]
    (dotimes [_ 2] (run (quot iters 4)))                 ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run iters)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))))
