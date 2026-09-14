;; host-io — READING THROUGH THE java.io SHIM, which is where a Clojure program
;; meets a file: a form read off a reader, a chunked char[] drain, and the
;; String/char[] conversions that sit on both ends of a decode loop.
;;
;; This is the regime `string-ops` and `char-scan` miss. Those measure operations
;; on a string that already exists; here the string does not exist yet, and the
;; cost is in how the characters are ASKED FOR. Three shapes were pathological,
;; and all three were invisible to a benchmark that starts from a string:
;;
;;   - `(read rdr)` over a stream-backed PushbackReader drained the reader one
;;     character at a time through record-method-dispatch — a method-table lookup
;;     by hashing the jhost tag, then a handler lookup by hashing the method NAME,
;;     per character — consing each one onto a list to reverse at the end.
;;     Reading one form out of each of 332 files measured 3909 ms against
;;     babashka's 57 ms (69x), while the SAME parse from a string took jolt 52 ms
;;     against bb's 67. The buffering was never the difference; the dispatch was.
;;   - `.read(char[])` — the documented way to stream a large input without
;;     materializing it — ran the same per-character loop plus a `ja-set!` per
;;     character (a checked record accessor, a bounds test that re-reads the
;;     backing length, and a cond over the backing type). 8.7 MB cost ~31 ms per
;;     MB against bb's ~1 ms, and buffer size changed nothing because the cost
;;     was per character. It was SLOWER than slurping the whole file, so the
;;     memory-bounded read cost time instead of saving it.
;;   - `.toCharArray` built a cons per character and then walked the list again;
;;     `(String. char[])` did the mirror image. A chunked decode loop pays both,
;;     once per chunk.
;;
;; The `-from-string` rows are the control: the same parse with the characters
;; already in hand. They were always fast, which is what localized the problem to
;; the reader path rather than the reader or the parser.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh host-io 200
(ns host-io
  (:require [clojure.string :as str]))

;; A source file's worth of forms — the shape ns-scanning tools actually read.
(def ^:private one-form
  "(defn some-function-name\n  \"A docstring that is long enough to matter when it is walked one character at a time.\"\n  [a b c]\n  (let [x (+ a b) y (* x c)]\n    {:sum x :product y :label \"result\"}))\n")

(def ^:private source-text
  (str "(ns bench.sample\n  \"Namespace docstring.\"\n  (:require [clojure.string :as str]))\n"
       (apply str (repeat 40 one-form))))

;; ~1 MB of line-oriented text, the chunked-read workload
(def ^:private payload
  (let [line (str "{\"role\":\"assistant\",\"content\":\"" (apply str (repeat 40 "abcdefghij")) "\"}")]
    (str/join "\n" (repeat 2400 line))))

(def ^:private tmp-path
  (str (System/getProperty "java.io.tmpdir") "/jolt-bench-host-io.txt"))

(defn- pushback-over-stream [path]
  (java.io.PushbackReader.
   (java.io.InputStreamReader.
    (java.io.FileInputStream. path))))

;; --- a form read off a STREAM-backed reader (the 69x shape) -------------------
(defn read-form-from-stream [path]
  (with-open [r (pushback-over-stream path)]
    (let [form (read r)]
      (if (and (list? form) (= 'ns (first form))) 1 0))))

;; --- the control: the same parse with the text already in hand ----------------
(defn read-form-from-string [text]
  (let [form (read-string text)]
    (if (and (list? form) (= 'ns (first form))) 1 0)))

;; --- chunked char[] drain (the 30x shape) -------------------------------------
(defn drain-chunked [path ^long bufsize]
  (with-open [r (java.io.InputStreamReader. (java.io.FileInputStream. path) "UTF-8")]
    (let [cbuf (char-array bufsize)]
      (loop [total 0]
        (let [n (.read r cbuf)]
          (if (neg? n) total (recur (+ total n))))))))

;; --- MANY SMALL slurps ---------------------------------------------------------
;; The arm every other row here misses. Each one above uses a large payload, and
;; a block-reading drain that sizes its scratch to the block rather than to the
;; input looks perfect on all of them while making small reads WORSE than the
;; per-character loop it replaced: a 64 KB buffer allocated to hold 200 bytes,
;; once per file. That shipped, and only a suite that reads many small files
;; caught it (a 900 ms group of namespaces went to 1.8 s). Small-and-many is a
;; different regime from large-and-once, so it gets its own row.
(defn slurp-many-small [paths]
  (reduce (fn [acc p] (+ acc (count (slurp p)))) 0 paths))

;; --- String <-> char[] round trip (the two 20x shapes) ------------------------
;; Both ends of this are now one block move: a char array is backed by a Chez
;; STRING, so .toCharArray is a string copy and (String. ca) is a substring of
;; the backing. They used to be a cons per character and a second walk over the
;; list, in both directions.
(defn char-array-round-trip [^String s]
  (let [ca (.toCharArray s)]
    (+ (count (String. ca))
       (count (String. ca 0 (quot (alength ca) 2))))))

;; --- ALLOCATING a char array --------------------------------------------------
;; Its own row because it is the one cost here with no decode, no copy and no
;; traversal in it — just the backing. A boxed vector of n characters is n
;; POINTERS the collector traces on every major GC; a string of n characters is
;; a flat untraced block half the size. Nothing else in this file would notice
;; the difference, because every other row is dominated by what it then does
;; with the array.
(defn alloc-char-arrays [^long n ^long size]
  (loop [i 0 acc 0]
    (if (< i n) (recur (inc i) (unchecked-add acc (alength (char-array size)))) acc)))

;; --- slurp, by PATH -----------------------------------------------------------
;; A different code path from every reader row above: slurping a path decodes
;; the file through the port's own transcoder rather than going through the
;; char-reader drain. It was reading with get-string-all, which grows its result
;; as it goes; the file's byte length bounds the character count, so the buffer
;; can be allocated once.
(defn slurp-by-path [path] (count (slurp path)))

(defn run [iters src-path small-paths]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add (read-form-from-stream src-path)
                              (read-form-from-string source-text))
               (unchecked-add
                (unchecked-add (drain-chunked tmp-path 65536)
                               (unchecked-add (alloc-char-arrays 4 65536)
                                              (slurp-by-path tmp-path)))
                (unchecked-add (char-array-round-trip payload)
                               (slurp-many-small small-paths))))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 200)
        src-path (str (System/getProperty "java.io.tmpdir") "/jolt-bench-host-io-src.clj")
        ;; 24 files of a few hundred bytes: a config, a fixture, a small source
        small-paths (mapv (fn [i] (str (System/getProperty "java.io.tmpdir")
                                       "/jolt-bench-host-io-small-" i ".txt"))
                          (range 24))]
    (spit tmp-path payload)
    (spit src-path source-text)
    (doseq [p small-paths] (spit p one-form))
    (dotimes [_ 2] (run (max 1 (quot iters 4)) src-path small-paths))   ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run iters src-path small-paths)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))
    (.delete (java.io.File. tmp-path))
    (.delete (java.io.File. src-path))
    (doseq [p small-paths] (.delete (java.io.File. p)))))
