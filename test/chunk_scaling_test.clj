;; chunk-append must cost O(1) amortized per item, not O(items-buffered).
;;
;; The chunk-builder API (clojure.core/chunk-buffer + chunk-append + chunk,
;; jolt-chunkbuf in host/chez/java/natives-array.ss) buffered items as a plain
;; list re-copied per append ((append items (list x))), so filling a buffer of n
;; cost O(n^2) — and the cap argument was silently ignored. The fix stores a
;; vector + count (growing when appends outrun the declared cap), which also
;; makes cap mean something.
;;
;; Same judgment as read_scaling_test.clj: the SHAPE, in one run. Quadrupling
;; the buffer size must not quadruple the per-item cost — linear lands near 4,
;; quadratic near 16, only the in-process ratio is judged. Both arms run
;; best-of-3 because the linear times are small (~ms) and a stray GC pause in
;; one run must not decide the gate. Sealed-chunk contents are verified per
;; build here, and the JVM-portable behavior rows live in the corpus
;; ("chunk-builder API"); cap overflow (a jolt superset — the JVM throws) is
;; pinned in test/chez/unit.edn.

(ns chunk-scaling-test)

(defn- build
  "Fill a chunk-buffer of capacity n, seal it, spot-check the contents."
  [n]
  (let [b (chunk-buffer n)]
    (dotimes [i n] (chunk-append b i))
    (let [c (chunk b)]
      (and (= (count c) n) (= (nth c 0) 0) (= (nth c (dec n)) (dec n))))))

(defn- timed [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; Small enough that the REGRESSED quadratic (~128M conses in the 4x arm)
;; finishes and fails rather than hanging. The linear implementation runs both
;; arms near the timer floor, where the (max 1) floor makes the ratio land well
;; under the ceiling.
(def ^:private n1 4000)
(def ^:private factor 4)
(def ^:private max-ratio 8.0)

(defn -main [& _]
  (when-not (and (build n1) (build (* factor n1)))
    (println "FAIL chunk-scaling: sealed chunk has wrong count or contents")
    (System/exit 1))
  (let [t1 (max 1 (best-of 3 #(build n1)))
        t4 (best-of 3 #(build (* factor n1)))
        ratio (double (/ t4 t1))]
    (println (format "chunk-scaling: %d appends %dms, %d appends %dms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                     n1 t1 (* factor n1) t4 ratio
                     (double factor) (double (* factor factor)) max-ratio))
    (if (> ratio max-ratio)
      (do (println (str "FAIL chunk-scaling: chunk-append scaled worse than linearly in the buffer size. "
                        "na-chunk-append is re-copying the buffered items per append "
                        "(jolt-chunkbuf in host/chez/java/natives-array.ss)."))
          (System/exit 1))
      (println "chunk-scaling: passed"))))

(-main)
