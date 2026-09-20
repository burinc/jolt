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
    ("(?<=a+)d"    "aaad"          ("d"))))
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

(set! wrap-end-chunker saved-wrap)
(printf "regex-anchor: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
