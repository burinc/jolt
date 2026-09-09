;; `apply` must hand a variadic its rest LAZILY, never a materialized list.
;;
;; jolt-apply (host/chez/seq.ss) gives a REGISTERED variadic its rest as a boxed
;; lazy seq and falls back to (seq->list …) for everything else. The natives that
;; post-prelude.ss installs as the var roots for + - * / min max and the
;; comparison chains are plain Scheme variadics, and until they were registered
;; every one of them took the fallback — so (apply max (range)) realized the seq
;; until the process died, where the reference folds it in constant space.
;;
;; Two independent assertions, because they fail differently:
;;
;;   SPACE — + and max cannot short-circuit, so they get the shape check:
;;   quadrupling the argument count must not quadruple the heap. The reading is
;;   the collector's own high-water mark (jolt.host/maximum-memory-bytes, reset
;;   before each arm), never a sample: a watcher thread reading the live heap
;;   sees collector timing, and two streaming arms then measure two accidents
;;   whose ratio can land anywhere — 1MB vs 3MB failed a CI run at 3.00. The
;;   mark is floored at one collection trip (jolt.host/gc-trip-bytes): between
;;   two collections at most that much is allocated, so work that holds nothing
;;   can raise the footprint by up to a trip and no more, and anything under it
;;   is invisible by construction. Two streaming arms read the floor, ratio 1.
;;   A materialized rest holds n elements at once and reads its own size, so
;;   the ratio lands near 4. A control arm applies max to a vector that IS held
;;   for the whole call and must read above the ceiling first, so a reading
;;   that cannot see a materialized rest fails as blind rather than passing.
;;
;;   TERMINATION — a comparison chain short-circuits on its second element, so
;;   (apply > (range)) is false the moment it looks at 0 and 1. Streaming answers
;;   immediately; materializing cannot answer at all, because it has to build an
;;   infinite list before the chain runs. This one is exact: no timing, no
;;   heap reading, it either returns or the gate times out. It runs LAST: its
;;   deadline needs threads, and the SPACE arms want a process with none, where
;;   System/gc is a real collection rather than the guarded no-op it becomes
;;   under live threads.

(ns apply-scaling-test)

(def ^:private n1 2000000)
(def ^:private factor 4)
;; Streaming measures 1 exactly and a materialized rest ~4, so the line sits
;; between them.
(def ^:private max-ratio 2.0)
(def ^:private mb 1048576)

(defn- peak-growth
  "[floored-mb raw-mb]: how far the heap footprint rose while f ran, from the
  collector's high-water mark reset before f and read after it, floored at one
  collection trip."
  [f]
  (System/gc)
  (jolt.host/reset-maximum-memory-bytes!)
  (let [base (jolt.host/current-memory-bytes)]
    (f)
    (let [growth (- (jolt.host/maximum-memory-bytes) base)
          floor (jolt.host/gc-trip-bytes)]
      [(max 1 (quot (max growth floor) mb)) (quot growth mb)])))

(defn- report [label [m1 raw1] [m4 raw4]]
  (let [ratio (double (/ m4 m1))]
    (println (format "apply-scaling %s: %dMB vs %dMB (x%d args) ratio %.2f (ceiling %.1f; raw %dMB vs %dMB, floor %dMB)"
                     label m1 m4 factor ratio max-ratio raw1 raw4 (quot (jolt.host/gc-trip-bytes) mb)))
    ratio))

(defn- judge [label g1 g4]
  (when (> (report label g1 g4) max-ratio)
    (println (str "FAIL apply-scaling: " label " grows with the argument count — "
                  "apply is materializing the rest instead of streaming it. The "
                  "native is missing its jolt-register-variadic! (host/chez/seq.ss)."))
    (System/exit 1)))

(defn- judge-control [label g1 g4]
  (when-not (> (report label g1 g4) max-ratio)
    (println (str "FAIL apply-scaling: " label " is a rest HELD for the whole call and must read "
                  "above the ceiling — it did not, so this reading cannot see a materialized "
                  "rest and the arms below prove nothing (jolt.host/maximum-memory-bytes)."))
    (System/exit 1)))

(defn -main [& _]
  ;; values first: a fast wrong answer is not a pass
  (when-not (and (= 6 (apply + [1 2 3])) (= 6 (apply + 1 [2 3])) (= 0 (apply + []))
                 (= -5 (apply - [5])) (= 7 (apply - [10 1 2])) (= 1/4 (apply / [4]))
                 (= 9 (apply max [1 9 2])) (= 2 (apply min 4 [7 2]))
                 (true? (apply < [1 2 3])) (false? (apply < [1 3 2])))
    (println "FAIL apply-scaling: wrong values before any measurement — fix that first")
    (System/exit 1))

  ;; SPACE: the yardstick first, then the shape.
  (apply + (range 1000)) (apply max (range 1000))          ; warm
  (judge-control "control: apply max over a held vector"
                 (peak-growth #(apply max (vec (range n1))))
                 (peak-growth #(apply max (vec (range (* factor n1))))))
  (judge "apply +"
         (peak-growth #(apply + (range n1)))
         (peak-growth #(apply + (range (* factor n1)))))
  (judge "apply max"
         (peak-growth #(apply max (range n1)))
         (peak-growth #(apply max (range (* factor n1)))))

  ;; TERMINATION: unbounded seq, short-circuiting chain. A materializing apply
  ;; cannot answer at all, so run each on a future and give it a deadline —
  ;; otherwise the regression this guards would HANG the gate instead of failing
  ;; it, which reads as a stuck runner rather than a broken build.
  (doseq [[label f] [["(apply > (range))" #(apply > (range))]
                     ["(apply < (repeat 5))" #(apply < (repeat 5))]]]
    (let [answer (deref (future (f)) 20000 ::timeout)]
      (when-not (false? answer)
        (println (str "FAIL apply-scaling: " label " answered " (pr-str answer)
                      " — expected false. apply is materializing an unbounded rest "
                      "instead of streaming it (host/chez/seq.ss "
                      "jolt-register-variadic! on the comparison chains)."))
        (System/exit 1))))
  (println "apply-scaling termination: comparison chains stream an unbounded rest")
  (println "apply-scaling: passed"))

(-main)
