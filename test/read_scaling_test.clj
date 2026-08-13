;; Reading a source file form by form off a host reader must cost time LINEAR in
;; the source, not quadratic.
;;
;; It was quadratic until v0.7.7: every (read rdr) drained the whole remaining
;; reader, parsed one form, and pushed the tail back, so a caller walking a file
;; paid a full copy of the rest of it per FORM. Reading clojure/core.clj (263KB,
;; 697 forms) took 37s against the JVM's 0.06s. Nothing noticed for a long time
;; because the loop was unreachable — (read opts stream) did not exist, so it
;; threw on the first call instead of running.
;;
;; What this asserts is the SHAPE, measured in one run: quadrupling the input
;; must not quadruple the cost per form. A ratio near 4 is linear; a quadratic
;; implementation lands near 16. Nothing here is an absolute time, so it does not
;; care how fast the machine is, and it does not compare against a calibration
;; constant that could drift — the two numbers come from the same process,
;; microseconds apart, and only their ratio is judged. (Gate timing lesson: an
;; absolute ns ceiling and a cross-run ratio both flake on CI; a property
;; measured within one run does not.)
;;
;; The behavioural half of this — that a read advances the reader correctly, that
;; the unconsumed tail survives, that each form carries its own line — is in the
;; corpus under "interop / read over a host reader". This file is only about cost.

(ns read-scaling-test)

(def ^:private form-text "(def some-name-here [1 2 3 :a :b \"str\"])\n")

(defn- source [n] (apply str (repeat n form-text)))

(defn- read-all
  "Read every form off a PushbackReader over s, the way a file walker does."
  [s]
  (let [r (java.io.PushbackReader. (java.io.StringReader. s))]
    (count (take-while #(not= :eof %) (repeatedly #(read {:eof :eof} r))))))

(defn- timed
  "[elapsed-ms result] — the count comes back with the time so verifying what was
  read costs no extra pass."
  [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

;; n1 is big enough that the measurement sits well above timer noise (~40ms here)
;; and small enough that a REGRESSED implementation still finishes and fails
;; rather than hanging — a gate that hangs reports nothing.
(def ^:private n1 8000)
(def ^:private factor 4)

;; Linear measures ~4.0 and quadratic ~16, so the line goes between them. 8 is
;; twice the linear cost — room for a slow or loaded machine, while still an
;; enormous distance from quadratic.
(def ^:private max-ratio 8.0)

(defn -main [& _]
  (let [s1 (source n1)
        s4 (source (* factor n1))
        _ (read-all s1)                 ; warm: keep one-time costs out of the ratio
        [t1 c1] (timed #(read-all s1))
        [t4 c4] (timed #(read-all s4))]
    ;; a ratio over the wrong number of forms would be meaningless, so check the
    ;; reads did what they claim before judging what they cost
    (when (or (not= c1 n1) (not= c4 (* factor n1)))
      (println (str "FAIL read-scaling: read the wrong number of forms — "
                    c1 " (want " n1 ") and " c4 " (want " (* factor n1) ")"))
      (System/exit 1))
    (let [t1 (max 1 t1)
          ratio (double (/ t4 t1))]
      (println (format "read-scaling: %d forms %dms, %d forms %dms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                       n1 t1 (* factor n1) t4 ratio
                       (double factor) (double (* factor factor)) max-ratio))
      (if (> ratio max-ratio)
        (do (println (str "FAIL read-scaling: reading scaled worse than linearly in the source size. "
                          "A read off a host reader is walking the whole remaining input again per form "
                          "(host-reader-read-form / host-reader-string-cursor in host/chez/java/io.ss, "
                          "or the position cursor in rdr-line-col-at no longer being reused)."))
            (System/exit 1))
        (println "read-scaling: passed")))))

(-main)
