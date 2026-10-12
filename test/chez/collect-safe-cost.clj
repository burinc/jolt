;; The cost of a :blocking (collect-safe) foreign call against a plain one, in
;; one process (collect-safe-activation-test.sh reads the ratio). On a stock
;; Chez kernel a collect-safe call takes the tc mutex four times and locks the
;; calling code object, ~8x a plain call; on a kernel with jolt's
;; lockfree-activation patch it is two CASes and a fence.
(ns collect-safe-cost (:require [jolt.ffi :as ffi]))

(ffi/defcfn c-abs "abs" [:int] :int)
(ffi/defcfn c-abs-blocking "abs" [:int] :int :blocking)

(defn run [f n] (loop [i 0 acc 0] (if (< i n) (recur (inc i) (+ acc (f (- i)))) acc)))
(defn ns-per [f n]
  (run f 200000)
  (let [t0 (System/nanoTime) _ (run f n) t1 (System/nanoTime)]
    (/ (double (- t1 t0)) n)))

;; Each round times the two back to back, and the ratio is the median round's.
;; A slow stretch on a shared runner then lands on both halves of a round or
;; spoils one round; taking each side's best separately let it land on one side
;; only (1.5-2x usually, 3.07x once on CI).
(let [rounds (sort-by (fn [[p b]] (/ b p))
                     (repeatedly 7 (fn [] [(ns-per c-abs 1000000) (ns-per c-abs-blocking 1000000)])))
      [plain blocking] (nth rounds (quot (count rounds) 2))
      lockfree (boolean (jolt.host/scheme-eval-string "(foreign-entry? \"(cs)lockfree_activation\")"))]
  (println (format "LOCKFREE %s PLAIN %.1f BLOCKING %.1f RATIO %.2f"
                   lockfree plain blocking (/ blocking plain))))
