;; The fast paths that keep reading and string-scanning off the slow route, each
;; gated as a RATIO against a reference the same run measures on the same machine.
;;
;; These are constant-factor gates, and that is why they are not written like
;; read_scaling_test.clj or io_scaling_test.clj. Every regression below is
;; perfectly LINEAR — it just has a terrible constant — so a 1x-vs-4x scaling
;; ratio sees nothing at all. What separates fast from slow here is that the same
;; work is available two ways, and the slow way is 5-70x the fast one. Measuring
;; both arms in one process and judging their ratio needs no absolute budget, no
;; baseline file, and no babashka in CI.
;;
;; What each arm gates (all figures x86_64, jolt vs babashka 1.12, 2026-09-13):
;;
;;   reader-vs-string   (read <stream-backed PushbackReader>) used to drain the
;;                      reader one character at a time through
;;                      record-method-dispatch — a method-table lookup by hashing
;;                      the jhost tag and a handler lookup by hashing the method
;;                      NAME, per character. 332 files cost 3909 ms against bb's
;;                      57; the same parse from a string cost 52. The reference
;;                      arm IS that string parse, so the gate asks: does reading
;;                      from a stream still cost about what reading from a string
;;                      costs?
;;
;;   chunked-vs-slurp   .read(char[]) is the memory-bounded way to read a large
;;                      file, and it was SLOWER than reading the whole thing
;;                      (2.7x), because the fill loop set one array element at a
;;                      time through the checked generic setter. The gate asks
;;                      the question that made it absurd: is the bounded read at
;;                      least not slower than the unbounded one?
;;
;;   literal-split      #"\n" is a literal, and running an irregex search per
;;   literal-replace    line to find one character cost ~10x. The reference arm
;;   split-lines        is the SAME call with a literal string separator, which
;;                      always took the index scan. If the literal recognizer
;;                      stops recognising, the regex arm falls back to the engine
;;                      and the ratio jumps.
;;
;;   small-file-drain   the regression that ACTUALLY SHIPPED during this work.
;;                      A block-reading drain that sizes its scratch to the BLOCK
;;                      rather than to the input reads large files beautifully and
;;                      allocates 64 KB to hold 200 bytes — once per file. Every
;;                      other arm here uses a large payload and saw nothing; a
;;                      suite that reads many small files went from 900 ms to
;;                      1.8 s. The reference arm reads the SAME FILES, the same
;;                      number of times, by PATH — which takes the bytevector
;;                      route and never touches the drain. Holding everything but
;;                      the drain constant is what makes the ratio sharp.
;;
;;   trim-no-copy       clojure.string/trim was (trimr (triml s)), and triml
;;                      copied the whole string even with nothing to trim, so
;;                      trimming an already-trimmed string allocated it twice.
;;                      This one IS a scaling test, and deliberately: trimming a
;;                      string that needs no trimming must cost the same whether
;;                      the string is short or long. A copying trim is linear in
;;                      the length; a scanning one is not.
;;
;; Only the ratios are judged, never the absolute times — a slow shared runner
;; moves both arms together. Sampling follows io_scaling_test.clj: best-of-N
;; (minimum, not mean — interference only ever adds time), a ceiling, a
;; clear-regression threshold that fails on the spot, and one re-measure in the
;; band between them so a single scheduler blip cannot fail the build. A real
;; regression measures far above the ceiling on every attempt, so re-measuring
;; costs no power.

(ns fastpath-ratio-test
  (:require [clojure.string :as str]))

(def ^:private samples 3)

;; nanoTime, not currentTimeMillis: these ratios are judged to two decimals and
;; the fast arms run in single-digit milliseconds, which a millisecond clock
;; quantizes badly — and the fast arm is the denominator.
(defn- timed [f]
  (let [t (System/nanoTime)
        v (f)]
    [(/ (- (System/nanoTime) t) 1e6) v]))

(defn- best-of [k f]
  (reduce min (map first (repeatedly k #(timed f)))))

(def ^:private failures (atom []))

(defn- judge!
  "Measure SLOW-ARM against FAST-ARM and record a failure when the ratio exceeds
   CEILING. Re-measures once in the band below CLEAR, as io_scaling_test.clj does."
  [label fast-arm slow-arm ceiling clear]
  (let [ratio (fn []
                (let [f (best-of samples fast-arm)
                      s (best-of samples slow-arm)]
                  ;; a floor on the denominator: an arm that measures as ~0 would
                  ;; make any numerator look infinite
                  (/ s (max f 0.05))))
        r1 (ratio)
        r (if (and (> r1 ceiling) (< r1 clear))
            (do (println (format "  %s: %.2f — in the re-measure band, sampling again" label r1))
                (ratio))
            r1)]
    (println (format "  %-18s ratio %6.2f  (ceiling %.1f)%s"
                     label r ceiling (if (> r ceiling) "  <-- REGRESSED" "")))
    (when (> r ceiling)
      (swap! failures conj (format "%s: ratio %.2f exceeds ceiling %.1f" label r ceiling)))
    r))

;; --- fixtures ---------------------------------------------------------------

(def ^:private one-form
  "(defn some-function-name\n  \"A docstring long enough that walking it one character at a time shows up.\"\n  [a b c]\n  (let [x (+ a b)] {:sum x :label \"result\"}))\n")

(def ^:private source-text
  (str "(ns bench.sample\n  \"Namespace docstring.\"\n  (:require [clojure.string :as str]))\n"
       (apply str (repeat 60 one-form))))

(def ^:private line
  (str "{\"role\":\"assistant\",\"content\":\"" (apply str (repeat 40 "abcdefghij")) "\"}"))

;; ~1.7 MB / 4000 lines: big enough that a per-character path cannot hide in
;; noise, small enough that a regressed run still finishes and fails fast.
(def ^:private payload (str/join "\n" (repeat 4000 line)))
(def ^:private crlf-payload (str/join "\r\n" (repeat 4000 line)))

(def ^:private tmpdir (System/getProperty "java.io.tmpdir"))
(def ^:private src-path (str tmpdir "/jolt-fastpath-src.clj"))
(def ^:private data-path (str tmpdir "/jolt-fastpath-data.txt"))

(defn- read-form-from-stream []
  (with-open [r (java.io.PushbackReader.
                 (java.io.InputStreamReader.
                  (java.io.FileInputStream. src-path)))]
    (first (read r))))

(defn- read-form-from-string []
  (first (read-string (slurp src-path))))

(defn- drain-chunked []
  (with-open [r (java.io.InputStreamReader. (java.io.FileInputStream. data-path) "UTF-8")]
    (let [cbuf (char-array 65536)]
      (loop [total 0]
        (let [n (.read r cbuf)]
          (if (neg? n) total (recur (+ total n))))))))

(defn- slurp-whole [] (count (slurp data-path)))

;; N small files whose bytes sum to one big file, for the per-file overhead arm
(def ^:private small-count 48)
(def ^:private small-paths
  (mapv (fn [i] (str tmpdir "/jolt-fastpath-small-" i ".txt")) (range small-count)))
(def ^:private small-text (apply str (repeat 6 one-form)))

;; Through an InputStreamReader, NOT (slurp path): slurping a PATH takes the
;; bytevector route and never reaches the char-reader drain this arm exists to
;; guard. Reading a reader object is what io/reader, line-seq and any code
;; holding a Reader actually do.
(defn- drain-reader-at [p]
  (with-open [r (java.io.InputStreamReader. (java.io.FileInputStream. p) "UTF-8")]
    (count (slurp r))))
(defn- drain-many-small []
  (reduce (fn [a p] (+ a (drain-reader-at p))) 0 small-paths))
;; the reference: the SAME files, the SAME number of opens, the same bytes —
;; read by path, which takes the bytevector route and never touches the drain.
;; Holding everything but the drain constant is what makes the ratio sharp:
;; a per-file allocation in the drain shows up here and nowhere else.
(defn- slurp-many-small-by-path []
  (reduce (fn [a p] (+ a (count (slurp p)))) 0 small-paths))

;; a clean string at two lengths, for the trim scaling arm
(def ^:private clean-short (apply str (repeat 64 "x")))
(def ^:private clean-long (apply str (repeat (* 64 64) "x")))

(defn -main [& _]
  (spit src-path source-text)
  (spit data-path payload)
  (doseq [p small-paths] (spit p small-text))
  (println "fastpath ratio gate")

  ;; Reading a form off a stream must cost about what reading it off a string
  ;; costs. Was ~70x when the drain went per-character through method dispatch.
  (judge! "reader-vs-string" read-form-from-string read-form-from-stream 8.0 15.0)

  ;; The memory-bounded read must not be slower than reading the whole file.
  ;; Was 2.7x when the fill loop went through the checked generic array setter.
  (judge! "chunked-vs-slurp" slurp-whole drain-chunked 2.0 4.0)

  ;; A literal pattern must not reach the regex engine. The reference arm is the
  ;; same split with a literal STRING separator, which never did.
  (judge! "literal-split"
          #(count (str/split payload "\n"))
          #(count (str/split payload #"\n"))
          3.0 6.0)

  ;; split-lines is #"\r?\n" — not a literal, so it needs its own recognition.
  (judge! "split-lines"
          #(count (str/split crlf-payload "\r\n"))
          #(count (str/split-lines crlf-payload))
          3.0 6.0)

  ;; A literal replace pattern with a literal replacement, against the same
  ;; function's literal-string arm.
  (judge! "literal-replace"
          #(count (str/replace payload "abc" "xyz"))
          #(count (str/replace payload #"abc" "xyz"))
          3.0 6.0)

  ;; Reading N small files must not cost wildly more than reading their bytes
  ;; from one file. Guards per-file overhead — a scratch sized to the block
  ;; rather than the input, an eager buffer, a per-open allocation.
  (judge! "small-file-drain" slurp-many-small-by-path drain-many-small 4.0 9.0)

  ;; Trimming a string that needs no trimming must not copy it: 64x the length
  ;; must not cost 64x the time. A copying trim is linear here.
  (judge! "trim-no-copy"
          #(dotimes [_ 200] (str/trim clean-short))
          #(dotimes [_ 200] (str/trim clean-long))
          4.0 10.0)

  (.delete (java.io.File. src-path))
  (.delete (java.io.File. data-path))
  (doseq [p small-paths] (.delete (java.io.File. p)))

  (if (seq @failures)
    (do (println "\nFAIL — fast paths regressed:")
        (doseq [f @failures] (println "  -" f))
        (println "\nEach ratio compares two ways of doing the same work in one process.")
        (println "A ratio this high means the fast path stopped being taken; see the")
        (println "header of test/fastpath_ratio_test.clj for what each arm gates.")
        (System/exit 1))
    (println "\nok — every fast path still taken")))

(apply -main *command-line-args*)
