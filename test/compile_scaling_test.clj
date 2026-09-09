;; Compiling a namespace must cost time LINEAR in its source, and a quoted form
;; must not cost dramatically more than the construction it is.
;;
;; Nothing measured either until v0.8.6, and both were broken at once.
;;
;; SHAPE. Chez's compile is quadratic in the size of one lexical scope, and jolt
;; hands it a def's whole constant pool as one wrapping let*. That is still true
;; and is jolt-wt6v: this arm measures ~4.3 where linear is 4.0, and the residue
;; is real rather than noise. What the ceiling pins is that it does not get
;; WORSE — it is a complexity guard, not a claim that the complexity is linear.
;;
;; Keying the pool by form identity (what Compiler.registerConstant does with its
;; IdentityHashMap) cut the CONSTANT and not the class: clojure.test/is names the
;; tested form five times, splicing the SAME object into each, and the pool kept a
;; separate construction per mention, so one deftest holding 800 (is …) emitted
;; 6410 bindings of which 812 were distinct. Halving the pool quarters a quadratic
;; term, which is most of malli.core-test going 154s -> 16.9s against the JVM's
;; 1.3s — but this ratio reads the same before and after, which is exactly why the
;; overhead half below exists.
;;
;; OVERHEAD. A per-quoted-form cost regression is invisible to the shape half —
;; it is linear, just linear and slow — and that is exactly what shipped once:
;; embed-plan probed the inspector inside a guard for every quoted form, and
;; sa-procedure-info raises on anything that is not a procedure, so an ordinary
;; quoted list paid for an exception. Compiling 500 forms holding five quoted
;; forms each went 0.61s to 10.41s and `make test` stayed green. Measured on that
;; binary this ratio is 35.4; healthy it is 1.15.
;;
;; Both assertions are ratios taken inside ONE process, microseconds apart, so
;; neither depends on how fast the machine is and neither can drift against a
;; recorded constant. (Gate timing lesson: an absolute ms ceiling and a cross-run
;; ratio both flake on CI; a property measured within one run does not.)

(ns compile-scaling-test
  (:require [clojure.string :as str]
            [clojure.test]))

(defn- body
  "A fn literal whose body is n independent statements built by f."
  [n f]
  (str "(clojure.core/fn [] " (str/join " " (map f (range n))) ")"))

(defn- timed [src]
  (let [t (System/nanoTime)]
    (load-string src)
    (/ (- (System/nanoTime) t) 1e6)))

;; Interference can only ever make a run SLOWER, so the minimum of a few is the
;; robust estimator; a single sample per arm is the most flake-prone shape there
;; is. Same reasoning as read_scaling_test.
(def ^:private samples 3)
(def ^:private tries 3)

(defn- best-of [k f] (reduce min (repeatedly k f)))

;; --- shape -----------------------------------------------------------------
;; Both arms sit in the same regime, and small: CI runs the suite as
;; `make -j$(nproc) test`, so a gate that hogs a core for seconds starves the
;; other timing gates beside it. 50 -> 200 measures ~110ms and ~555ms.
(def ^:private n1 50)
(def ^:private factor 4)
;; Linear measures 4.0, quadratic 16. Measured 4.3-4.4 at this sizing on both
;; sides of the pool change, so the line goes at 7.0: well clear of a loaded
;; machine, and less than half way to quadratic.
(def ^:private max-shape 7.0)
(def ^:private clear-shape 12.0)

(defn- is-forms [n] (body n (fn [i] (str "(clojure.test/is (= " i " " i "))"))))

(defn- shape-ratio []
  (let [a (is-forms n1)
        b (is-forms (* n1 factor))]
    (/ (best-of samples #(timed b)) (best-of samples #(timed a)))))

;; --- per-quoted-form overhead ----------------------------------------------
;; Same statement count, same shape, one arm quoting and one constructing. A
;; quoted form IS a construction, so the honest ratio is near 1.
(def ^:private n-quoted 300)
;; Measured 1.15 here and 1.17 before the pool change; 35.4 on the binary that
;; regressed it. 4.0 leaves 3.5x headroom and is nowhere near the failure.
(def ^:private max-quoted 4.0)
(def ^:private clear-quoted 8.0)

(defn- quoted-ratio []
  (let [q (body n-quoted (fn [i] (str "(quote (= " i " " i "))")))
        p (body n-quoted (fn [i] (str "(clojure.core/list " i " " i ")")))]
    (/ (best-of samples #(timed q)) (best-of samples #(timed p)))))

;; A ratio over the ceiling is re-measured before failing, which costs no POWER:
;; a real regression is over it on every attempt and still fails deterministically,
;; while a one-off interference episode passes on retry.
(defn- check [label f max-ratio clear]
  (loop [n tries seen []]
    (let [r (f)]
      (cond
        (<= r max-ratio) (do (println (format "  %-22s %.2f  (ceiling %.1f)" label r max-ratio))
                             true)
        (>= r clear) (do (println (format "  %-22s %.2f  FAIL — over %.1f, not ambiguous"
                                          label r clear))
                         false)
        (= n 1) (do (println (format "  %-22s %.2f  FAIL — over %.1f on %d attempts %s"
                                     label r max-ratio tries (pr-str (conj seen r))))
                    false)
        :else (recur (dec n) (conj seen r))))))

(defn -main [& _]
  (println "compile-scaling:")
  (let [ok (reduce (fn [acc [label f mx cl]] (and (check label f mx cl) acc))
                   true
                   [["shape 1x->4x" shape-ratio max-shape clear-shape]
                    ["quoted/plain" quoted-ratio max-quoted clear-quoted]])]
    (println (if ok "compile-scaling: passed" "compile-scaling: FAILED"))
    (System/exit (if ok 0 1))))

(-main)
