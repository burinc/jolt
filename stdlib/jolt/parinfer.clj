;; Ported from Parinfer 3.13.1 (parinfer.js), https://github.com/parinfer/parinfer.js
;;
;; Copyright (c) 2015 Shaun Williams and contributors
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy of
;; this software and associated documentation files (the "Software"), to deal in
;; the Software without restriction, including without limitation the rights to
;; use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
;; the Software, and to permit persons to whom the Software is furnished to do so,
;; subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
;; FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
;; COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
;; IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
;;
;; The port follows parinfer.js function for function, so its doc/code.md reads
;; against this file too. Two representation choices carry the JS semantics:
;; the running result is one volatile map, and each open-paren record is its own
;; volatile, because the algorithm mutates an opener (indentDelta, argX,
;; maxChildIndent, closer) while it sits on the paren stack, a paren trail and
;; the returned paren tree at once. UINT_NULL stays a -999 sentinel rather than
;; nil: the JS compares it numerically in places (cursor holding, clamping), and
;; a nil there would throw where the original quietly compares false.
(ns jolt.parinfer
  "Parinfer: infer close-parens from indentation (indent mode), indentation
  from close-parens (paren mode), or a blend that follows the edit being made
  (smart mode). Each mode takes the full text and an options map and returns a
  result map; nothing is retained between calls.

  Options (all optional):
    :cursor-x :cursor-line            the cursor, zero-based
    :prev-cursor-x :prev-cursor-line  the cursor before the edit (smart mode)
    :selection-start-line             a selection's first line; turns smart off
    :changes  [{:line-no :x :old-text :new-text}]  the edit that produced text
    :force-balance :partial-result :return-parens   booleans
    :comment-chars :open-paren-chars :close-paren-chars  a char or a sequence

  Result: {:text :success :cursor-x :cursor-line :tab-stops :paren-trails
           :parens :error} where :error is {:name :message :line-no :x :extra}
  and :name one of :quote-danger :eol-backslash :unclosed-quote
  :unclosed-paren :unmatched-close-paren :unmatched-open-paren
  :leading-close-paren."
  (:require [clojure.string :as str]))

;; -----------------------------------------------------------------------------
;; Constants

(def ^:private U -999) ; UINT_NULL

(def ^:private match-paren
  {"{" "}" "}" "{" "[" "]" "]" "[" "(" ")" ")" "("})

;; -----------------------------------------------------------------------------
;; Language helpers

(defn- split-lines* [s] (vec (str/split s #"\r?\n" -1)))

(defn- char-at
  "The one-char string at i, or \"\" past either end (JS s[i] is undefined
  there, which no char test matches)."
  [s i]
  (if (and (<= 0 i) (< i (count s))) (subs s i (inc i)) ""))

(defn- stack-peek
  "parinfer.js peek: the element idx-from-back from the top, nil past the bottom."
  [v idx-from-back]
  (let [i (- (count v) 1 idx-from-back)]
    (when (>= i 0) (nth v i))))

(defn- slice [v from to]
  (let [n (count v)]
    (subvec v (min from n) (min to n))))

(defn- replace-within-string [orig start end replace]
  (let [n (count orig)]
    (str (subs orig 0 (min start n)) replace (subs orig (min end n)))))

(defn- line-ending [text]
  ;; any CR means CRLF after every line
  (if (str/includes? text "\r") "\r\n" "\n"))

;; -----------------------------------------------------------------------------
;; Options

(defn- transform-change [change]
  (when change
    (let [new-lines (split-lines* (:new-text change))
          old-lines (split-lines* (:old-text change))
          x (:x change)
          old-end-x (+ (if (= 1 (count old-lines)) x 0) (count (peek old-lines)))
          new-end-x (+ (if (= 1 (count new-lines)) x 0) (count (peek new-lines)))
          new-end-line-no (+ (:line-no change) (count new-lines) -1)]
      {:x x
       :line-no (:line-no change)
       :old-text (:old-text change)
       :new-text (:new-text change)
       :old-end-x old-end-x
       :new-end-x new-end-x
       :new-end-line-no new-end-line-no
       :lookup-line-no new-end-line-no
       :lookup-x new-end-x})))

(defn- transform-changes [changes]
  (when (seq changes)
    (reduce (fn [lines change]
              (let [c (transform-change change)]
                (assoc-in lines [(:lookup-line-no c) (:lookup-x c)] c)))
            {} changes)))

(defn- one-char? [c]
  (or (char? c) (and (string? c) (= 1 (count c)))))

(defn- char-set
  "A char, a one-char string, or a sequence of either, as a set of one-char
  strings; anything else leaves the default."
  [v default]
  (cond
    (one-char? v) #{(str v)}
    (and (sequential? v) (every? one-char? v)) (set (map str v))
    :else default))

;; -----------------------------------------------------------------------------
;; Result structure

(defn- initial-paren-trail []
  {:line-no U       ; line number of the last parsed paren trail
   :start-x U       ; x of the first paren in the range
   :end-x U         ; x after the last paren in the range
   :openers []      ; the open-paren of each close-paren in the range
   :clamped {:start-x U :end-x U :openers []}}) ; before the cursor clamped it

(defn- initial-result [text options mode smart]
  (let [int-opt (fn [k] (let [v (get options k)] (when (integer? v) v)))
        bool-opt (fn [k] (let [v (get options k)] (when (boolean? v) v)))
        cursor-x (int-opt :cursor-x)
        cursor-line (int-opt :cursor-line)]
    (volatile!
      {:mode mode                       ; :indent or :paren
       :smart (boolean smart)
       :orig-text text
       :orig-cursor-x (or cursor-x U)
       :orig-cursor-line (or cursor-line U)
       :input-lines (split-lines* text)
       :input-line-no -1
       :input-x -1
       :lines []                        ; output lines
       :line-no -1
       :ch ""                           ; the char being processed ("" or "  " once replaced)
       :x 0
       :indent-x U
       :paren-stack []                  ; open-paren records, innermost last
       :tab-stops []
       :paren-trail (initial-paren-trail)
       :paren-trails []
       :return-parens (boolean (bool-opt :return-parens))
       :parens []
       :cursor-x (or cursor-x U)
       :cursor-line (or cursor-line U)
       :prev-cursor-x (or (int-opt :prev-cursor-x) U)
       :prev-cursor-line (or (int-opt :prev-cursor-line) U)
       :comment-chars (char-set (:comment-chars options) #{";"})
       :open-paren-chars (char-set (:open-paren-chars options) #{"(" "[" "{"})
       :close-paren-chars (char-set (:close-paren-chars options) #{")" "]" "}"})
       :selection-start-line (or (int-opt :selection-start-line) U)
       :changes (when (sequential? (:changes options)) (transform-changes (:changes options)))
       :in-code? true
       :escaping? false
       :escaped? false
       :in-str? false
       :in-comment? false
       :comment-x U
       :quote-danger? false
       :tracking-indent? false
       :skip-char? false
       :success? false
       :partial-result? (boolean (bool-opt :partial-result))
       :force-balance? (boolean (bool-opt :force-balance))
       :max-indent U
       :indent-delta 0
       :tracking-arg-tab-stop nil       ; nil, :space or :arg
       :error nil
       :error-pos-cache {}})))

;; -----------------------------------------------------------------------------
;; Errors

(def ^:private error-messages
  {:quote-danger "Quotes must balanced inside comment blocks."
   :eol-backslash "Line cannot end in a hanging backslash."
   :unclosed-quote "String is missing a closing quote."
   :unclosed-paren "Unclosed open-paren."
   :unmatched-close-paren "Unmatched close-paren."
   :unmatched-open-paren "Unmatched open-paren."
   :leading-close-paren "Line cannot lead with a close-paren."})

(defn- cache-error-pos [r ename]
  (let [res @r
        e {:line-no (:line-no res) :x (:x res)
           :input-line-no (:input-line-no res) :input-x (:input-x res)}]
    (vswap! r assoc-in [:error-pos-cache ename] e)
    e))

(defn- create-error [r ename]
  (let [res @r
        cache (get-in res [:error-pos-cache ename])
        [kl kx] (if (:partial-result? res) [:line-no :x] [:input-line-no :input-x])
        err {:name ename
             :message (error-messages ename)
             :line-no (if cache (kl cache) (kl res))
             :x (if cache (kx cache) (kx res))}
        opener (some-> (stack-peek (:paren-stack res) 0) deref)]
    (case ename
      :unmatched-close-paren
      ;; where the open-paren it should have matched is
      (let [cache2 (get-in res [:error-pos-cache :unmatched-open-paren])]
        (if (or cache2 opener)
          (assoc err :extra {:name :unmatched-open-paren
                             :line-no (if cache2 (kl cache2) (kl opener))
                             :x (if cache2 (kx cache2) (kx opener))})
          err))
      :unclosed-paren
      (assoc err :line-no (kl opener) :x (kx opener))
      err)))

(defn- error! [r ename]
  (ex-info (str "parinfer: " (name ename)) {::error (create-error r ename)}))

(defn- exit-to-paren-mode [reason]
  (ex-info "parinfer: exit to paren mode" {::exit-to-paren-mode reason}))

;; -----------------------------------------------------------------------------
;; Line operations

(defn- cursor-affected? [res start end]
  (let [cx (:cursor-x res)]
    (if (and (= cx start) (= cx end))
      (zero? cx)
      (>= cx end))))

(defn- shift-cursor-on-edit [r line-no start end replace]
  (let [res @r
        dx (- (count replace) (- end start))]
    (when (and (not (zero? dx))
               (= (:cursor-line res) line-no)
               (not= (:cursor-x res) U)
               (cursor-affected? res start end))
      (vswap! r update :cursor-x + dx))))

(defn- replace-within-line [r line-no start end replace]
  (vswap! r update-in [:lines line-no] replace-within-string start end replace)
  (shift-cursor-on-edit r line-no start end replace))

(defn- insert-within-line [r line-no idx insert]
  (replace-within-line r line-no idx idx insert))

(defn- init-line [r]
  (vswap! r (fn [res]
              (-> res
                  (assoc :x 0
                         :indent-x U
                         :comment-x U
                         :indent-delta 0
                         :tracking-arg-tab-stop nil
                         :tracking-indent? (not (:in-str? res)))
                  (update :line-no inc)
                  (update :error-pos-cache dissoc
                          :unmatched-close-paren :unmatched-open-paren :leading-close-paren)))))

(defn- commit-char
  "If the current char was replaced, commit the change to the current line."
  [r orig-ch]
  (let [res @r
        ch (:ch res)
        orig-len (count orig-ch)
        len (count ch)]
    (when (not= orig-ch ch)
      (replace-within-line r (:line-no res) (:x res) (+ (:x res) orig-len) ch)
      (vswap! r update :indent-delta - orig-len len))
    (vswap! r update :x + len)))

;; -----------------------------------------------------------------------------
;; Misc utils

(defn- clamp [v min-n max-n]
  (cond-> v
    (not= min-n U) (max min-n)
    (not= max-n U) (min max-n)))

;; -----------------------------------------------------------------------------
;; Questions about characters

(defn- valid-close-paren? [paren-stack ch]
  (and (seq paren-stack)
       (= (:ch @(peek paren-stack)) (match-paren ch))))

(defn- whitespace? [res]
  (let [ch (:ch res)]
    (and (not (:escaped? res)) (or (= ch " ") (= ch "  ")))))

(defn- closable?
  "Can this be the last code char of a list?"
  [res]
  (let [ch (:ch res)
        closer? (and (contains? (:close-paren-chars res) ch) (not (:escaped? res)))]
    (and (:in-code? res) (not (whitespace? res)) (not= ch "") (not closer?))))

;; -----------------------------------------------------------------------------
;; Advanced operations on characters

(defn- check-cursor-holding [r]
  (let [res @r
        stack (:paren-stack res)
        opener @(stack-peek stack 0)
        parent (stack-peek stack 1)
        hold-min-x (if parent (inc (:x @parent)) 0)
        hold-max-x (:x opener)
        cx (:cursor-x res)
        holding (and (= (:cursor-line res) (:line-no opener))
                     (<= hold-min-x cx) (<= cx hold-max-x))]
    (when (and (not (:changes res)) (not= (:prev-cursor-line res) U))
      (let [px (:prev-cursor-x res)
            prev-holding (and (= (:prev-cursor-line res) (:line-no opener))
                              (<= hold-min-x px) (<= px hold-max-x))]
        (when (and prev-holding (not holding))
          (throw (exit-to-paren-mode :release-cursor-hold)))))
    holding))

(defn- track-arg-tab-stop [r state]
  (let [res @r]
    (case state
      :space (when (and (:in-code? res) (whitespace? res))
               (vswap! r assoc :tracking-arg-tab-stop :arg))
      :arg (when-not (whitespace? res)
             (vswap! (stack-peek (:paren-stack res) 0) assoc :arg-x (:x res))
             (vswap! r assoc :tracking-arg-tab-stop nil)))))

;; -----------------------------------------------------------------------------
;; Literal character events

(declare reset-paren-trail)

(defn- on-open-paren [r]
  (let [res @r]
    (when (:in-code? res)
      (let [opener (volatile!
                     (cond-> {:input-line-no (:input-line-no res)
                              :input-x (:input-x res)
                              :line-no (:line-no res)
                              :x (:x res)
                              :ch (:ch res)
                              :indent-delta (:indent-delta res)
                              :max-child-indent U}
                       (:return-parens res)
                       (assoc :children (volatile! [])
                              :closer {:line-no U :x U :ch ""})))]
        (when (:return-parens res)
          (if-let [parent (stack-peek (:paren-stack res) 0)]
            (vswap! (:children @parent) conj opener)
            (vswap! r update :parens conj opener)))
        (vswap! r #(-> % (update :paren-stack conj opener)
                       (assoc :tracking-arg-tab-stop :space)))))))

(defn- set-closer [opener line-no x ch]
  (vswap! opener update :closer assoc :line-no line-no :x x :ch ch))

(defn- on-matched-close-paren [r]
  (let [res @r
        opener (stack-peek (:paren-stack res) 0)]
    (when (:return-parens res)
      (set-closer opener (:line-no res) (:x res) (:ch res)))
    (vswap! r #(-> % (assoc-in [:paren-trail :end-x] (inc (:x %)))
                   (update-in [:paren-trail :openers] conj opener)))
    (let [res @r]
      (when (and (= (:mode res) :indent) (:smart res) (check-cursor-holding r))
        (let [{:keys [start-x end-x openers]} (:paren-trail res)]
          (reset-paren-trail r (:line-no res) (inc (:x res)))
          (vswap! r assoc-in [:paren-trail :clamped]
                  {:start-x start-x :end-x end-x :openers openers}))))
    (vswap! r #(-> % (update :paren-stack pop)
                   (assoc :tracking-arg-tab-stop nil)))))

(defn- on-unmatched-close-paren [r]
  (let [res @r]
    (cond
      (= (:mode res) :paren)
      (let [trail (:paren-trail res)
            in-leading-paren-trail (and (= (:line-no trail) (:line-no res))
                                        (= (:start-x trail) (:indent-x res)))]
        (when-not (and (:smart res) in-leading-paren-trail)
          (throw (error! r :unmatched-close-paren))))

      (and (= (:mode res) :indent)
           (not (get-in res [:error-pos-cache :unmatched-close-paren])))
      (do (cache-error-pos r :unmatched-close-paren)
          (when-let [opener (stack-peek (:paren-stack res) 0)]
            (cache-error-pos r :unmatched-open-paren)
            (vswap! r update-in [:error-pos-cache :unmatched-open-paren] assoc
                    :input-line-no (:input-line-no @opener)
                    :input-x (:input-x @opener))))))
  (vswap! r assoc :ch ""))

(defn- on-close-paren [r]
  (let [res @r]
    (when (:in-code? res)
      (if (valid-close-paren? (:paren-stack res) (:ch res))
        (on-matched-close-paren r)
        (on-unmatched-close-paren r)))))

(defn- on-tab [r]
  (when (:in-code? @r)
    (vswap! r assoc :ch "  ")))

(defn- on-comment-char [r]
  (when (:in-code? @r)
    (vswap! r #(assoc % :in-comment? true :comment-x (:x %) :tracking-arg-tab-stop nil))))

(defn- on-newline [r]
  (vswap! r assoc :in-comment? false :ch ""))

(defn- on-quote [r]
  (let [res @r]
    (cond
      (:in-str? res) (vswap! r assoc :in-str? false)
      (:in-comment? res) (do (vswap! r update :quote-danger? not)
                             (when (:quote-danger? @r)
                               (cache-error-pos r :quote-danger)))
      :else (do (vswap! r assoc :in-str? true)
                (cache-error-pos r :unclosed-quote)))))

(defn- on-backslash [r]
  (vswap! r assoc :escaping? true))

(defn- after-backslash [r]
  (vswap! r assoc :escaping? false :escaped? true)
  (when (= (:ch @r) "\n")
    (when (:in-code? @r)
      (throw (error! r :eol-backslash)))
    (on-newline r)))

;; -----------------------------------------------------------------------------
;; Character dispatch

(defn- on-char [r]
  (let [ch (:ch @r)]
    (vswap! r assoc :escaped? false)
    (let [res @r]
      (cond
        (:escaping? res) (after-backslash r)
        (contains? (:open-paren-chars res) ch) (on-open-paren r)
        (contains? (:close-paren-chars res) ch) (on-close-paren r)
        (= ch "\"") (on-quote r)
        (contains? (:comment-chars res) ch) (on-comment-char r)
        (= ch "\\") (on-backslash r)
        (= ch "\t") (on-tab r)
        (= ch "\n") (on-newline r))))
  (vswap! r #(assoc % :in-code? (and (not (:in-comment? %)) (not (:in-str? %)))))
  (let [res @r]
    (when (closable? res)
      (reset-paren-trail r (:line-no res) (+ (:x res) (count (:ch res))))))
  (when-let [state (:tracking-arg-tab-stop @r)]
    (track-arg-tab-stop r state)))

;; -----------------------------------------------------------------------------
;; Cursor functions

(defn- cursor-left-of? [cursor-x cursor-line x line-no]
  ;; inclusive since (cursor-x = x) implies (x-1 < cursor < x)
  (and (= cursor-line line-no) (not= x U) (not= cursor-x U) (<= cursor-x x)))

(defn- cursor-right-of? [cursor-x cursor-line x line-no]
  (and (= cursor-line line-no) (not= x U) (not= cursor-x U) (> cursor-x x)))

(defn- cursor-in-comment? [res cursor-x cursor-line]
  (cursor-right-of? cursor-x cursor-line (:comment-x res) (:line-no res)))

(defn- handle-change-delta [r]
  (let [res @r]
    (when (and (:changes res) (or (:smart res) (= (:mode res) :paren)))
      (when-let [change (get-in (:changes res) [(:input-line-no res) (:input-x res)])]
        (vswap! r update :indent-delta + (- (:new-end-x change) (:old-end-x change)))))))

;; -----------------------------------------------------------------------------
;; Paren trail functions

(defn- reset-paren-trail [r line-no x]
  (vswap! r assoc :paren-trail
          {:line-no line-no :start-x x :end-x x :openers []
           :clamped {:start-x U :end-x U :openers []}}))

(defn- cursor-clamping-paren-trail? [res cursor-x cursor-line]
  (and (cursor-right-of? cursor-x cursor-line (get-in res [:paren-trail :start-x]) (:line-no res))
       (not (cursor-in-comment? res cursor-x cursor-line))))

(defn- clamp-paren-trail-to-cursor
  "INDENT MODE: allow the cursor to clamp the paren trail."
  [r]
  (let [res @r
        {:keys [start-x end-x openers]} (:paren-trail res)
        cursor-x (:cursor-x res)]
    (when (cursor-clamping-paren-trail? res cursor-x (:cursor-line res))
      (let [new-start-x (max start-x cursor-x)
            new-end-x (max end-x cursor-x)
            line (get (:lines res) (:line-no res))
            remove-count (count (filter #(contains? (:close-paren-chars res) (char-at line %))
                                        (range start-x new-start-x)))]
        (vswap! r update :paren-trail assoc
                :openers (slice openers remove-count (count openers))
                :start-x new-start-x
                :end-x new-end-x
                :clamped {:openers (slice openers 0 remove-count)
                          :start-x start-x
                          :end-x end-x})))))

(defn- pop-paren-trail
  "INDENT MODE: pops the paren trail from the stack."
  [r]
  (let [{:keys [start-x end-x openers]} (:paren-trail @r)]
    (when (not= start-x end-x)
      (vswap! r #(-> % (update :paren-stack into (rseq openers))
                     (assoc-in [:paren-trail :openers] []))))))

(defn- get-parent-opener-index
  "Which open-paren on the stack (if any) is the direct parent of the current
  line, given its indentation point. This lets Smart Mode simulate Paren Mode's
  structure-preserving behavior by adding its opener's indent-delta to the
  line's indentation. parinfer.js documents each branch with examples."
  [r indent-x]
  (let [res @r
        stack (:paren-stack res)
        n (count stack)
        delta (:indent-delta res)]
    (loop [i 0]
      (if (>= i n)
        i
        (let [opener (stack-peek stack i)
              o @opener
              curr-outside (< (:x o) indent-x)
              prev-indent-x (- indent-x delta)
              prev-outside (< (- (:x o) (:indent-delta o)) prev-indent-x)
              parent?
              (cond
                (and prev-outside curr-outside) true
                (and (not prev-outside) (not curr-outside)) false
                ;; possible fragmentation: prevent it when this line did not
                ;; move, allow it when it did (the both-nonzero case allows it
                ;; too, as upstream does)
                (and prev-outside (not curr-outside))
                (zero? delta)
                ;; possible adoption
                :else
                (let [next-opener (some-> (stack-peek stack (inc i)) deref)
                      adopt (cond
                              (and next-opener (<= (:indent-delta next-opener) (:indent-delta o)))
                              (> (+ indent-x (:indent-delta next-opener)) (:x o))
                              (and next-opener (> (:indent-delta next-opener) (:indent-delta o)))
                              true
                              :else (> delta (:indent-delta o)))]
                  (when adopt
                    ;; indent-delta is reserved for previous child lines only
                    (vswap! opener assoc :indent-delta 0))
                  adopt))]
          (if parent? i (recur (inc i))))))))

(declare remember-paren-trail update-remembered-paren-trail)

(defn- correct-paren-trail
  "INDENT MODE: correct paren trail from indentation."
  [r indent-x]
  (let [opener-idx (get-parent-opener-index r indent-x)
        parens (loop [i 0 parens ""]
                 (if (< i opener-idx)
                   (let [res @r
                         opener (peek (:paren-stack res))
                         close-ch (match-paren (:ch @opener))]
                     (vswap! r #(-> % (update :paren-stack pop)
                                    (update-in [:paren-trail :openers] conj opener)))
                     (when (:return-parens res)
                       (set-closer opener (get-in res [:paren-trail :line-no])
                                   (+ (get-in res [:paren-trail :start-x]) i) close-ch))
                     (recur (inc i) (str parens close-ch)))
                   parens))
        trail (:paren-trail @r)]
    (when (not= (:line-no trail) U)
      (replace-within-line r (:line-no trail) (:start-x trail) (:end-x trail) parens)
      (vswap! r assoc-in [:paren-trail :end-x] (+ (:start-x trail) (count parens)))
      (remember-paren-trail r))))

(defn- clean-paren-trail
  "PAREN MODE: remove spaces from the paren trail."
  [r]
  (let [res @r
        {:keys [start-x end-x line-no]} (:paren-trail res)]
    (when-not (or (= start-x end-x) (not= (:line-no res) line-no))
      (let [line (get (:lines res) (:line-no res))
            chs (map #(char-at line %) (range start-x end-x))
            closers (filter #(contains? (:close-paren-chars res) %) chs)
            space-count (- (count chs) (count closers))]
        (when (pos? space-count)
          (replace-within-line r (:line-no res) start-x end-x (apply str closers))
          (vswap! r update-in [:paren-trail :end-x] - space-count))))))

(defn- set-max-indent [r opener]
  (when opener
    (if-let [parent (stack-peek (:paren-stack @r) 0)]
      (vswap! parent assoc :max-child-indent (:x @opener))
      (vswap! r assoc :max-indent (:x @opener)))))

(defn- append-paren-trail
  "PAREN MODE: append a valid close-paren to the end of the paren trail."
  [r]
  (let [opener (peek (:paren-stack @r))
        close-ch (match-paren (:ch @opener))]
    (vswap! r update :paren-stack pop)
    (let [res @r
          {:keys [line-no end-x]} (:paren-trail res)]
      (when (:return-parens res)
        (set-closer opener line-no end-x close-ch))
      (set-max-indent r opener)
      (insert-within-line r line-no end-x close-ch)
      (vswap! r #(-> % (update-in [:paren-trail :end-x] inc)
                     (update-in [:paren-trail :openers] conj opener)))
      (update-remembered-paren-trail r))))

(defn- invalidate-paren-trail [r]
  (vswap! r assoc :paren-trail (initial-paren-trail)))

(defn- check-unmatched-outside-paren-trail [r]
  (let [res @r]
    (when-let [cache (get-in res [:error-pos-cache :unmatched-close-paren])]
      (when (< (:x cache) (get-in res [:paren-trail :start-x]))
        (throw (error! r :unmatched-close-paren))))))

(defn- remember-paren-trail [r]
  (let [trail (:paren-trail @r)
        clamped (:clamped trail)]
    (when (or (seq (:openers clamped)) (seq (:openers trail)))
      (let [start-x (if (not= (:start-x clamped) U) (:start-x clamped) (:start-x trail))
            end-x (if (empty? (:openers trail)) (:end-x clamped) (:end-x trail))]
        (vswap! r update :paren-trails conj
                {:line-no (:line-no trail) :start-x start-x :end-x end-x})))))

(defn- update-remembered-paren-trail
  ;; parinfer.js also points the newest opener's closer at this trail when
  ;; returning parens; its authors note that assignment is buggy and has no
  ;; effect on the suite, so the port leaves it out.
  [r]
  (let [res @r
        trails (:paren-trails res)
        trail (peek trails)]
    (if (or (nil? trail) (not= (:line-no trail) (get-in res [:paren-trail :line-no])))
      (remember-paren-trail r)
      (vswap! r assoc-in [:paren-trails (dec (count trails)) :end-x]
              (get-in res [:paren-trail :end-x])))))

(defn- finish-new-paren-trail [r]
  (let [res @r]
    (cond
      (:in-str? res) (invalidate-paren-trail r)
      (= (:mode res) :indent) (do (clamp-paren-trail-to-cursor r)
                                  (pop-paren-trail r))
      (= (:mode res) :paren) (do (set-max-indent r (stack-peek (get-in res [:paren-trail :openers]) 0))
                                 (when (not= (:line-no res) (:cursor-line res))
                                   (clean-paren-trail r))
                                 (remember-paren-trail r)))))

;; -----------------------------------------------------------------------------
;; Indentation functions

(defn- add-indent [r delta]
  (let [res @r
        orig-indent (:x res)
        new-indent (+ orig-indent delta)]
    (replace-within-line r (:line-no res) 0 orig-indent (apply str (repeat new-indent \space)))
    (vswap! r #(-> % (assoc :x new-indent :indent-x new-indent)
                   (update :indent-delta + delta)))))

(defn- should-add-opener-indent?
  "Don't add the opener's indent-delta if the user already added it (happens
  when multiple lines are indented together)."
  [r opener]
  (not= (:indent-delta @opener) (:indent-delta @r)))

(defn- correct-indent [r]
  (let [res @r
        orig-indent (:x res)
        opener (stack-peek (:paren-stack res) 0)
        [new-indent min-indent max-indent]
        (if opener
          [(if (should-add-opener-indent? r opener)
             (+ orig-indent (:indent-delta @opener))
             orig-indent)
           (inc (:x @opener))
           (:max-child-indent @opener)]
          [orig-indent 0 (:max-indent res)])
        new-indent (clamp new-indent min-indent max-indent)]
    (when (not= new-indent orig-indent)
      (add-indent r (- new-indent orig-indent)))))

(defn- on-indent [r]
  (vswap! r #(assoc % :indent-x (:x %) :tracking-indent? false))
  (when (:quote-danger? @r)
    (throw (error! r :quote-danger)))
  (case (:mode @r)
    :indent (do (correct-paren-trail r (:x @r))
                (let [opener (stack-peek (:paren-stack @r) 0)]
                  (when (and opener (should-add-opener-indent? r opener))
                    (add-indent r (:indent-delta @opener)))))
    :paren (correct-indent r)))

(defn- check-leading-close-paren [r]
  (let [res @r]
    (when (and (get-in res [:error-pos-cache :leading-close-paren])
               (= (get-in res [:paren-trail :line-no]) (:line-no res)))
      (throw (error! r :leading-close-paren)))))

(defn- on-leading-close-paren [r]
  (when (= (:mode @r) :indent)
    (when-not (:force-balance? @r)
      (when (:smart @r)
        (throw (exit-to-paren-mode :leading-close-paren)))
      (when-not (get-in @r [:error-pos-cache :leading-close-paren])
        (cache-error-pos r :leading-close-paren)))
    (vswap! r assoc :skip-char? true))
  (when (= (:mode @r) :paren)
    (let [res @r]
      (cond
        (not (valid-close-paren? (:paren-stack res) (:ch res)))
        (if (:smart res)
          (vswap! r assoc :skip-char? true)
          (throw (error! r :unmatched-close-paren)))

        (cursor-left-of? (:cursor-x res) (:cursor-line res) (:x res) (:line-no res))
        (do (reset-paren-trail r (:line-no res) (:x res))
            (on-indent r))

        :else
        (do (append-paren-trail r)
            (vswap! r assoc :skip-char? true))))))

(defn- on-comment-line [r]
  (let [trail-openers (get-in @r [:paren-trail :openers])
        n (count trail-openers)
        paren? (= (:mode @r) :paren)]
    ;; restore the openers matching the previous paren trail
    (when paren?
      (vswap! r update :paren-stack into (rseq trail-openers)))
    (let [idx (get-parent-opener-index r (:x @r))
          opener (stack-peek (:paren-stack @r) idx)]
      ;; shift the comment line based on the parent open paren
      (when (and opener (should-add-opener-indent? r opener))
        (add-indent r (:indent-delta @opener))))
    ;; repop them
    (when paren?
      (vswap! r update :paren-stack #(subvec % 0 (- (count %) n))))))

(defn- check-indent [r]
  (let [res @r
        ch (:ch res)]
    (cond
      (contains? (:close-paren-chars res) ch) (on-leading-close-paren r)
      ;; comments don't count as indentation points
      (contains? (:comment-chars res) ch) (do (on-comment-line r)
                                              (vswap! r assoc :tracking-indent? false))
      (not (contains? #{"\n" " " "\t"} ch)) (on-indent r))))

(defn- make-tab-stop [opener]
  (let [o @opener
        arg-x (:arg-x o)]
    (cond-> {:ch (:ch o) :x (:x o) :line-no (:line-no o)}
      (and (integer? arg-x) (>= arg-x 0)) (assoc :arg-x arg-x))))

(defn- tab-stop-line [res]
  (if (not= (:selection-start-line res) U)
    (:selection-start-line res)
    (:cursor-line res)))

(defn- set-tab-stops [r]
  (let [res @r]
    (when (= (tab-stop-line res) (:line-no res))
      (let [stops (cond-> (into (:tab-stops res) (map make-tab-stop) (:paren-stack res))
                    (= (:mode res) :paren)
                    (into (map make-tab-stop) (rseq (get-in res [:paren-trail :openers]))))
            ;; remove an arg-x that falls to the right of the next stop
            stops (reduce (fn [stops i]
                            (let [prev (stops (dec i))
                                  arg-x (:arg-x prev)]
                              (if (and (integer? arg-x) (>= arg-x (:x (stops i))))
                                (assoc stops (dec i) (dissoc prev :arg-x))
                                stops)))
                          stops
                          (range 1 (count stops)))]
        (vswap! r assoc :tab-stops stops)))))

;; -----------------------------------------------------------------------------
;; High-level processing functions

(defn- process-char [r ch]
  (vswap! r assoc :ch ch :skip-char? false)
  (handle-change-delta r)
  (when (:tracking-indent? @r)
    (check-indent r))
  (if (:skip-char? @r)
    (vswap! r assoc :ch "")
    (on-char r))
  (commit-char r ch))

(defn- process-line [r line-no]
  (init-line r)
  (let [line (get (:input-lines @r) line-no)]
    (vswap! r update :lines conj line)
    (set-tab-stops r)
    (dotimes [x (count line)]
      (vswap! r assoc :input-x x)
      (process-char r (char-at line x)))
    (process-char r "\n"))
  (when-not (:force-balance? @r)
    (check-unmatched-outside-paren-trail r)
    (check-leading-close-paren r))
  (when (= (:line-no @r) (get-in @r [:paren-trail :line-no]))
    (finish-new-paren-trail r)))

(defn- finalize-result [r]
  (when (:quote-danger? @r) (throw (error! r :quote-danger)))
  (when (:in-str? @r) (throw (error! r :unclosed-quote)))
  (when (and (seq (:paren-stack @r)) (= (:mode @r) :paren))
    (throw (error! r :unclosed-paren)))
  (when (= (:mode @r) :indent)
    (init-line r)
    (on-indent r))
  (vswap! r assoc :success? true))

(defn- process-text [text options mode smart]
  (let [r (initial-result text options mode smart)
        outcome (try
                  (dotimes [i (count (:input-lines @r))]
                    (vswap! r assoc :input-line-no i)
                    (process-line r i))
                  (finalize-result r)
                  nil
                  (catch clojure.lang.ExceptionInfo e
                    (let [data (ex-data e)]
                      (cond
                        (contains? data ::exit-to-paren-mode) ::exit-to-paren-mode
                        (contains? data ::error) (do (vswap! r assoc :success? false :error (::error data))
                                                     nil)
                        :else (throw e)))))]
    (if (= outcome ::exit-to-paren-mode)
      (process-text text options :paren smart)
      r)))

;; -----------------------------------------------------------------------------
;; Public API

(defn- public-parens [parens]
  (mapv (fn [opener]
          (let [o @opener]
            (cond-> o
              (:children o) (assoc :children (public-parens @(:children o))))))
        parens))

(defn- public-result [r]
  (let [res @r
        le (line-ending (:orig-text res))
        partial? (:partial-result? res)
        out (cond
              (:success? res)
              (cond-> {:text (str/join le (:lines res))
                       :cursor-x (:cursor-x res)
                       :cursor-line (:cursor-line res)
                       :success true
                       :tab-stops (:tab-stops res)
                       :paren-trails (:paren-trails res)}
                (:return-parens res) (assoc :parens (public-parens (:parens res))))

              partial?
              (cond-> {:success false
                       :error (:error res)
                       :text (str/join le (:lines res))
                       :cursor-x (:cursor-x res)
                       :cursor-line (:cursor-line res)
                       :paren-trails (:paren-trails res)}
                (:return-parens res) (assoc :parens (public-parens (:parens res))))

              :else
              {:success false
               :error (:error res)
               :text (:orig-text res)
               :cursor-x (:orig-cursor-x res)
               :cursor-line (:orig-cursor-line res)
               :paren-trails nil})]
    (cond-> out
      (= (:cursor-x out) U) (dissoc :cursor-x)
      (= (:cursor-line out) U) (dissoc :cursor-line)
      (and (contains? out :tab-stops) (empty? (:tab-stops out))) (dissoc :tab-stops))))

(defn indent-mode
  "Infer close-parens from indentation."
  ([text] (indent-mode text nil))
  ([text options]
   (public-result (process-text text options :indent false))))

(defn paren-mode
  "Infer indentation from close-parens."
  ([text] (paren-mode text nil))
  ([text options]
   (public-result (process-text text options :paren false))))

(defn smart-mode
  "Indent mode that follows the edit described by :changes and the cursor:
  indentation moves with the parens it was relative to, and a close-paren the
  cursor is holding stays put. A selection (:selection-start-line) turns the
  smart behavior off."
  ([text] (smart-mode text nil))
  ([text options]
   (public-result (process-text text options :indent (nil? (:selection-start-line options))))))
