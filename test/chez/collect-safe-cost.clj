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

;; best of three, so one scheduler hiccup does not decide the ratio
(defn best [f] (apply min (repeatedly 3 #(ns-per f 2000000))))

(let [plain (best c-abs) blocking (best c-abs-blocking)
      lockfree (boolean (jolt.host/scheme-eval-string "(foreign-entry? \"(cs)lockfree_activation\")"))]
  (println (format "LOCKFREE %s PLAIN %.1f BLOCKING %.1f RATIO %.2f"
                   lockfree plain blocking (/ blocking plain))))
