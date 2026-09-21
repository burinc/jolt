;; regex-anchor-test.ss — a one-unit look-behind must not rescan (#1062).
;;
;; The java.util.regex `^`/`$`/`\A`/`\Z` anchors are built from IrRegex
;; look-behind/look-ahead forms (host/chez/java/regex-translate.ss).  The
;; vendored look-behind compiles its body as `(* any) BODY eos` against a chunk
;; wrapped to end at the current position, so it rescans from the chunk start on
;; every evaluation — O(n) per position, O(n^2) for a scan.  A one-unit body (a
;; single char, or a char-set over chars) only ever inspects the preceding code
;; unit, so host/chez/java/regex-anchor-sre.scm redefines `sre->procedure` with
;; an O(1) fast path for exactly that shape.
;;
;; The property gated here is the fast path itself, and it is clock-free: the
;; general path calls `wrap-end-chunker` (that is the rescan), the fast path
;; never does, so counting those calls is a deterministic witness of which path
;; ran.  The match results are checked too, against JVM-verified answers — the
;; fast path is an optimization, never a semantics change.
;;   chez --script test/chez/regex-anchor-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; Every match of `pattern` over `s`, as the matched substrings, through the same
;; scanning entry point re-seq uses (a zero-width match advances by one).
(define (matches pattern-string s)
  (let ((irx (regex-t-irx (jolt-regex pattern-string))))
    (let loop ((i 0) (acc '()))
      (let ((m (and (<= i (string-length s)) (irx-search-from irx s i))))
        (if (not m)
            (reverse acc)
            (let ((ms (irregex-match-start-index m 0)) (me (irregex-match-end-index m 0)))
              (loop (if (> me ms) me (+ me 1)) (cons (substring s ms me) acc))))))))

;; Clock-free witness: the general look-behind path wraps the chunk back to the
;; start via `wrap-end-chunker`; the fast path never does.  Count the calls for a
;; full scan of `s`.
(define wrap-calls 0)
(define saved-wrap wrap-end-chunker)
(set! wrap-end-chunker (lambda args (set! wrap-calls (+ wrap-calls 1)) (apply saved-wrap args)))
(define (rescans pattern-string s) (set! wrap-calls 0) (matches pattern-string s) wrap-calls)

(define (rep n s) (let loop ((i 0) (acc "")) (if (= i n) acc (loop (+ i 1) (string-append acc s)))))

;; 1. answers, from the JVM (java.util.regex) via babashka.  The `$` non-multiline
;; / `\Z` cases are the slow ones; the rest pin the shapes the fast path must not
;; disturb.  A string is shown before the pattern so the escapes stay legible.
(define vectors
  '(("a$"          "ba"        ("a"))
    ("a$"          "ab"        ())
    ("^a"          "ab"        ("a"))
    ("^a"          "ba"        ())
    ("\\Aa"        "ab"        ("a"))
    ("\\Aa"        "ba"        ())
    ("a\\z"        "ba"        ("a"))
    ("a\\z"        "ba\n"      ())
    ("a\\Z"        "ba"        ("a"))
    ("a\\Z"        "ba\n"      ("a"))
    ("b\\Z"        "b\n\n"     ())
    ("(?m)^a"      "a\nba\nab" ("a" "a"))
    ("(?m)a$"      "a\nb"      ("a"))
    ("(?m)b$"      "a\nb"      ("b"))
    ("(?m)^"       "a\nb"      ("" ""))
    ("(?m)$"       "a\nb"      ("" ""))
    ("(?m)a$"      "a\r\n"     ("a"))
    ("(?m)^a"      "\na"       ("a"))
    ("(?<=ab)c"    "abc"       ("c"))
    ("(?<=ab)c"    "xbc"       ())
    ("(?<=ab)c"    "cabc"      ("c"))
    ("(?<!a)b"     "cb"        ("b"))
    ("(?<!a)b"     "ab"        ())
    ("(?<=[ab])c"  "ac"        ("c"))
    ("(?<=[ab])c"  "bc"        ("c"))
    ("(?<=[ab])c"  "xc"        ())
    ("(?<=a)b"     "ab"        ("b"))
    ("(?<=a)b"     "cb"        ())
    ;; case-insensitivity folds the one-unit body exactly as the general path
    ;; does; the fast path must build its char set under the flag, not without.
    ("(?i)(?<=a)b" "Ab"        ("b"))
    ("(?i)(?<=a)b" "ab"        ("b"))
    ("(?i)(?<!a)b" "Ab"        ())
    ("(?i)(?<=A)b" "ab"        ("b"))
    ("(?i)(?<=[a-c])d" "Bd"    ("d"))
    ;; fixed-width multi-unit look-behind: the general path handles these, and
    ;; they must keep answering once the rescan is bounded to the body's width.
    ("(?<=line )(\\d+)" "line 42"  ("42"))
    ("(?<=line )(\\d+)" "xline 42" ("42"))
    ("(?<=line )(\\d+)" "lin 42"   ())
    ("(?<=abc)d"   "abcd"          ("d"))
    ("(?<=abc)d"   "bcd"           ())
    ("(?<=a|abc)d" "abcd"          ("d"))
    ("(?<=a|abc)d" "xad"           ("d"))
    ("(?<!abc)d"   "abcd"          ())
    ("(?<!abc)d"   "xbcd"          ("d"))
    ("(?<=a+)d"    "aaad"          ("d"))
    ;; a look-around nested inside a look-behind must read at position i, which
    ;; sits at the wrapped chunk's end; the body's end is pinned by a zero-width
    ;; assertion instead of `eos` (drg-bba2).
    ("(?<=a(?=b))b"     "abc"      ("b"))
    ("(?<=a(?=b))b"     "abbc"     ("b"))
    ("(?<!a(?=b))b"     "xbc"      ("b"))
    ("(?<!a(?=b))b"     "abc"      ())
    ("(?<=ab(?=c))c"    "abc"      ("c"))
    ("(?<=ab(?=c))c"    "abx"      ())
    ("(?<=a(?=bc))bc"   "abc"      ("bc"))
    ("(?<=x(?=y))y"     "xy"       ("y"))
    ("(?<=x(?=y))y"     "xz"       ())
    ;; an unbounded inner reach widens the chunk to its end; the body then gets
    ;; the whole chunk (correct, O(position) rescan).
    ("(?<=a(?=b*))b"    "abc"      ("b"))
    ("(?<=a(?=b*c))c"   "abbc"     ())
    ("(?<=a(?=b{2,}))b" "abb"      ("b"))
    ("(?<=a(?=b{2,}))b" "ab"       ())
    ("(?<=a(?=b+))b"    "acb"      ())))
(for-each (lambda (v) (ok (format "~s on ~s => ~s" (car v) (cadr v) (caddr v))
                          (equal? (matches (car v) (cadr v)) (caddr v))))
          vectors)

;; 2. one-unit look-behind bodies must not rescan at all.  The inputs are chosen
;; so the anchor is actually evaluated (and fails) at many positions; the `^`/`\A`
;; rows compile to a bare `bos` and are O(1) by construction.  Delete the fast
;; path from regex-anchor-sre.scm and every row but the two `bos` ones moves.
(define one-unit
  `(("a$"          . ,(make-string 500 #\a))
    ("^a"          . ,(make-string 500 #\a))
    ("\\Aa"        . ,(make-string 500 #\a))
    ("a\\Z"        . ,(make-string 500 #\a))
    ("(?m)a$"      . ,(rep 500 "ab\n"))
    ("(?m)^a"      . ,(rep 500 "b\na\n"))
    ("(?<=a)b"     . ,(rep 500 "cb"))
    ("(?<=[ab])c"  . ,(rep 500 "xc"))
    ("(?<!a)b"     . ,(rep 500 "ab"))
    ("(?i)(?<=a)b" . ,(rep 500 "Ab"))
    ("(?i)(?<=[a-c])d" . ,(rep 500 "Bd"))))
(for-each (lambda (c) (ok (format "~s does not rescan from the chunk start" (car c))
                          (= 0 (rescans (car c) (cdr c)))))
          one-unit)

;; 2b. a FIXED-WIDTH multi-unit look-behind must rescan only its own width, not
;; back to the chunk start.  The rescan window is the body's width and is
;; independent of the input length (the walk back to the chunk start was #1062).
;; `%look-behind-window` is set to the clamped window on every bounded evaluation,
;; or left 0 when the body's width is unbounded/unknown and the general rescan
;; runs.  This is clock-free: it counts units, not time.
(define (window pattern-string s)
  (set! %look-behind-window 0) (matches pattern-string s) %look-behind-window)
(ok "multi-unit look-behind rescan window is its own width"
    (= 5 (window "(?<=line )(\\d+)" (rep 400 "line 7 x\n"))))
(ok "multi-unit look-behind window does not grow with input"
    (= (window "(?<=line )(\\d+)" (rep 200 "line 7 x\n"))
       (window "(?<=line )(\\d+)" (rep 1600 "line 7 x\n"))))
(ok "alternation look-behind window is its widest branch"
    (= 3 (window "(?<=a|abc)d" (rep 400 "abcd"))))
(ok "an unbounded-width look-behind keeps the general rescan"
    (= 0 (window "(?<=a+)d" (rep 400 "aaad"))))

;; 3. controls: a body that is NOT one unit never takes the O(1) fast path, so the
;; witness above is live and the guard did not over-fire.  `(?<=ab)` is a two-char
;; string and `(?<=ab|cd)` an alternation of strings — if the char-set guard read
;; either as a single unit, the fast path would misfire and the query would be
;; wrong, so these also pin the guard's rejection of string leaves.
(ok "a two-char look-behind still rescans" (> (rescans "(?<=ab)c" (rep 500 "abc")) 0))
(ok "a string-alternation look-behind still rescans" (> (rescans "(?<=ab|cd)e" (rep 500 "abe")) 0))
(ok "a two-char look-behind still answers" (equal? (matches "(?<=ab)c" "zcabc") '("c")))

;; --- an assertion INSIDE a look-behind body reads the real input (jolt-69q) ---
;; The look-behind wraps the chunk to end at the current position, which is the
;; whole point of the bounded rescan above -- but an assertion that reads FORWARD
;; then answers about the wrap instead of about the subject.  $ saw the wrap as
;; end-of-input, \b saw it as end-of-word, and %java-bol ("...and not at the end
;; of input") saw every position as the end and declined them all, so
;; (?m)(?<=^) found nothing at all.  %sre-lookbehind-ext now answers #f for those
;; assertions, which restores the full-chunk wrap and lets %look-behind-end pin
;; the body's end back to i.
;;
;; These are START INDICES, not substrings: every match here is zero-width, so
;; the substring form the vectors above use cannot tell position 1 from position
;; 2.  Every expected value was taken from reference JVM Clojure.
(define (starts pattern-string s)
  (let ((irx (regex-t-irx (jolt-regex pattern-string))))
    (let loop ((i 0) (acc '()))
      (let ((m (and (<= i (string-length s)) (irx-search-from irx s i))))
        (if (not m)
            (reverse acc)
            (let ((ms (irregex-match-start-index m 0)) (me (irregex-match-end-index m 0)))
              (loop (if (> me ms) me (+ me 1)) (cons ms acc))))))))

(define lookbehind-vectors
  '(;; $ / \Z / \z inside the body: the bead's own case is the first row
    ("(?<=a$)"      "ab"     ())
    ("(?<=a$)"      "a"      (1))
    ("(?<=a$)"      "a\n"    (1))
    ("(?<=a$)"      "a\nb"   ())
    ("(?<=a\\Z)"    "ab"     ())
    ("(?<=a\\Z)"    "a"      (1))
    ("(?<=a\\z)"    "ab"     ())
    ("(?<=a\\z)"    "a"      (1))
    ;; the negative form follows from the positive one
    ("(?<!a$)b"     "ab"     (1))
    ("(?<!a$)b"     "a\nb"   (2))
    ;; the anchor inside an alternation and behind a char class
    ("(?<=a$|c)"    "ab"     ())
    ("(?<=a$|c)"    "a"      (1))
    ("(?<=[ab]$)"   "ab"     (2))
    ("(?<=[ab]$)"   "a"      (1))
    ;; multiline ^ inside a look-behind: nothing matched before jolt-69q
    ("(?m)(?<=^)"   "ab"     (0))
    ("(?m)(?<=^)"   "a\nb"   (0 2))
    ("(?m)(?<=^)"   "\na"    (0 1))
    ("(?m)(?<=\\n^)" "a\nb"  (2))
    ("(?m)(?<=a$)"  "ab"     ())
    ("(?m)(?<=a$)"  "a\n"    (1))
    ;; shapes the fix must NOT disturb: \A is purely backward, a nested
    ;; look-ahead already had its own widening, and a plain body is untouched.
    ("(?<=\\A)"     "ab"     (0))
    ("(?<=^a)"      "ab"     (1))
    ("(?<=^a)"      " ab"    ())
    ("(?<=a(?=b))"  "ab"     (1))
    ("(?<=a)"       " ab"    (2))
    ;; The line terminators $ and \Z look past: these are what sizes the widening
    ;; window at 3 (a lone \r\n is two units, so three still-available units mean
    ;; more input follows and the assertion must decline).  All JVM-verified.
    ("(?<=a$)"      "a\r\n"   (1))
    ("(?<=a$)"      "a\r\nb"  ())
    ("(?<=a$)"      "a\r"     (1))
    ("(?<=a$)"      "a\r\n\r\n" ())
    ("(?<=a$)"      "a\n\n"   ())
    ("(?<=a\\Z)"    "a\r\n"   (1))
    ("(?<=a\\Z)"    "a\r\nb"  ())
    ("(?<=a\\z)"    "a\r\n"   ())
    ("(?m)(?<=a$)"  "a\r\nb"  (1))))

(for-each
  (lambda (v)
    (let ((pat (car v)) (s (cadr v)) (want (caddr v)))
      (ok (string-append "starts " pat " over " (format "~s" s) " = " (format "~a" want))
          (equal? (starts pat s) want))))
  lookbehind-vectors)

;; --- \b and \B at the edges of the input, and over "_" (jolt-406) -------------
;; Three defects in irregex's own boundary assertions, all reachable with no
;; look-behind anywhere:
;;
;;   eow read the ABSENCE of a preceding character as a word character, so a
;;   subject starting with a non-word character reported a word ending at 0.
;;   nwb required BOTH neighbours to exist, so \B -- the complement of \b --
;;   could never match at position 0 or at the end of input.
;;   bow/eow/nwb asked char-alphanumeric?, which excludes "_", while the \w in
;;   the same pattern is (or alphanumeric #\_) (regex-translate.ss), so \b split
;;   identifiers at their underscores.
;;
;; Start indices, all from reference JVM Clojure.
(define boundary-vectors
  '(("\\b"  " ab"   (1 3))
    ("\\B"  " ab"   (0 2))
    ("\\b"  "ab "   (0 2))
    ("\\B"  "ab "   (1 3))
    ("\\b"  "a\n"   (0 1))
    ("\\B"  "a\n"   (2))
    ("\\b"  "ab"    (0 2))
    ("\\B"  "ab"    (1))
    ("\\b"  ""      ())
    ("\\B"  ""      (0))
    ("\\b"  " "     ())
    ("\\B"  " "     (0 1))
    ;; "_" is a word character, so an identifier is ONE word
    ("\\b"  "a_b"   (0 3))
    ("\\B"  "a_b"   (1 2))
    ("\\b"  "_a"    (0 2))
    ("\\B"  "_a"    (1))
    ("\\b"  "a_"    (0 2))
    ("\\B"  "a_"    (1))
    ("\\b"  "a__b"  (0 4))
    ("\\B"  "a__b"  (1 2 3))
    ;; digits are word characters too, and punctuation is not
    ("\\b"  "1a"    (0 2))
    ("\\b"  "a-b"   (0 1 2 3))
    ("\\B"  "a-b"   ())
    ("\\b"  "a.b.c" (0 1 2 3 4 5))))

(for-each
  (lambda (v)
    (let ((pat (car v)) (s (cadr v)) (want (caddr v)))
      (ok (string-append "starts " pat " over " (format "~s" s) " = " (format "~a" want))
          (equal? (starts pat s) want))))
  boundary-vectors)

;; The look-behind layer must be TRANSPARENT for an assertion body: testing X
;; inside (?<=X) at position i has to answer exactly what testing X at i answers
;; on its own.  That is the invariant jolt-69q broke and this restores, and it is
;; worth pinning separately from the values above because it still holds while
;; jolt's own \b disagrees with the JVM at the input edges (a distinct defect --
;; \b and \B there are wrong with or without the look-behind).  When that is
;; fixed these rows keep passing; if the look-behind ever starts wrapping the
;; chunk away from an assertion again, they fail even though the JVM-valued rows
;; above might not cover the shape.
(for-each
  (lambda (pat)
    (for-each
      (lambda (s)
        (ok (string-append "(?<=" pat ") is transparent over " (format "~s" s))
            (equal? (starts (string-append "(?<=" pat ")") s) (starts pat s))))
      '("ab" " ab" "ab " "a b" "a\n" "a\nb" "\na" "a" "")))
  '("\\b" "\\B" "$" "\\z" "\\Z" "\\A"))

(set! wrap-end-chunker saved-wrap)
(printf "regex-anchor: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
