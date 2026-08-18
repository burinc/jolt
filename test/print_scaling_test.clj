;; Rendering a collection must cost time LINEAR in the printed length.
;;
;; jolt-str-join / jolt-str-join-comma (host/chez/rt.ss) were right-folds of
;; string-append, so element i's copy cost was the length of the entire
;; remaining suffix — O(n*L) over the whole render, on EVERY collection print:
;; both printers (str-style and pr-readable), record printing, sorted-coll
;; printing. The fix joins through a string output port, one pass. The same
;; right-fold lived in host/gambit/rt-core.ss, and sorted-map rendering
;; (host-table.ss) carried its own accumulator-first string-append.
;;
;; Same judgment as read_scaling_test.clj: the SHAPE, in one run — quadrupling
;; the element count must not quadruple the per-element cost. Linear lands near
;; 4, the old right-fold near 16; both arms run best-of-3 and only the
;; in-process ratio is judged. Correctness (exact rendering) is asserted on
;; small values here and pinned broadly by the corpus; this file is about cost.

(ns print-scaling-test)

(defn- render [n]
  (let [v (vec (range n))
        s (pr-str v)]
    ;; the count comes back with the render so verifying costs no extra pass
    (count s)))

;; a record's #ns.Name{...} form joins its entries the same one-pass way; the
;; extension map is unbounded (any non-field key assoc'd on lands there), so a
;; per-entry append to a growing accumulator (jrec-field-pr, records.ss) would
;; be quadratic in the entry count.
(defrecord ExtRec [])

(defn- render-rec [n]
  (let [r (reduce (fn [r i] (assoc r (keyword (str "k" i)) i)) (->ExtRec) (range n))]
    (count (pr-str r))))

;; nanoTime, not currentTimeMillis. The 1x arm here renders in 2-3ms, so
;; millisecond resolution quantized it to ±33% — and that error lands straight in
;; the ratio, since t1 is the denominator.
(defn- timed [f]
  (let [t (System/nanoTime)
        v (f)]
    [(/ (- (System/nanoTime) t) 1e6) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; n1 sized so the REGRESSED right-fold (~7.5e8 char copies in the 4x arm)
;; still finishes and fails rather than hanging the gate.
(def ^:private n1 4000)
(def ^:private factor 4)
(def ^:private max-ratio 8.0)
;; best-of over this many runs per arm. best-of is the right estimator for "what
;; does this cost when nothing interferes": interference (a GC episode, the
;; scheduler) can only ever make a run slower, never faster.
;;
;; 5 rather than 3, because the arms here are SMALL — the 1x record arm renders in
;; ~7ms — and this gate cannot be resized the way read_scaling_test.clj was.
;; Per-element cost grows with n across this whole range (record: 1.77us at 4000,
;; 4.10 at 16000, 5.44 at 32000, 5.93 at 64000; vector: 0.61, 0.63, 1.56, 1.84),
;; so there is no flat regime to move onto — 16000 -> 64000 measures 9.05 on the
;; vector arm and would fail outright. These sizes are the best window available.
;;
;; And not more than 5: sampling is not free, and CI runs the suite as
;; `make -j$(nproc) test`, where a gate that holds a core longer starves the other
;; timing gates beside it — an earlier revision of these two files did exactly that
;; to the complexity gate, whose ceiling sits at 2.0 over 3ms measurements. Five is
;; enough for the property: on an idle machine the reported ratios sit at 4.07-4.15
;; and 4.39-4.42 across runs, and the retry below covers the rare episode that
;; sampling cannot.
(def ^:private samples 5)
;; ...and if the ratio still comes out over the ceiling, re-measure the whole
;; thing this many times before failing.
;;
;; Both arms of the record check allocate ~n intermediate records (each assoc
;; conses a new one), so a GC episode can span every run of a best-of and inflate
;; the arm as a whole — which best-of alone cannot filter. The record ratio
;; measures ~4.6 against a ceiling of 8.0, so there is only ~1.7x of headroom for
;; that to eat, and it did: this gate failed twice during one afternoon's work,
;; once on a tree with no local changes at all (ratio 8.71).
;;
;; Retrying costs nothing in POWER, which is the point. A genuine quadratic
;; regression measures ~16 — it is over the ceiling on every attempt and still
;; fails deterministically. Only a one-off interference episode passes on retry,
;; and that is exactly the case that was never a real failure.
(def ^:private tries 3)

;; Measure t1/t4/ratio once.
(defn- ratio-once [f1 f4]
  (let [t1 (max 0.001 (best-of samples f1))
        t4 (best-of samples f4)]
    [t1 t4 (/ t4 t1)]))

;; Judge one arm: report every attempt, pass on the first ratio within the
;; ceiling, fail only when all of them exceed it.
(defn- judge [label n1' n4' f1 f4 fail-msg]
  (loop [attempt 1 seen []]
    (let [[t1 t4 ratio] (ratio-once f1 f4)
          seen (conj seen ratio)]
      (println (format "print-scaling: %s%d %.2fms, %d %.2fms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                       label n1' t1 n4' t4 ratio
                       (double factor) (double (* factor factor)) max-ratio))
      (cond
        (<= ratio max-ratio) (println "print-scaling: passed")
        (< attempt tries)
        (do (println (format "print-scaling: ratio %.2f over ceiling %.1f — re-measuring (attempt %d of %d)"
                             ratio max-ratio (inc attempt) tries))
            (recur (inc attempt) seen))
        :else
        (do (println (str "FAIL print-scaling: " fail-msg))
            (println (str "  ratios over " tries " attempts: "
                          (clojure.string/join ", " (map #(format "%.2f" %) seen))))
            (System/exit 1))))))

(defn -main [& _]
  ;; exact small renders: separators, map commas, sorted-map arm
  (when-not (and (= (pr-str [1 2 3]) "[1 2 3]")
                 (= (pr-str {:a 1}) "{:a 1}")
                 (= (pr-str (sorted-map :a 1 :b 2)) "{:a 1, :b 2}")
                 (= (pr-str (sorted-set 3 1 2)) "#{1 2 3}")
                 (= (str [1 2 3]) "[1 2 3]"))
    (println "FAIL print-scaling: wrong rendering on small values")
    (System/exit 1))
  (let [c1 (render n1)
        c4 (render (* factor n1))]
    ;; a ratio over the wrong output would be meaningless
    (when-not (and (> c1 (* 4 n1)) (> c4 (* 4 factor n1)))
      (println (str "FAIL print-scaling: rendered lengths look wrong — " c1 " and " c4))
      (System/exit 1))
    (judge "" n1 (* factor n1) #(render n1) #(render (* factor n1))
           (str "rendering scaled worse than linearly in the element count. "
                "jolt-str-join is re-copying the joined suffix per element "
                "(host/chez/rt.ss, host/gambit/rt-core.ss, or sorted-map-render in host-table.ss).")))
  ;; the record arm, judged the same way
  (when-not (= (pr-str (assoc (->ExtRec) :b 2 :a 1)) "#print-scaling-test.ExtRec{:b 2, :a 1}")
    (println (str "FAIL print-scaling: wrong record rendering — " (pr-str (assoc (->ExtRec) :b 2 :a 1))))
    (System/exit 1))
  (judge "record " n1 (* factor n1) #(render-rec n1) #(render-rec (* factor n1))
         (str "record rendering scaled worse than linearly in the entry count. "
              "jrec-field-pr is appending each entry to a growing accumulator (host/chez/records.ss).")))

(-main)
