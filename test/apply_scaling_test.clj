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
;;   TERMINATION — a comparison chain short-circuits on its second element, so
;;   (apply > (range)) is false the moment it looks at 0 and 1. Streaming answers
;;   immediately; materializing cannot answer at all, because it has to build an
;;   infinite list before the chain runs. This one is exact: no timing, no
;;   heap reading, it either returns or the gate times out.
;;
;;   SPACE — + and max cannot short-circuit, so they get the shape check instead:
;;   quadrupling the argument count must not quadruple the heap. Streaming holds
;;   the ratio near 1; a materialized rest list lands near 4. Only the ratio is
;;   judged, from one process, so machine size does not matter.

(ns apply-scaling-test)

(def ^:private n1 2000000)
(def ^:private factor 4)
;; Streaming measures ~1 and a materialized list ~4, so the line sits between
;; them with room for collector noise on a loaded machine.
(def ^:private max-ratio 2.0)

(defn- live-mb [] (long (/ (jolt.host/current-memory-bytes) 1048576)))

(defn- peak-during
  "Peak live heap (MB) observed while f runs, sampled from a watcher thread —
  the allocation we are looking for is transient, so a before/after reading
  would miss it entirely."
  [f]
  (let [peak (atom 0) done (atom false)
        w (Thread. (fn [] (while (not @done) (swap! peak max (live-mb)))))]
    (.start w)
    (let [base (live-mb)]
      (f)
      (reset! done true)
      (.join w 2000)
      (max 1 (- @peak base)))))

(defn- judge [label m1 m4]
  (let [ratio (double (/ m4 m1))]
    (println (format "apply-scaling %s: %dMB vs %dMB (x%d args) ratio %.2f (ceiling %.1f)"
                     label m1 m4 factor ratio max-ratio))
    (when (> ratio max-ratio)
      (println (str "FAIL apply-scaling: " label " grows with the argument count — "
                    "apply is materializing the rest instead of streaming it. The "
                    "native is missing its jolt-register-variadic! (host/chez/seq.ss)."))
      (System/exit 1))))

(defn -main [& _]
  ;; values first: a fast wrong answer is not a pass
  (when-not (and (= 6 (apply + [1 2 3])) (= 6 (apply + 1 [2 3])) (= 0 (apply + []))
                 (= -5 (apply - [5])) (= 7 (apply - [10 1 2])) (= 1/4 (apply / [4]))
                 (= 9 (apply max [1 9 2])) (= 2 (apply min 4 [7 2]))
                 (true? (apply < [1 2 3])) (false? (apply < [1 3 2])))
    (println "FAIL apply-scaling: wrong values before any measurement — fix that first")
    (System/exit 1))

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

  ;; SPACE: no short-circuit available, so judge the shape.
  (apply + (range 1000)) (apply max (range 1000))          ; warm
  (judge "apply +"
         (peak-during #(apply + (range n1)))
         (peak-during #(apply + (range (* factor n1)))))
  (judge "apply max"
         (peak-during #(apply max (range n1)))
         (peak-during #(apply max (range (* factor n1)))))
  (println "apply-scaling: passed"))

(-main)
