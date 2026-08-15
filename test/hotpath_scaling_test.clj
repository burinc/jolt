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

  ;; protocol-count shape independence: a record collection op looks for a
  ;; declared impl before falling back to the record behaviour, and that lookup
  ;; used to snapshot the type's protocol keys under a mutex and probe each one
  ;; — so count/contains?/seq on a record got slower the more protocols its type
  ;; implemented, while answering "none declared" every time. Two records with
  ;; identical fields, one implementing 1 protocol and one implementing 8: the
  ;; per-op cost must not track the protocol count.
  (let [reps 40000
        one (eval '(do (ns proto-shape-ns)
                       (defrecord POne [x y z])
                       (defprotocol PA (pa [_]))
                       (extend-protocol PA POne (pa [_] 1))
                       (->POne 1 2 3)))
        many (eval '(do (ns proto-shape-ns)
                        (defrecord PMany [x y z])
                        (defprotocol PB (pb [_])) (defprotocol PC (pc [_]))
                        (defprotocol PD (pd [_])) (defprotocol PE (pe [_]))
                        (defprotocol PF (pf [_])) (defprotocol PG (pg [_]))
                        (defprotocol PH (ph [_])) (defprotocol PI (pi* [_]))
                        (extend-protocol PB PMany (pb [_] 1))
                        (extend-protocol PC PMany (pc [_] 1))
                        (extend-protocol PD PMany (pd [_] 1))
                        (extend-protocol PE PMany (pe [_] 1))
                        (extend-protocol PF PMany (pf [_] 1))
                        (extend-protocol PG PMany (pg [_] 1))
                        (extend-protocol PH PMany (ph [_] 1))
                        (extend-protocol PI PMany (pi* [_] 1))
                        (->PMany 1 2 3)))
        _ (when-not (and (= 3 (count one)) (= 3 (count many))
                         (contains? one :x) (contains? many :x))
            (println "FAIL hotpath proto-shape: record ops answered wrong")
            (System/exit 1))
        probe (fn [r] #(dotimes [_ reps] (do (count r) (contains? r :x) (seq r))))
        t1 (max 1 (best-of 3 (probe one)))
        t8 (best-of 3 (probe many))]
    (judge "proto-shape" t1 t8 3.0
           "record collection ops are re-walking the type's protocol table (find-method-any-protocol, protocols.ss) — 8 protocols cost more than 1"))

  (if (pos? @failures)
    (do (println (str "hotpath-scaling: " @failures " section(s) failed"))
        (System/exit 1))
    (println "hotpath-scaling: passed")))

(-main)
