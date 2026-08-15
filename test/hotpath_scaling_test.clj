;; Hot-path shape gates: split-with-limit, timeout arming, deque draining,
;; StringTokenizer, ns-publics/refer, and set/intersection must not scale
;; worse than linearly (or must be independent of a dimension they used to
;; scale with). One file, one boot: each section is the same in-process
;; judgment as read_scaling_test.clj — best-of-3, only ratios, sized so a
;; REGRESSED implementation still finishes and fails rather than hanging.
;;
;; What each section pins (all were real, found in the 2026-08 structural
;; sweep):
;;   split      (.split s LIMIT) recomputed (length out) per part — O(parts^2).
;;   timeout    core.async timeout arming was a linear sorted-list insert —
;;              O(k^2) for a burst; now a binary min-heap.
;;   deque      ArrayDeque/LinkedList front ops shifted the whole backing
;;              vector — the standard .poll worklist idiom was O(n^2).
;;   tokenizer  StringTokenizer called length/list-ref per token — O(n^2).
;;   ns-shape   ns-publics/refer scanned EVERY interned var in the image, so a
;;              3-var namespace cost O(total vars) — judged as shape
;;              independence: interning 30k unrelated vars must not change
;;              what ns-publics of a tiny ns costs.
;;   set-shape  intersection walked its FIRST argument — big ∩ small must cost
;;              what small ∩ big costs (the reference's smaller-side swap).

(ns hotpath-scaling-test
  (:require [clojure.string :as str]
            [clojure.set :as set]
            [clojure.core.async :as async]))

(defn- timed [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

(def ^:private failures (atom 0))

(defn- judge [label t1 t4 ceiling detail]
  (let [t1 (max 1 t1)
        ratio (double (/ t4 t1))]
    (println (format "hotpath %-9s %4dms vs %4dms, ratio %6.2f (ceiling %.1f)"
                     label t1 t4 ratio (double ceiling)))
    (when (> ratio ceiling)
      (println (str "FAIL hotpath " label ": " detail))
      (swap! failures inc))))

;; --- split with a positive limit ---------------------------------------------
(defn- split-drain [n]
  (let [s (str/join "," (range n))]
    (count (str/split s #"," 10000000))))

;; --- timeout arming: k pending timers, far-future distinct deadlines ---------
(defn- arm-timeouts [k base-ms]
  (dotimes [i k] (async/timeout (+ base-ms i)))
  k)

;; --- deque drain -------------------------------------------------------------
(defn- deque-drain [n]
  (let [d (java.util.ArrayDeque.)]
    (dotimes [i n] (.addLast d i))
    (loop [c 0] (if (nil? (.poll d)) c (recur (inc c))))))

;; --- StringTokenizer drain ---------------------------------------------------
(defn- tok-drain [n]
  (let [s (str/join " " (repeat n "tok"))
        t (java.util.StringTokenizer. s)]
    (loop [c 0] (if (.hasMoreTokens t) (do (.nextToken t) (recur (inc c))) c))))

(defn -main [& _]
  ;; correctness spot-checks before any cost is judged
  (when-not (and (= (str/split "a,b,c" #"," 5) ["a" "b" "c"])
                 (= (str/split "a,b,c" #"," 2) ["a" "b,c"])
                 (= 5 (deque-drain 5))
                 (= 5 (tok-drain 5))
                 (= #{2} (set/intersection #{1 2} #{2 3}))
                 (= #{2} (set/intersection (set (range 1000)) #{2})))
    (println "FAIL hotpath: wrong results from a fixed path")
    (System/exit 1))

  (let [n1 4000]
    (judge "split" (best-of 3 #(split-drain n1)) (best-of 3 #(split-drain (* 4 n1))) 8.0
           "re-split is recomputing (length out) per part again (natives-str.ss)")
    (judge "deque" (best-of 3 #(deque-drain n1)) (best-of 3 #(deque-drain (* 4 n1))) 8.0
           "ArrayDeque front ops are shifting the backing vector again (host-static-classes.ss)")
    (judge "tokenizer" (best-of 3 #(tok-drain n1)) (best-of 3 #(tok-drain (* 4 n1))) 8.0
           "StringTokenizer is scanning its token list per token again (host-static-classes.ss)"))

  ;; timeout arming: single measurement per size (arming is not idempotent —
  ;; a second best-of run would arm into a heap pre-loaded by the first, which
  ;; is fine for a heap but distorts the pre/post comparison), far-future
  ;; deadlines so nothing fires mid-measure.
  (let [k 2000
        [t1 _] (timed #(arm-timeouts k 3600000))
        [t4 _] (timed #(arm-timeouts (* 4 k) 7200000))]
    (judge "timeout" t1 t4 8.0
           "timeout-insert! is walking the pending list per arm again (async.ss)"))

  ;; ns-publics shape independence: a tiny namespace's ns-publics must not get
  ;; slower because unrelated vars exist. R repetitions beat the clock floor.
  (let [_ (eval '(do (ns tiny-probe-ns) (def a 1) (def b 2) (def c 3) (ns hotpath-scaling-test)))
        reps 300
        probe #(dotimes [_ reps] (ns-publics 'tiny-probe-ns))
        t-before (best-of 3 probe)
        _ (doseq [i (range 30)]
            (let [n (create-ns (symbol (str "bulk-ns-" i)))]
              (dotimes [j 1000] (intern n (symbol (str "v" j)) 1))))
        t-after (best-of 3 probe)]
    (judge "ns-shape" t-before t-after 3.0
           "ns-publics is scanning the whole var table again (ns.ss) — 30k unrelated vars changed a 3-var namespace's cost"))

  ;; intersection shape independence: big ∩ small vs small ∩ big.
  (let [big (set (range 100000))
        small #{1 2 3}
        reps 200
        t-bs (best-of 3 #(dotimes [_ reps] (set/intersection big small)))
        t-sb (max 1 (best-of 3 #(dotimes [_ reps] (set/intersection small big))))
        ratio (double (/ t-bs t-sb))]
    (println (format "hotpath set-shape %4dms vs %4dms, ratio %6.2f (ceiling 5.0)" t-bs t-sb ratio))
    (when (> ratio 5.0)
      (println "FAIL hotpath set-shape: intersection is walking its larger argument (set.clj)")
      (swap! failures inc)))

  (if (pos? @failures)
    (do (println (str "hotpath-scaling: " @failures " section(s) failed"))
        (System/exit 1))
    (println "hotpath-scaling: passed")))

(-main)
