;; string-scan — clojure.string OVER A LARGE PAYLOAD: splitting, replacing and
;; trimming text the size a real document or session log reaches, rather than the
;; short-string dispatch `string-ops` measures.
;;
;; The axis is whether a pattern that is REALLY A LITERAL reaches the regex
;; engine. A great many regex calls are not regex calls: #"\n" is the commonest
;; separator in line-oriented code, and running an irregex search per line to
;; find one character measured ~10x babashka (1086 ms vs 106 ms for 20k lines).
;; #"abc" as a replace pattern was the same story — 1661 ms against bb's 174,
;; where the literal arm of the very same function did the identical work in 171.
;; Recognising the literal routes both to a non-allocating index scan.
;;
;; `split-lines` is the one line-shaped pattern that is NOT a literal (#"\r?\n"),
;; so it needs its own recognition; it is here to keep that arm honest.
;;
;; The `-engine` rows are the control: patterns that genuinely need the engine (a
;; character class, a quantifier, a group reference in the replacement). They must
;; NOT regress, and they are what a too-eager literal recognizer would break — a
;; recognizer that accepted #"[0-9]" or a replacement containing $1 would be
;; wrong, not fast.
;;
;; `trim` is the allocation shape rather than the engine shape: clojure.string's
;; trim was (trimr (triml s)), and triml copied the whole string even when there
;; was nothing to trim, so trimming an untrimmed string allocated it twice —
;; ~15x babashka on short strings, all of it in copies the scan did not need.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh string-scan 40
(ns string-scan
  (:require [clojure.string :as str]))

(def ^:private line
  (str "{\"role\":\"assistant\",\"content\":\"" (apply str (repeat 40 "abcdefghij")) "\"}"))

;; ~870 KB, 2000 lines
(def ^:private payload (str/join "\n" (repeat 2000 line)))
(def ^:private crlf-payload (str/join "\r\n" (repeat 2000 line)))

;; short strings, where per-call overhead rather than the scan decides
(def ^:private words (mapv (fn [i] (str "  word" i "  ")) (range 32)))
(def ^:private clean-words (mapv (fn [i] (str "word" i)) (range 32)))

(defn split-literal [s]     (count (str/split s #"\n")))
(defn split-literal-str [s] (count (str/split s #"\}\{")))
(defn split-lines* [s]      (count (str/split-lines s)))
(defn split-engine [s]      (count (str/split s #"[\n\r]+")))

(defn replace-literal [s]   (count (str/replace s #"abc" "xyz")))
(defn replace-engine [s]    (count (str/replace s #"[0-9]+" "#")))
(defn replace-groups [s]    (count (str/replace s #"\"(\w+)\":" "<$1>")))

(defn trim-dirty [] (reduce (fn [a w] (+ a (count (str/trim w)))) 0 words))
(defn trim-clean [] (reduce (fn [a w] (+ a (count (str/trim w)))) 0 clean-words))

(defn seq-matches [s] (count (re-seq #"\"role\":\"(\w+)\"" s)))

(defn run [iters]
  (loop [i 0 acc 0]
    (if (< i iters)
      (recur (inc i)
             (unchecked-add
              acc
              (unchecked-add
               (unchecked-add
                (unchecked-add (split-literal payload) (split-lines* crlf-payload))
                (unchecked-add (split-literal-str payload) (split-engine crlf-payload)))
               (unchecked-add
                (unchecked-add (replace-literal payload) (replace-engine payload))
                (unchecked-add
                 (unchecked-add (replace-groups payload) (seq-matches payload))
                 (unchecked-add (trim-dirty) (trim-clean)))))))
      acc)))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 40)]
    (dotimes [_ 2] (run (max 1 (quot iters 4))))            ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run iters)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))))
