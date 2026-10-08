;; jolt.line-editor gate — the editing model behind the interactive REPL,
;; driven without a terminal: key commands in, buffer and cursor out (with
;; parinfer's smart mode reconciling after each one, as at the prompt), plus the
;; Enter rule, newline indentation, key decoding and screen layout. A buffer is
;; written with | marking the cursor. Self-checks and prints LINE-EDITOR OK.
;; Run: bin/jolt run test/chez/line-editor-test.clj
(ns line-editor-test
  (:require
   [clojure.string :as str]
   [jolt.line-editor :as le]))

(def failures (atom []))
(defn fail! [msg] (swap! failures conj msg))
(defn chk= [label got want]
  (when-not (= got want)
    (fail! (str label ": want " (pr-str want) " got " (pr-str got)))))

(defn buf
  "\"(a|)\" -> {:text \"(a)\" :cursor 2}"
  [s]
  (let [i (str/index-of s "|")]
    {:text (str (subs s 0 i) (subs s (inc i))) :cursor i}))

(defn show [{:keys [text cursor]}]
  (str (subs text 0 cursor) "|" (subs text cursor)))

(defn run-keys [start cmds]
  (show (reduce le/edit (merge (le/initial-state) (buf start)) cmds)))

(defn typed [s] (map (fn [c] [:char c]) s))

(defn chk-keys [label start cmds want]
  (chk= label (run-keys start cmds) want))

;; --- closing parens are added as an open paren is typed -----------------------
(chk-keys "open paren" "|" (typed "(") "(|)")
(chk-keys "type a call" "|" (typed "(+ 1 2") "(+ 1 2|)")
(chk-keys "nested opens" "|" (typed "(let [x") "(let [x|])")
(chk-keys "map and set" "|" (typed "#{:a {:b") "#{:a {:b|}}")
(chk-keys "char literal paren adds no closer" "|" (typed "\\(") "\\(|")
(chk-keys "quote pairs" "|" (typed "\"") "\"|\"")
(chk-keys "string content" "|" (typed "\"hi") "\"hi|\"")
(chk-keys "quote steps over the closing quote" "\"hi|\"" (typed "\"") "\"hi\"|")
(chk-keys "quote inside a string is escaped" "\"a|b\"" (typed "\"") "\"a\\\"|b\"")
(chk-keys "parens in a string are text" "\"|\"" (typed "(") "\"(|\"")
(chk-keys "comment text is literal" "; |" (typed "(\"") "; (\"|")

;; --- typing a closer steps out of the form it closes ---------------------------
(chk-keys "close steps out" "(a|)" (typed ")") "(a)|")
(chk-keys "close steps out past spaces" "(a b|)" (typed " )") "(a b)|")
(chk-keys "close finds the matching form" "(a [b|])" (typed ")") "(a [b])|")
(chk-keys "close with nothing to close" "a|" (typed ")") "a|")

;; --- deleting: content first, the closer stays, then the empty form ------------
(chk-keys "backspace inside" "(ab|)" [:backspace] "(a|)")
(chk-keys "backspace to empty form" "(a|)" [:backspace] "(|)")
(chk-keys "backspace removes the empty form" "(|)" [:backspace] "|")
(chk-keys "content then form" "(ab|)" [:backspace :backspace :backspace] "|")
(chk-keys "backspace over a closer moves" "(a)|" [:backspace] "(a|)")
(chk-keys "opener of a non-empty form stays" "(|a)" [:backspace] "|(a)")
(chk-keys "inner empty form" "(foo (|))" [:backspace] "(foo |)")
(chk-keys "empty set" "#{|}" [:backspace] "|")
(chk-keys "empty anonymous fn" "#(|)" [:backspace] "|")
(chk-keys "empty string" "\"|\"" [:backspace] "|")
(chk-keys "closing quote moves" "\"a\"|" [:backspace] "\"a|\"")
(chk-keys "string then quotes" "\"ab|\"" [:backspace :backspace :backspace] "|")
(chk-keys "char literal deletes whole" "\\(|" [:backspace] "|")
(chk-keys "escape in a string deletes whole" "\"a\\n|\"" [:backspace] "\"a|\"")
(chk-keys "delete forward on empty form" "(|)" [:delete] "|")
(chk-keys "delete forward on a closer" "(a|)" [:delete] "(a|)")
(chk-keys "delete forward into a form" "|(a)" [:delete] "(|a)")
(chk-keys "delete forward char" "(|ab)" [:delete] "(|b)")

;; --- newlines indent, and parinfer keeps the closers where they belong --------
(chk-keys "newline in a call" "(defn foo [x]|)" [:newline] "(defn foo [x]\n  |)")
(chk-keys "newline body" "(defn foo [x]|)" (cons :newline (typed "(inc x")) "(defn foo [x]\n  (inc x|))")
(chk-keys "newline in a vector" "[1 2|]" [:newline] "[1 2\n |]")
(chk-keys "newline aligns a keyword list" "(:require [a]|)" [:newline] "(:require [a]\n          |)")
(chk-keys "newline trims the line end" "(a b |)" [:newline] "(a b\n  |)")
(chk-keys "newline in a string" "\"a|b\"" [:newline] "\"a\n|b\"")
(chk-keys "top-level newline" "(a)|" [:newline] "(a)\n|")

;; --- pasted text keeps its own structure and indentation ----------------------
(chk-keys "paste a form" "|" [[:paste "(defn f [x]\n  (inc x))"]] "(defn f [x]\n  (inc x))|")
(chk-keys "paste CRLF" "|" [[:paste "(a\r\n b)"]] "(a\n b)|")
(chk-keys "paste into a form" "(foo |)" [[:paste "[1 2]"]] "(foo [1 2]|)")

;; --- movement ------------------------------------------------------------------
(chk-keys "left right" "ab|c" [:left :left :right] "a|bc")
(chk-keys "home end" "(a\n b|c)" [:home] "(a\n |bc)")
(chk-keys "end of line" "(a\n |bc)" [:end] "(a\n bc)|")
(chk-keys "up keeps column" "(abc\n d|e)" [:up] "(a|bc\n de)")
(chk-keys "down clamps column" "(abcdef|\n d)" [:down] "(abcdef\n d)|")
(chk-keys "word left" "(foo bar-baz|)" [:word-left] "(foo |bar-baz)")
(chk-keys "word right" "(|foo bar)" [:word-right] "(foo| bar)")
(chk-keys "kill line" "(a |b c)" [:kill-line] "(a |)")
(chk-keys "kill word back" "(foo bar|)" [:kill-word-back] "(foo |)")
(chk-keys "kill and yank" "(a |b c)" [:kill-line [:char \x] :yank] "(a xb c|)")

;; --- Enter submits a complete form with the cursor at its end ------------------
(defn submit? [s] (let [{:keys [text cursor]} (buf s)] (le/submit? text cursor)))
(chk= "submit complete at end" (submit? "(+ 1 2)|") true)
(chk= "inside the closer is a newline" (submit? "(+ 1 2|)") false)
(chk= "trailing space at end" (submit? "(+ 1 2)| ") true)
(chk= "bare symbol" (submit? "foo|") true)
(chk= "blank" (submit? "|") true)
(chk= "unclosed string" (submit? "\"abc|") false)
(chk= "two forms" (submit? "(a) (b)|") true)

;; --- keys ----------------------------------------------------------------------
(defn decode [s]
  (let [q (atom (seq s))
        next-char (fn [_block?] (let [c (first @q)] (swap! q next) c))]
    (le/decode-key next-char)))
(chk= "printable" (decode "a") [:char \a])
(chk= "enter" (decode "\r") :enter)
(chk= "ctrl-j" (decode "\n") :newline)
(chk= "backspace" (decode "\u007f") :backspace)
(chk= "arrow up" (decode "\u001b[A") :up)
(chk= "arrow ss3" (decode "\u001bOD") :left)
(chk= "delete key" (decode "\u001b[3~") :delete)
(chk= "home csi" (decode "\u001b[H") :home)
(chk= "home tilde" (decode "\u001b[1~") :home)
(chk= "ctrl-right" (decode "\u001b[1;5C") :word-right)
(chk= "meta enter" (decode "\u001b\r") :submit)
(chk= "meta d" (decode "\u001bd") :doc)
(chk= "meta backspace" (decode "\u001b\u007f") :kill-word-back)
(chk= "ctrl-a" (decode "\u0001") :home)
(chk= "eof" (decode "") :eof)

;; --- layout --------------------------------------------------------------------
(defn rows [lay] (mapv (fn [row] (apply str (map first row))) (:rows lay)))
(let [lay (le/layout {:prompt "user=> " :text "(a\n b)" :cursor 4} 80 (constantly 1))]
  (chk= "rows" (rows lay) ["user=> (a" "        b)"])
  (chk= "cursor" (:cursor lay) [1 8]))
(let [lay (le/layout {:prompt "> " :text "abcdefghij" :cursor 10} 10 (constantly 1))]
  (chk= "wrap rows" (rows lay) ["> abcdefg" "hij"])
  (chk= "wrap cursor" (:cursor lay) [1 3]))
(let [lay (le/layout {:prompt "> " :text "ab" :cursor 0 :below "doc line\nsecond"} 40 (constantly 1))]
  (chk= "below rows" (rows lay) ["> ab" "doc line" "second"])
  (chk= "below cursor" (:cursor lay) [0 2]))
(let [lay (le/layout {:prompt "> " :text "a\tb" :cursor 3} 40 (constantly 1))]
  (chk= "tab shows as spaces" (rows lay) ["> a  b"])
  (chk= "tab cursor" (:cursor lay) [0 6]))

;; --- tokens for doc and completion ---------------------------------------------
(chk= "token at end" (le/token-at "(map inc" 4) "map")
(chk= "token inside" (le/token-at "(clojure.string/join x)" 5) "clojure.string/join")
(chk= "no token" (le/token-at "( )" 1) nil)

(if (empty? @failures)
  (println "LINE-EDITOR OK")
  (do (run! println @failures)
      (println "LINE-EDITOR FAILED" (count @failures))
      (System/exit 1)))
