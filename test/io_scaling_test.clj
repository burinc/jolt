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

(defn- timed [f]
  (let [t (System/currentTimeMillis)
        v (f)]
    [(- (System/currentTimeMillis) t) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

;; 8000, not 2000: the small arm measured 2-3ms on a millisecond clock, so
;; quantization plus one scheduler blip on a shared runner read 8.33 against
;; the 8.0 ceiling (locally the drain sits ~4.5; the quadratic bug this gates
;; sat ~16). At 8000 the small arm is ~10ms and the ratio stops moving with
;; the clock's granularity. A regressed quadratic drain at 32000 items still
;; finishes in seconds, so the gate keeps failing fast when it should.
(def ^:private n1 8000)
(def ^:private factor 4)
(def ^:private max-ratio 8.0)

(defn- judge [label t1 t4]
  (let [t1 (max 1 t1)
        ratio (double (/ t4 t1))]
    (println (format "io-scaling %s: %d items %dms, %d items %dms, ratio %.2f (linear ~%.1f, quadratic ~%.1f, ceiling %.1f)"
                     label n1 t1 (* factor n1) t4 ratio
                     (double factor) (double (* factor factor)) max-ratio))
    (when (> ratio max-ratio)
      (println (str "FAIL io-scaling: " label " drain scaled worse than linearly in the input. "
                    "The IReader in jolt-core/clojure/core/50-io.clj is re-copying or re-parsing "
                    "the remaining buffer per item instead of advancing a cursor."))
      (System/exit 1))))

(defn -main [& _]
  (let [ls1 (lines-src n1) ls4 (lines-src (* factor n1))
        fs1 (forms-src n1) fs4 (forms-src (* factor n1))]
    ;; the drains must have read what they claim before their cost is judged;
    ;; also pin the read/read-line interleave (read consumes exactly its form)
    (when-not (and (= (drain-lines ls1) n1) (= (drain-lines ls4) (* factor n1))
                   (= (drain-forms fs1) n1) (= (drain-forms fs4) (* factor n1))
                   (= (with-in-str "(+ 1 2) tail-text\nnext"
                        [(read) (read-line) (read-line)])
                      ['(+ 1 2) " tail-text" "next"]))
      (println "FAIL io-scaling: wrong lines/forms through the reader")
      (System/exit 1))
    (judge "read-line" (best-of 3 #(drain-lines ls1)) (best-of 3 #(drain-lines ls4)))
    (judge "read" (best-of 3 #(drain-forms fs1)) (best-of 3 #(drain-forms fs4)))
    (println "io-scaling: passed")))

(-main)
