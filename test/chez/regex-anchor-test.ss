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
    ("(?i)(?<=[a-c])d" "Bd"    ("d"))))
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

;; 3. controls: a body that is NOT one unit still takes the general path, so the
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
