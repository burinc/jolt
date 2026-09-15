;; cst-format — the SOURCE-FORMATTER shape: parse text into a CST of small
;; fixed-key maps, then walk the flattened node vector mutating per-node
;; bookkeeping and accumulating output text. Lifted from
;; standard-clojure-style (the Clojure port of standard-clojure-style-js), whose
;; PERFORMANCE.md measures the same twelve files against the upstream JavaScript
;; implementation on V8 — so this row has a non-JVM reference too, and the
;; numbers say jolt is ~40x V8 on it warm.
;;
;; Every axis here is one a formatter, linter, reader or template engine hits,
;; and none of the existing rows covers the combination:
;;
;;   parse phase  — one 10-key map allocated PER TOKEN (`make-node`), combinator
;;                  parsers reached through `(:parse p)` on a map, `.charAt` per
;;                  position, and `^`-anchored `re-find` over a chunk cut out
;;                  with `subs`. That `subs` is the shape that matters: a parser
;;                  that cannot match a regex AT an index copies the rest of the
;;                  input to match one token, and `substring` is ~3.7x a
;;                  `string-copy!` of the same span in Chez, so the copy is
;;                  neither free nor optimal. `collections` and `literals` build
;;                  maps but never at one-per-input-token rates.
;;
;;   format phase — every node wrapped in an atom, `swap! node assoc` adding
;;                  ~8 more keys as the walk learns each node's column and line,
;;                  a paren stack of those atoms, and the output built by
;;                  `(swap! out-txt str …)` per line. V8 makes the last one O(1)
;;                  with cons-strings; a copying `str` makes it quadratic in the
;;                  output, which is exactly the kind of cost no correctness gate
;;                  can see.
;;
;; The payload is generated rather than embedded so the row scales with its
;; argument and the file stays readable; `verify` pins the parse and the format
;; so neither phase can be optimized away or silently break.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh cst-format 6
(ns cst-format
  (:require [clojure.string :as str]))

;; -----------------------------------------------------------------------------
;; Payload: Clojure-shaped source text, ~7.7 KB per unit.

(def ^:private unit-forms
  ["(ns example.core.unit%d\n  (:require [clojure.string :as str]\n            [clojure.set :as set]))"
   "(def ^:private lookup-%d\n  {:alpha 1, :beta 2, :gamma 3, :delta \"four\", :epsilon [5 6 7]})"
   "(defn transform-%d\n  \"Doc string for the transform.\"\n  [{:keys [a b c] :or {c 3}} xs]\n  (->> xs\n       (map (fn [x] (+ x a b c)))\n       (filter odd?)\n       (reduce + 0)))"
   ";; a comment line about entry %d\n(defrecord Point%d [x y]\n  Object\n  (toString [_] (str \"<\" x \",\" y \">\")))"
   "(defn scan-%d [^String s]\n  (loop [i 0 acc 0]\n    (if (< i (.length s))\n      (recur (inc i) (+ acc (int (.charAt s i))))\n      acc)))"
   "(let [m {:k %d :v \"string with (parens) and [brackets]\"}]\n  (case (:k m)\n    0 :zero\n    1 :one\n    :many))"])

(defn- build-payload [units]
  (str/join "\n\n"
            (mapcat (fn [i] (map (fn [f] (str/replace f "%d" (str i))) unit-forms))
                    (range units))))

;; -----------------------------------------------------------------------------
;; Node: the fixed-key map every parser result is, one per token.

(def ^:private id-counter (atom 0))

(defn- make-node [children end-idx nm start-idx text]
  {:id (swap! id-counter inc)
   :startIdx start-idx
   :endIdx end-idx
   :name nm
   :text text
   :children children
   :_origColIdx -1
   :_printedColIdx -1
   :_printedLineIdx -1
   :_wasSlurpedUp false})

(defn- append-children [acc node]
  (cond
    (and (string? (:name node)) (not= (:name node) "")) (conj acc node)
    (vector? (:children node)) (reduce append-children acc (:children node))
    :else acc))

;; -----------------------------------------------------------------------------
;; Parsers: maps carrying a :parse closure, reached by keyword lookup — the
;; combinator shape, not a `case` over a tag.

(declare parser-of)

(defn- p-char [nm ^String c]
  (let [target (.charAt c 0)]
    {:name nm
     :parse (fn [^String txt pos]
              (when (and (< pos (.length txt)) (= (.charAt txt pos) target))
                (make-node nil (inc pos) nm pos c)))}))

(defn- p-not-char [nm ^String c]
  (let [target (.charAt c 0)]
    {:name nm
     :parse (fn [^String txt pos]
              (when (and (< pos (.length txt)) (not= (.charAt txt pos) target))
                (make-node nil (inc pos) nm pos (subs txt pos (inc pos)))))}))

;; The chunked regex: `re-find` has no "match at index", so matching one token
;; means cutting a window out of the input first. 2048 is the port's window.
(def ^:private chunk-len 2048)

(defn- p-regex [nm re]
  {:name nm
   :parse (fn [^String txt pos]
            (let [txt-len (.length txt)]
              (when (< pos txt-len)
                (let [remaining (- txt-len pos)
                      sub (if (<= remaining chunk-len)
                            (subs txt pos)
                            (subs txt pos (+ pos chunk-len)))
                      m (re-find re sub)]
                  (when m
                    (let [^String s (if (vector? m) (first m) m)]
                      (make-node nil (+ pos (.length s)) nm pos s)))))))})

(defn- p-seq [nm parser-refs]
  {:name nm
   :parse (fn [txt pos]
            (loop [idx 0 children [] end-idx pos]
              (if (< idx (count parser-refs))
                (let [node ((:parse (parser-of (nth parser-refs idx))) txt end-idx)]
                  (when node
                    (recur (inc idx) (append-children children node) (:endIdx node))))
                (make-node children end-idx nm pos nil))))})

(defn- p-choice [parser-refs]
  {:parse (fn [txt pos]
            (loop [idx 0]
              (when (< idx (count parser-refs))
                (if-let [node ((:parse (parser-of (nth parser-refs idx))) txt pos)]
                  node
                  (recur (inc idx))))))})

(defn- p-repeat [nm parser-ref]
  {:parse (fn [txt pos]
            (let [p (parser-of parser-ref)]
              (loop [end-idx pos children []]
                (if-let [node ((:parse p) txt end-idx)]
                  (recur (:endIdx node) (append-children children node))
                  (make-node children end-idx
                             (when (and (string? nm) (> end-idx pos)) nm)
                             pos nil)))))})

(defn- p-optional [parser-ref]
  {:parse (fn [txt pos]
            (let [node ((:parse (parser-of parser-ref)) txt pos)]
              (if (and node (string? (:text node)) (not= (:text node) ""))
                node
                (make-node nil pos nil pos nil))))})

(def ^:private registry (atom {}))

(defn- parser-of [p]
  (if (map? p) p (get @registry p)))

(defn- register! [k p] (swap! registry assoc k p) p)

(def ^:private ws-chars " ,\n\r\t\f")
(def ^:private ws-set (set ws-chars))

(defn- init-parsers! []
  (reset! registry {})
  (register! "token" (p-regex "token" (re-pattern (str "^[^()\\[\\]{}\";" ws-chars "][^()\\[\\]{}\";" ws-chars "]*"))))
  (register! "ws" (p-regex "whitespace" (re-pattern (str "^[" ws-chars "]+"))))
  (register! "comment" (p-regex "comment" #"^;[^\n]*"))
  (register! "string" (p-seq "string" [(p-char ".open" "\"")
                                       (p-optional (p-regex ".body" #"^([^\"\\]+|\\.)+"))
                                       (p-optional (p-char ".close" "\""))]))
  (register! "parens" (p-seq "parens" [(p-char ".open" "(")
                                       (p-repeat ".body" (p-choice ["_gap" "_form" (p-not-char "error" ")")]))
                                       (p-optional (p-char ".close" ")"))]))
  (register! "brackets" (p-seq "brackets" [(p-char ".open" "[")
                                           (p-repeat ".body" (p-choice ["_gap" "_form" (p-not-char "error" "]")]))
                                           (p-optional (p-char ".close" "]"))]))
  (register! "braces" (p-seq "braces" [(p-char ".open" "{")
                                       (p-repeat ".body" (p-choice ["_gap" "_form" (p-not-char "error" "}")]))
                                       (p-optional (p-char ".close" "}"))]))
  (register! "_gap" {:parse (fn [^String txt pos]
                              (when (< pos (.length txt))
                                (let [ch (.charAt txt pos)]
                                  (cond
                                    (contains? ws-set ch) ((:parse (parser-of "ws")) txt pos)
                                    (= ch \;) ((:parse (parser-of "comment")) txt pos)
                                    :else nil))))})
  (register! "_form" {:parse (fn [^String txt pos]
                               (when (< pos (.length txt))
                                 (let [ch (.charAt txt pos)]
                                   (cond
                                     (= ch \() ((:parse (parser-of "parens")) txt pos)
                                     (= ch \[) ((:parse (parser-of "brackets")) txt pos)
                                     (= ch \{) ((:parse (parser-of "braces")) txt pos)
                                     (= ch \") ((:parse (parser-of "string")) txt pos)
                                     :else ((:parse (parser-of "token")) txt pos)))))})
  (register! "source" (p-repeat "source" (p-choice ["_gap" "_form"])))
  nil)

(defn parse [^String txt]
  ((:parse (parser-of "source")) txt 0))

;; -----------------------------------------------------------------------------
;; Flatten: depth-first into one vector, the array the formatter indexes.

(defn flatten-tree [node]
  (persistent!
   (letfn [(walk [acc nd]
             (let [acc (conj! acc nd)]
               (if (vector? (:children nd))
                 (reduce walk acc (:children nd))
                 acc)))]
     (walk (transient []) node))))

;; -----------------------------------------------------------------------------
;; Format: the mutating walk. Nodes become atoms so the paren stack and the
;; lookahead can write back to them; output accrues by string concatenation.

(defn- newline-node? [m]
  (and (= (:name m) "whitespace") (string? (:text m)) (str/includes? (:text m) "\n")))

(defn- count-newlines [^String s]
  (loop [i 0 n 0]
    (if (< i (.length s))
      (recur (inc i) (if (= (.charAt s i) \newline) (inc n) n))
      n)))

(defn- chars-after-last-newline [^String s]
  (loop [i (dec (.length s))]
    (cond (< i 0) (.length s)
          (= (.charAt s i) \newline) (- (.length s) (inc i))
          :else (recur (dec i)))))

(defn- opener? [m] (and (= (:name m) ".open") (string? (:text m))))
(defn- closer? [m] (and (= (:name m) ".close") (string? (:text m))))

(defn format-nodes [nodes-arr]
  (let [num-nodes (count nodes-arr)
        nodes (mapv atom nodes-arr)
        out-txt (atom "")
        line-txt (atom "")
        line-idx (atom 0)
        col-idx (atom 0)
        depth (atom 0)
        paren-stack (atom [])
        printed (atom 0)]
    (loop [i 0]
      (when (< i num-nodes)
        (let [node (nth nodes i)
              m @node]
          (cond
            (opener? m)
            (do (swap! depth inc)
                (when-let [top (peek @paren-stack)]
                  (swap! top update :_openingLineNodes conj node))
                (swap! node assoc
                       :_colIdx @col-idx
                       :_parenOpenerLineIdx @line-idx
                       :_openingLineNodes []
                       :_rule3Active false
                       :_rule3NumSpaces 0
                       :_rule3SearchComplete false)
                (swap! paren-stack conj node))

            (closer? m)
            (do (swap! depth dec)
                (swap! paren-stack pop))

            :else
            (when-let [top (peek @paren-stack)]
              (when (and (string? (:text m)) (= @line-idx (:_parenOpenerLineIdx @top)))
                (swap! node assoc :_colIdx @col-idx :_lineIdx @line-idx)
                (swap! top update :_openingLineNodes conj node))))

          (let [txt (:text m)]
            (when (and (string? txt) (not= txt ""))
              (if (newline-node? m)
                ;; line break: flush the line into the output and start a new one.
                ;; `str` on the accumulator is the quadratic shape V8 avoids with
                ;; cons-strings — kept exactly as the formatter spells it.
                (do (swap! out-txt str @line-txt txt)
                    (reset! line-txt "")
                    (swap! line-idx + (count-newlines txt))
                    (reset! col-idx (chars-after-last-newline txt)))
                (do (swap! node assoc :_printedColIdx (count @line-txt) :_printedLineIdx @line-idx)
                    (swap! line-txt str txt)
                    (swap! col-idx + (count txt))
                    (swap! printed inc)))))
          (recur (inc i)))))
    (when (not= @line-txt "")
      (swap! out-txt str @line-txt))
    {:out (str/trim @out-txt) :printed @printed :nodes num-nodes}))

;; -----------------------------------------------------------------------------

(defn run [payload]
  (let [tree (parse payload)
        nodes (flatten-tree tree)]
    (format-nodes nodes)))

(defn- verify [payload]
  (let [tree (parse payload)
        nodes (flatten-tree tree)
        r (format-nodes nodes)]
    ;; the parse must cover the whole input and the format must reproduce it
    (when (not= (:endIdx tree) (count payload))
      (println "PARSE SHORT:" (:endIdx tree) "of" (count payload)))
    (when (not= (str/trim payload) (:out r))
      (println "FORMAT MISMATCH: out" (count (:out r)) "in" (count (str/trim payload))))
    [(count nodes) (:printed r)]))

(defn -main [& args]
  (let [units (if (seq args) (Integer/parseInt (first args)) 6)
        payload (build-payload units)]
    (init-parsers!)
    (println "payload chars:" (count payload) "verify:" (verify payload))
    (dotimes [_ 2] (run payload))                        ; warmup
    (let [runs 3
          ;; the phase split, for reading by hand — `mean:` below is the row
          tp (let [t0 (System/nanoTime)] (parse payload) (/ (- (System/nanoTime) t0) 1000000.0))
          nodes (flatten-tree (parse payload))
          tf (let [t0 (System/nanoTime)] (format-nodes nodes) (/ (- (System/nanoTime) t0) 1000000.0))
          ts (mapv (fn [_]
                     (let [t0 (System/nanoTime)
                           r (run payload)
                           ms (/ (- (System/nanoTime) t0) 1000000.0)]
                       (when (zero? (:printed r)) (println "unexpected empty format"))
                       ms))
                   (range runs))
          mean (/ (reduce + ts) runs)]
      (println "phases: parse" (/ (Math/round (* tp 10.0)) 10.0)
               "ms  format" (/ (Math/round (* tf 10.0)) 10.0) "ms")
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) ts))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
