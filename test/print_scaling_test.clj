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

(defn- timed [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; n1 sized so the REGRESSED right-fold (~7.5e8 char copies in the 4x arm)
;; still finishes and fails rather than hanging the gate.
(def ^:private n1 4000)
(def ^:private factor 4)
(def ^:private max-ratio 8.0)

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
    (let [t1 (max 1 (best-of 3 #(render n1)))
          t4 (best-of 3 #(render (* factor n1)))
          ratio (double (/ t4 t1))]
      (println (format "print-scaling: %d elems %dms, %d elems %dms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                       n1 t1 (* factor n1) t4 ratio
                       (double factor) (double (* factor factor)) max-ratio))
      (if (> ratio max-ratio)
        (do (println (str "FAIL print-scaling: rendering scaled worse than linearly in the element count. "
                          "jolt-str-join is re-copying the joined suffix per element "
                          "(host/chez/rt.ss, host/gambit/rt-core.ss, or sorted-map-render in host-table.ss)."))
            (System/exit 1))
        (println "print-scaling: passed")))))

(-main)
