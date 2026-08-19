;; (into vec vec) and (subvec v s e) must cost time LOGARITHMIC in the vector
;; size, not linear: both are backed by the RRB tree (pvec-catvec / pvec-slice
;; in host/chez/collections.ss), and this guards that the CORE FNS still reach
;; that backing — the raw ops have their own gate (test/chez/rrb-scaling-test.ss),
;; which cannot notice core falling back to an element-by-element rebuild.
;;
;; What this asserts is the SHAPE, measured in one run: quadrupling the vectors
;; must not quadruple the per-call cost. The structural op holds the ratio near
;; 1; a linear rebuild lands near 4. Nothing here is an absolute time, so it
;; does not care how fast the machine is — the two numbers come from the same
;; process, microseconds apart, and only their ratio is judged.
;;
;; The behavioural half — that the results are element- and metadata-correct —
;; is in unit/corpus rows and test/chez/rrb-property-test.ss. This file is only
;; about cost.

(ns vec-scaling-test)

(defn- vec-of [n] (into [] (range n)))

(defn- timed-best
  "Best of 5 batches of `reps` calls to f, in ms — the minimum is the least
  noise-contaminated sample."
  [reps f]
  (reduce min
          (for [_ (range 5)]
            (let [t (System/currentTimeMillis)]
              (dotimes [_ reps] (f))
              (- (System/currentTimeMillis) t)))))

(def ^:private n1 50000)
(def ^:private factor 4)
;; enough calls that the structural op's batch sits above the ms-timer floor —
;; at 1ms both sides clamp and the ratio measures nothing. 15000, not 5000:
;; the catvec arms measured 6ms/4ms, the same sub-noise-floor size that made
;; three sibling gates flake a hair over their ceilings on shared runners
;; (allocating arms + one GC pause moves a small ratio). ~18ms/12ms now.
(def ^:private reps 15000)

;; Logarithmic measures ~1 and a linear rebuild ~4, so the line goes between
;; them, with room for a loaded machine.
(def ^:private max-ratio 2.5)

(defn- judge [label t1 t4]
  (let [t1 (max 1 t1)
        ratio (double (/ t4 t1))]
    (println (format "vec-scaling %s: %dms vs %dms (x%d size) ratio %.2f (ceiling %.1f)"
                     label t1 t4 factor ratio max-ratio))
    (when (> ratio max-ratio)
      (println (str "FAIL vec-scaling: " label " scales with the vector size — "
                    "core is rebuilding element by element instead of using the "
                    "RRB op (jolt-into's catvec path in host/chez/seq.ss, or "
                    "subvec's jolt.host/slice call in clojure/core/00-kernel.clj)."))
      (System/exit 1))))

(defn -main [& _]
  (let [a1 (vec-of n1) b1 (vec-of n1)
        a4 (vec-of (* factor n1)) b4 (vec-of (* factor n1))]
    ;; sanity before cost: the fast paths must produce the right values
    (when-not (and (= (count (into a1 b1)) (* 2 n1))
                   (= (nth (into a1 b1) n1) 0)
                   (= (subvec a1 10 12) [10 11])
                   (= (count (subvec a4 0 (count a4))) (* factor n1)))
      (println "FAIL vec-scaling: wrong values before any timing — fix that first")
      (System/exit 1))
    (into a1 b1) (into a4 b4)          ; warm both sizes
    (judge "into vec+vec"
           (timed-best reps #(into a1 b1))
           (timed-best reps #(into a4 b4)))
    (let [s1 (quot n1 3) e1 (* 2 s1)
          s4 (quot (* factor n1) 3) e4 (* 2 s4)]
      (subvec a1 s1 e1) (subvec a4 s4 e4)
      (judge "subvec"
             (timed-best reps #(subvec a1 s1 e1))
             (timed-best reps #(subvec a4 s4 e4))))
    (println "vec-scaling: passed")))

(-main)
