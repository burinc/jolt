;; Writing to a piped stream must cost O(1) per chunk, not O(chunks-queued).
;;
;; The pipe buffer (jpipe in host/chez/java/io-streams.ss) was a plain list and
;; every write re-copied it ((append chunks (list chunk))), so piping N chunks
;; cost O(N^2) cons work plus N^2 GC pressure — all under the pipe mutex, which
;; is the buffer every ring.util.io/piped-input-stream response body flows
;; through. The fix keeps a front/rear list pair (the standard amortized-O(1)
;; queue) and a running byte count so .available is O(1) too.
;;
;; Like read_scaling_test.clj this asserts the SHAPE in one run: quadrupling the
;; chunk count must not quadruple the per-chunk cost. Both arms are measured
;; best-of-3 in this process and only their ratio is judged — linear lands near
;; 4, the old quadratic near 16, and nothing here is an absolute time. The
;; write-then-drain order is deterministic (the pipe queue is unbounded), so no
;; second thread is involved. Behavior — byte order through the queue, available,
;; end-of-stream — is pinned in test/chez/unit.edn suite "piped-streams"; this
;; file is only about cost.

(ns pipe-scaling-test)

(def ^:private chunk-bytes 64)

(defn- pump
  "Write n 64-byte chunks, close the write end, drain. [total-bytes first-byte]"
  [n]
  (let [in (java.io.PipedInputStream.)
        out (java.io.PipedOutputStream. in)
        chunk (byte-array chunk-bytes (byte 7))
        buf (byte-array 4096)]
    (dotimes [_ n] (.write out chunk))
    (.close out)
    (loop [total 0 probe -2]
      (let [r (.read in buf)]
        (if (neg? r)
          [total probe]
          (recur (+ total r) (if (= probe -2) (aget buf 0) probe)))))))

(defn- timed [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

(defn- best-of
  "Minimum elapsed over k runs — robust to a GC pause landing in one arm."
  [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; n1 is big enough that the linear implementation still measures above timer
;; noise (~10ms of writes+reads) and small enough that the REGRESSED quadratic
;; finishes and fails rather than hanging — a gate that hangs reports nothing.
(def ^:private n1 8000)
(def ^:private factor 4)
(def ^:private max-ratio 8.0)

(defn -main [& _]
  (let [[c1 p1] (pump n1)              ; warm + verify small
        [c4 p4] (pump (* factor n1))]  ; verify big
    (when-not (and (= c1 (* n1 chunk-bytes)) (= c4 (* factor n1 chunk-bytes))
                   (= p1 7) (= p4 7))
      (println (str "FAIL pipe-scaling: wrong bytes through the pipe — got "
                    [c1 p1] " and " [c4 p4]))
      (System/exit 1))
    (let [t1 (max 1 (best-of 3 #(pump n1)))
          t4 (best-of 3 #(pump (* factor n1)))
          ratio (double (/ t4 t1))]
      (println (format "pipe-scaling: %d chunks %dms, %d chunks %dms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                       n1 t1 (* factor n1) t4 ratio
                       (double factor) (double (* factor factor)) max-ratio))
      (if (> ratio max-ratio)
        (do (println (str "FAIL pipe-scaling: piping scaled worse than linearly in the chunk count. "
                          "pipe-write! is re-copying the queued chunk list per write "
                          "(jpipe front/rear queue in host/chez/java/io-streams.ss)."))
            (System/exit 1))
        (println "pipe-scaling: passed")))))

(-main)
