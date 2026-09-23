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
;;   chars-copy         a char array's backing IS a Chez string, so .toCharArray
;;   string-from-chars  is a string copy and (String. ca) is a substring of it.
;;                      Both used to build a cons per character and then walk the
;;                      list again — 21x babashka on the chunked-read path that
;;                      feeds them. The reference arm for both is (subs s 0 n),
;;                      which copies exactly as many characters by a route that
;;                      was always a block move. If the backing goes back to a
;;                      boxed vector, both arms walk again and the ratios jump
;;                      (measured: 0.68 -> 2.47 and 1.00 -> 1.63).
;;
;;   char-alloc         the same backing, seen with no traversal in it at all.
;;                      A char array of n elements is a flat 4-byte-per-character
;;                      string the collector never traces; a boxed vector of the
;;                      same n is n POINTERS at 8 bytes that it traces on every
;;                      major GC. So allocating a char array must be FASTER than
;;                      allocating a long array of the same length — the ceiling
;;                      here is deliberately below 1.0, and a boxed char backing
;;                      brings it straight back to parity (0.49 -> 1.02).
;;
;;   substring-scan     str-index-of is the widest-reach scan in the string
;;                      layer: indexOf, contains, literal split and both literal
;;                      replaces all run it once per character. It called
;;                      char-by-char-match? at EVERY position, so the call cost
;;                      more than the comparison — testing the first character
;;                      inline took a 7.8 MB miss from 56 ms to 18 ms. The
;;                      reference arm is the SAME search with a CHAR needle,
;;                      which takes str-char-index and never had an inner call,
;;                      so it is unaffected by the regression and measures 23 ms
;;                      on both sides (0.80 -> 2.43).
;;
;;   trim-no-copy       clojure.string/trim was (trimr (triml s)), and triml
;;                      copied the whole string even with nothing to trim, so
;;                      trimming an already-trimmed string allocated it twice.
;;                      This one IS a scaling test, and deliberately: trimming a
;;                      string that needs no trimming must cost the same whether
;;                      the string is short or long. A copying trim is linear in
;;                      the length; a scanning one is not.
;;
;;   reify-instance     (instance? SomeProtocol r) on a reify walked every
;;   deftype-instance   host-shim instance-check arm (23 of them, each passing)
;;                      and then munged every declared protocol name to compare
;;                      it — ~3.5 us for a reify of six protocols against the
;;                      JVM's ~14 ns, ~500 ns for a deftype. core.logic asks it
;;                      of every var and constraint on every propagation step,
;;                      and its finite-domain solver spent 56 s seeing a trivial
;;                      contradiction. The reference arm calls a protocol method
;;                      on the same value, which never walked anything. Measured
;;                      before/after: reify 204 -> 1.38, deftype 7.75 -> 1.13.
;;
;;   instance-miss      ...and a NO walked all of them every time, then the
;;   number-miss        JVM taxonomy: 500-700 ns for (instance? IVar 5), which
;;                      core.logic asks of every term it walks. The builtin arms'
;;                      verdict per value kind is memoized now, the library arm
;;                      still asked live (31 -> 1.55, 22 -> 1.37).
;;
;;   instance-site      ...and past both memos, each (instance? T x) SITE caches
;;   instance-site-type its last type argument and receiver kind, so a repeat is
;;                      two eq?s and an epoch compare — the shape of the JVM's
;;                      inlined instanceof, where the memo path still interned the
;;                      type name and read two tables per call. Held BELOW a
;;                      protocol call: the site measures 0.32 (quoted name) and
;;                      0.42 (a deftype as T) of one; without it, 1.15-1.95.
;;
;;   reify-construct    (reify …) built a {kw fn} map and then a hashtable from it
;;                      per instance (~310 ns against the JVM's ~25). The layout is
;;                      the site's, built once; an instance is a vector of fns.
;;                      The reference constructs a deftype (8.9 -> 1.05).
;;
;;   satisfies-reify    satisfies? on a reify re-munged every declared protocol
;;                      name ahead of the match (13.5 -> 0.82).
;;
;;   record-key-get     a map keyed on a deftype that declares equals/hashCode
;;                      (core.logic's LVar) looked both methods up by NAME, in two
;;                      string-keyed tables, on every key compared. The reference
;;                      is the same lookup over identity-keyed deftypes, which
;;                      declare neither and so find nothing to call (5.46 -> 1.86).
;;
;;   top-level-fn       a fn built in a bare top-level form — every deftype and
;;                      defrecord method, every extend-type impl and defmethod —
;;                      got no constant pool, so each keyword literal in it
;;                      re-interned on every call. The reference is the same fn
;;                      built under a def, which always had one (2.38 -> 1.02).
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

;; ~1.5 MB of text for the char-array and scan arms. Large enough that a
;; per-character path cannot hide in the noise of one allocation.
(def ^:private chars-text (apply str (repeat 40000 "abcdefghijklmnopqrstuvwxyz0123456789abc")))
(def ^:private chars-len (count chars-text))
(def ^:private chars-array (.toCharArray chars-text))
;; a needle that is NOT present, so both scan arms run to the end of the string
(def ^:private absent-str "QZXW")
(def ^:private absent-char \Q)

;; dispatch fixtures: a reify and a deftype declaring several protocols, and
;; deftype map keys with and without their own equals/hashCode
(defprotocol DP1 (dp1 [x])) (defprotocol DP2 (dp2 [x])) (defprotocol DP3 (dp3 [x]))
(defprotocol DP4 (dp4 [x])) (defprotocol DP5 (dp5 [x])) (defprotocol DP6 (dp6 [x]))
(def ^:private dispatch-reify
  (reify DP1 (dp1 [_] 1) DP2 (dp2 [_] 2) DP3 (dp3 [_] 3)
         DP4 (dp4 [_] 4) DP5 (dp5 [_] 5) DP6 (dp6 [_] 6)))
(deftype DispatchT [a] DP1 (dp1 [_] a) DP2 (dp2 [_] a))
(def ^:private dispatch-t (DispatchT. 1))
(def ^:private dispatch-n 100000)
(defprotocol DP7 (dp7 [x] [x y]))
(defn- mk-reify [a] (reify DP1 (dp1 [_] a) DP2 (dp2 [_] a) DP7 (dp7 [_] a) (dp7 [_ y] y)))
(defn- mk-type [a] (DispatchT. a))
(def ^:private made-reify (mk-reify 1))
(deftype EqKey [id]
  Object
  (equals [_ o] (and (instance? EqKey o) (= id (.-id ^EqKey o))))
  (hashCode [_] (hash id)))
(deftype PlainKey [id])
(def ^:private eq-key-map (zipmap (map #(EqKey. %) (range 8)) (range)))
(def ^:private eq-probe (EqKey. 7))
(def ^:private plain-keys (mapv #(PlainKey. %) (range 8)))
(def ^:private plain-key-map (zipmap plain-keys (range)))
(def ^:private plain-probe (nth plain-keys 7))
;; one body, built under a def and in a bare top-level form
(def ^:private kw-map {:a 1 :b 2 :c 3})
(def ^:private fn-via-def (fn [m] (+ (get m :a) (get m :b) (get m :c))))
(def ^:private fn-holder (atom nil))
(reset! fn-holder (fn [m] (+ (get m :a) (get m :b) (get m :c))))
(def ^:private fn-via-top @fn-holder)

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

  ;; A char array is backed by a string, so building one from a string and
  ;; reading one back out are block moves — each must cost about what copying
  ;; the same characters with subs costs.
  (judge! "chars-copy"
          #(count (subs chars-text 0 chars-len))
          #(alength (.toCharArray chars-text))
          1.5 3.0)
  (judge! "string-from-chars"
          #(count (subs chars-text 0 chars-len))
          #(count (String. chars-array))
          1.35 2.5)

  ;; ...and allocating one must beat allocating a long array of the same length,
  ;; because its backing is half as wide and is never traced by the collector.
  (judge! "char-alloc"
          #(dotimes [_ 200] (alength (long-array 65536)))
          #(dotimes [_ 200] (alength (char-array 65536)))
          0.8 1.5)

  ;; Searching for a multi-character needle must cost about what searching for a
  ;; single CHARACTER costs — the reference arm takes str-char-index, which never
  ;; had a call per position, so it does not move when str-index-of regresses.
  (judge! "substring-scan"
          #(str/index-of chars-text absent-char)
          #(str/index-of chars-text absent-str)
          1.5 3.0)

  ;; Trimming a string that needs no trimming must not copy it: 64x the length
  ;; must not cost 64x the time. A copying trim is linear here.
  (judge! "trim-no-copy"
          #(dotimes [_ 200] (str/trim clean-short))
          #(dotimes [_ 200] (str/trim clean-long))
          4.0 10.0)

  ;; instance? on a reify or deftype that declares the protocol must cost about
  ;; what calling one of its methods costs.
  (judge! "reify-instance"
          #(dotimes [_ dispatch-n] (dp6 dispatch-reify))
          #(dotimes [_ dispatch-n] (instance? fastpath_ratio_test.DP6 dispatch-reify))
          4.0 20.0)
  (judge! "deftype-instance"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (instance? fastpath_ratio_test.DP2 dispatch-t))
          3.0 6.0)

  ;; ...and a miss, on a record and on a number, must too.
  (judge! "instance-miss"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (instance? fastpath_ratio_test.DP7 dispatch-t))
          4.0 10.0)
  (judge! "number-miss"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (instance? fastpath_ratio_test.DP7 42))
          4.0 10.0)

  ;; The site cache: cheaper than the protocol call it is measured against.
  (judge! "instance-site"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (instance? fastpath_ratio_test.DP7 dispatch-t))
          0.8 1.1)
  (judge! "instance-site-type"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (instance? DispatchT dispatch-t))
          0.8 1.1)

  ;; Building a reify must cost about what building a deftype costs.
  (judge! "reify-construct"
          #(dotimes [_ dispatch-n] (mk-type 1))
          #(dotimes [_ dispatch-n] (mk-reify 1))
          3.0 6.0)

  ;; satisfies? on a reify must cost about a protocol call.
  (judge! "satisfies-reify"
          #(dotimes [_ dispatch-n] (dp1 dispatch-t))
          #(dotimes [_ dispatch-n] (satisfies? DP2 made-reify))
          3.0 8.0)

  ;; A key with its own equals/hashCode must not cost wildly more to look up
  ;; than an identity key.
  (judge! "record-key-get"
          #(dotimes [_ 20000] (get plain-key-map plain-probe))
          #(dotimes [_ 20000] (get eq-key-map eq-probe))
          3.0 4.5)

  ;; The same fn body costs the same whether a def or a bare form built it.
  (judge! "top-level-fn"
          #(dotimes [_ dispatch-n] (fn-via-def kw-map))
          #(dotimes [_ dispatch-n] (fn-via-top kw-map))
          1.5 2.0)

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
