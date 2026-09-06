;; Draining a string reader — by lines or by forms — must cost time LINEAR in
;; the input, not quadratic.
;;
;; The IReader implementations in clojure.core (50-io.clj) held the UNREAD REST
;; of the input in an atom: every read-line re-copied the whole remaining
;; buffer ((subs cur (inc i))), and every read re-parsed and re-copied it
;; through __parse-next, which returned [form rest-of-string]. Draining S chars
;; over L lines/forms cost O(S*L) — (line-seq (with-in-str ...)) and read loops
;; are the standard way tests feed input. The fix keeps a [string offset]
;; cursor (str-find takes a start, __parse-next-from returns [form next-index])
;; so nothing re-copies the tail.
;;
;; Same judgment as read_scaling_test.clj: the SHAPE, in one run, best-of-3,
;; only the in-process 1x-vs-4x ratio judged — linear ~4, the old copy ~16.
;; n1 is sized so a REGRESSED implementation still finishes and fails.

(ns io-scaling-test)

(def ^:private line-text "the quick brown fox jumps over the lazy dog etc")

(defn- lines-src [n] (apply str (repeat n (str line-text "\n"))))

(defn- drain-lines [s]
  (with-in-str s
    (loop [c 0]
      (if (nil? (read-line)) c (recur (inc c))))))

(def ^:private form-text "(def some-name-here [1 2 3 :a :b \"str\"])\n")

(defn- forms-src [n] (apply str (repeat n form-text)))

(defn- drain-forms [s]
  (with-in-str s
    (loop [c 0]
      (if (= :eof (read {:eof :eof} *in*)) c (recur (inc c))))))

;; nanoTime, not currentTimeMillis: the ratio is judged to two decimals and a
;; millisecond clock quantizes the small arm, which is the one a coarse tick
;; moves furthest.
(defn- timed [f]
  (let [t (System/nanoTime)
        v (f)]
    [(/ (- (System/nanoTime) t) 1e6) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; 8000, not 2000: at 2000 the drain is a couple of milliseconds and a single
;; scheduler blip on a shared runner is most of the measurement (locally the
;; drain sits ~4.5 against a linear 4.0; the quadratic bug this gates sat ~16).
;; A regressed quadratic drain at 32000 items still finishes in seconds, so the
;; gate keeps failing fast when it should.
(def ^:private n1 8000)
(def ^:private factor 4)
(def ^:private samples 3)
(def ^:private max-ratio 8.0)

;; A ratio at or above this is not ambiguous — it is most of the way to
;; quadratic — so it fails on the spot with no re-measuring.
(def ^:private clear-regression 12.0)

;; ...and between the ceiling and that, re-measure before failing, exactly as
;; read_scaling_test.clj does. This costs no POWER: a quadratic drain measures
;; ~16 and is over the ceiling on every attempt, so it still fails
;; deterministically. What it absorbs is interference, which this gate is
;; especially exposed to: CI runs the suite as `make -j$(nproc) test`, the two
;; arms are measured one after the other rather than side by side, and the 4x
;; arm — being four times as long — is the more likely of the two to overlap a
;; busy stretch. That is a bias toward a HIGH ratio, not just noise around it.
;; It read 8.22 on a run whose sibling workflow measured 2.74 on the same
;; commit (8000 items 55ms, 32000 items 452ms, against 95ms and 260ms).
(def ^:private tries 3)

(defn- report [label t1 t4 ratio]
  (println (format "io-scaling %s: %d items %.2fms, %d items %.2fms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                   label n1 t1 (* factor n1) t4 ratio
                   (double factor) (double (* factor factor)) max-ratio)))

(defn- fail! [label]
  (println (str "FAIL io-scaling: " label " drain scaled worse than linearly in the input. "
                "The IReader in jolt-core/clojure/core/50-io.clj is re-copying or re-parsing "
                "the remaining buffer per item instead of advancing a cursor."))
  (System/exit 1))

;; w1/w4 are the verification runs' own times — already paid, so screening with
;; them fails an unambiguous regression after one run per arm.
(defn- judge [label w1 w4 f1 f4]
  (let [screen (/ w4 (max 0.001 w1))]
    (when (>= screen clear-regression)
      (report label w1 w4 screen)
      (fail! label)))
  (loop [attempt 1 seen []]
    (let [t1 (max 0.001 (best-of samples f1))
          t4 (best-of samples f4)
          ratio (/ t4 t1)
          seen (conj seen ratio)]
      (report label t1 t4 ratio)
      (cond
        (<= ratio max-ratio) nil
        (>= ratio clear-regression) (fail! label)
        (< attempt tries)
        (do (println (format "io-scaling %s: ratio %.2f over ceiling %.1f — re-measuring (attempt %d of %d)"
                             label ratio max-ratio (inc attempt) tries))
            (recur (inc attempt) seen))
        :else
        (do (println (str "  ratios over " tries " attempts: "
                          (clojure.string/join ", " (map #(format "%.2f" %) seen))))
            (fail! label))))))

(defn -main [& _]
  (let [ls1 (lines-src n1) ls4 (lines-src (* factor n1))
        fs1 (forms-src n1) fs4 (forms-src (* factor n1))
        ;; the drains must have read what they claim before their cost is judged;
        ;; also pin the read/read-line interleave (read consumes exactly its form).
        ;; Timed, so these double as the warm-up and the screen below.
        [lw1 lc1] (timed #(drain-lines ls1))
        [lw4 lc4] (timed #(drain-lines ls4))
        [fw1 fc1] (timed #(drain-forms fs1))
        [fw4 fc4] (timed #(drain-forms fs4))]
    (when-not (and (= lc1 n1) (= lc4 (* factor n1))
                   (= fc1 n1) (= fc4 (* factor n1))
                   (= (with-in-str "(+ 1 2) tail-text\nnext"
                        [(read) (read-line) (read-line)])
                      ['(+ 1 2) " tail-text" "next"]))
      (println "FAIL io-scaling: wrong lines/forms through the reader")
      (System/exit 1))
    (judge "read-line" lw1 lw4 #(drain-lines ls1) #(drain-lines ls4))
    (judge "read" fw1 fw4 #(drain-forms fs1) #(drain-forms fs4))
    (println "io-scaling: passed")))

(-main)
