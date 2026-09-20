;; regex-replace-zero-width-test.ss — clojure.string/replace must emit the
;; replacement for a ZERO-WIDTH match, then step past it.
;;
;; The replace scan sits next to re-seq / the matcher's .find, which advance by
;; `(if (> e ms) e (+ e 1))` (the match end, or one past a zero-width match).
;; re-replace instead bumped `start` and dropped the replacement text, so every
;; zero-width match — `#""`, `(?=x)`, `(?m)^`/`(?m)$` — replaced with NOTHING:
;;   (str/replace "abc" #"(?=b)" "X")  =>  "abc"     ; JVM: "aXbc"
;; Expected values below are babashka v1.13.222 output.
;;   chez --script test/chez/regex-replace-zero-width-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name got want)
  (set! total (+ total 1))
  (unless (equal? got want)
    (set! fails (+ fails 1))
    (printf "FAIL: ~a\n  got:  ~s\n  want: ~s\n" name got want)))

;; re-replace is the shared engine entry point clojure.string/replace(-first)
;; call after string/pattern dispatch; drive it directly.
(define (rep-all pat s repl)
  (re-replace (regex-t-irx (jolt-regex pat)) s repl #t))
(define (rep-first pat s repl)
  (re-replace (regex-t-irx (jolt-regex pat)) s repl #f))

;; lookahead / empty-pattern zero-width matches, at every position
(ok "empty-all" (rep-all "" "abc" "X") "XaXbXcX")
(ok "lookahead-empty" (rep-all "(?=)" "abc" "X") "XaXbXcX")
(ok "lookahead-ch" (rep-all "(?=b)" "abc" "X") "aXbc")
(ok "lookahead-ch-twice" (rep-all "(?=b)" "abcabc" "X") "aXbcaXbc")
(ok "lookahead-aaa" (rep-all "(?=a)" "aaa" "X") "XaXaXa")
(ok "lookahead-end" (rep-all "(?=$)" "ab" "X") "abX")
(ok "lookahead-space" (rep-all "(?= )" "ab cd" "<>") "ab<> cd")
(ok "star-empty" (rep-all "x*" "ab" "-") "-a-b-")

;; multiline anchors are zero-width (\A..\Z style) too
(ok "m-caret" (rep-all "(?m)^" "a\nb\nc" "X") "Xa\nXb\nXc")
(ok "m-dollar" (rep-all "(?m)$" "a\nb\nc" "X") "aX\nbX\ncX")
(ok "m-caret-trailing-nl" (rep-all "(?m)^" "a\nb\nc\n" "X") "Xa\nXb\nXc\n")
(ok "m-dollar-trailing-nl" (rep-all "(?m)$" "a\nb\nc\n" "X") "aX\nbX\ncX\nX")
(ok "m-caret-leading-nl" (rep-all "(?m)^" "\na\n" "X") "X\nXa\n")

;; replace-FIRST: same emission, stop after the first match
(ok "first-empty" (rep-first "" "abc" "X") "Xabc")
(ok "first-lookahead" (rep-first "(?=b)" "abc" "X") "aXbc")
(ok "first-m-caret" (rep-first "(?m)^" "a\nb" "X") "Xa\nb")

;; non-zero-width replace still correct (regression guard)
(ok "literal" (rep-all "abc" "xabcy" "X") "xXy")
(ok "literal-first" (rep-first "abc" "xabcy" "X") "xXy")

;; --- group references in the replacement ($N, ${name}) ---------------------
;; The JVM's appendReplacement syntax: $N is a group NUMBER, ${name} a named
;; group. Values are babashka v1.13.222 output.
(ok "dollar-1" (rep-all "(b)" "abc" "[$1]") "a[b]c")
(ok "dollar-0" (rep-all "(b)" "abc" "[$0]") "a[b]c")
(ok "dollar-multi-digit" (rep-all "(b)(c)" "abc" "$12") "ab2")
(ok "dollar-escaped" (rep-all "b" "abc" "\\$") "a$c")
(ok "backslash-escaped" (rep-all "b" "abc" "\\\\") "a\\c")
(ok "braced-name" (rep-all "(?<y>b)" "abc" "[${y}]") "a[b]c")

;; a group reference that cannot resolve is the JVM's error, not silent text
(define (throws-message? thunk want)
  (guard (e (#t (let ((x (jolt-unwrap-throw e)))
                  (and (jolt-ex-info-record? x)
                       (equal? (jolt-ex-info-record-message x) want)))))
    (thunk) #f))
(ok "dollar-past-count" (throws-message? (lambda () (rep-all "(b)" "abc" "$5")) "No group 5") #t)
(ok "dollar-lone" (throws-message? (lambda () (rep-all "(b)" "abc" "$"))
                                   "Illegal group reference: group index is missing") #t)
(ok "dollar-not-a-reference" (throws-message? (lambda () (rep-all "(b)" "abc" "x$y"))
                                              "Illegal group reference") #t)
(ok "dangling-backslash" (throws-message? (lambda () (rep-all "b" "abc" "\\"))
                                          "character to be escaped is missing") #t)
;; ${...} is a NAME, never a number: ${1} parses "1" as a name and rejects it
(ok "braced-number-is-a-name"
    (throws-message? (lambda () (rep-all "(b)" "abc" "${1}"))
                     "capturing group name {1} starts with digit character") #t)
(ok "braced-unknown-name" (throws-message? (lambda () (rep-all "(b)" "abc" "${nope}"))
                                           "No group with name {nope}") #t)
(ok "braced-empty-name" (throws-message? (lambda () (rep-all "(b)" "abc" "${}"))
                                         "named capturing group has 0 length name") #t)
(ok "braced-unterminated" (throws-message? (lambda () (rep-all "(b)" "abc" "${y"))
                                           "named capturing group is missing trailing '}'") #t)

;; --- Matcher.group(String) is a NAME lookup --------------------------------
(define (group-by-name pat s name)
  (let ((m (jolt-re-matcher (jolt-regex pat) s)))
    (jolt-matcher-region m 0 (string-length s))
    (jolt-re-find m)
    (jolt-matcher-group m name)))
(ok "group-by-name" (group-by-name "(?<y>b)" "abc" "y") "b")
(ok "group-name-alnum" (group-by-name "(?<y1>b)" "abc" "y1") "b")
;; a name that looks like a number is still looked up AS a name, and fails
(ok "group-name-not-index" (throws-message? (lambda () (group-by-name "(?<y>b)" "abc" "1"))
                                            "No group with name <1>") #t)
(ok "group-unknown-name" (throws-message? (lambda () (group-by-name "(?<y>b)" "abc" "nope"))
                                          "No group with name <nope>") #t)

(printf "~a/~a passed\n" (- total fails) total)
(exit (if (zero? fails) 0 1))
