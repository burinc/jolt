;; regex-anchor-prims-test.ss — the line-anchor primitives answer what the SREs
;; they replaced answer (#1062).
;;
;; host/chez/java/regex-anchors.ss reimplements java.util.regex's `^`, `$` and
;; `\Z` as zero-width primitives, decided from the code unit before the position
;; and the two after it, because compiling them as the look-ahead/look-behind SREs
;; they are equivalent to cost the general look-around machinery at every
;; candidate position.  Those SREs are still registered as the primitives'
;; `sre-named-definitions` expansions, which makes the property here a
;; DIFFERENTIAL one and pins it without a clock and without a JVM:
;;
;;   for every pattern and every input, the SRE jolt compiles (primitives) and the
;;   same SRE with every primitive expanded back (look-arounds) must report the
;;   same matches, at the same positions.
;;
;; The inputs are what makes it a test of the anchors rather than of `a$`: Java's
;; terminator set is \n, \r, \r\n, NEL, LS and PS, a CRLF is ONE terminator so no
;; anchor may sit inside it, and multiline `^` never matches at the very end of
;; input.  Those are the rules the primitives had to restate, so the battery is
;; every terminator in every position.
;;
;; The second half pins the other #1062 compile-time rewrite: a character class
;; reaches irregex as an `or`, and folding an `or` of single units into a char set
;; must not change what it matches — including what it does NOT license, a string
;; alternation, which `sre->cset` would silently widen to the set of its letters.
;;   chez --script test/chez/regex-anchor-prims-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; Every match of a compiled irx over s, as (start . end) pairs, through the same
;; scanning entry point re-seq uses (a zero-width match advances by one).
(define (scan irx s)
  (let loop ((i 0) (acc '()))
    (let ((m (and (<= i (string-length s)) (irx-search-from irx s i))))
      (if (not m)
          (reverse acc)
          (let ((ms (irregex-match-start-index m 0)) (me (irregex-match-end-index m 0)))
            (loop (if (> me ms) me (+ me 1)) (cons (cons ms me) acc)))))))

;; The same SRE with every line-anchor primitive replaced by its registered
;; expansion — the look-around form that was there before #1062.
(define (expand-prims sre)
  (cond ((and (symbol? sre) (%java-anchor-proc sre))
         (cdr (assq sre sre-named-definitions)))
        ((pair? sre) (cons (expand-prims (car sre)) (expand-prims (cdr sre))))
        (else sre)))

;; The symbols an SRE mentions, so a row can assert which anchor form jolt built.
(define (sre-symbols x)
  (cond ((symbol? x) (list x))
        ((pair? x) (append (sre-symbols (car x)) (sre-symbols (cdr x))))
        (else '())))

(define nel (string (integer->char #x85)))
(define ls (string (integer->char #x2028)))
(define ps (string (integer->char #x2029)))

(define inputs
  (list ""
        "a" "ab"
        "\n" "\r" "\r\n" "\n\r" "\r\r" "\n\n" "\r\n\r\n"
        "a\n" "a\r" "a\r\n" "a\n\r" "\na" "\ra" "\r\na"
        "a\nb" "a\rb" "a\r\nb" "a\n\rb"
        "ab\r\ncd\nef\rgh"
        "a\r\n\r\nb"
        nel ls ps
        (string-append "a" nel "b") (string-append "a" ls "b") (string-append "a" ps "b")
        (string-append "a" nel) (string-append "a" ls) (string-append "a" ps)
        (string-append "a\r" nel "b")
        " \t  \n  \t \n" "x   \n   \ny   "))

;; Every anchor, alone and in company, multiline and not, wide terminators and
;; UNIX_LINES — the four (jr-bol-sre / jr-eol-sre / jr-final-eol-sre) arms plus
;; the `bos` one `^` takes without (?m).
(define patterns
  '("$" "^" "\\Z" "\\z" "\\A"
    "(?m)$" "(?m)^" "(?d)$" "(?d)^" "(?dm)$" "(?dm)^"
    "a$" "^a" "\\s+$" "\\s*$" "(?m)\\s+$" "(?m)^.*$" "(?m)^$" "(?m)^\\s*$"
    "a\\Z" "(?d)\\Z" "(?m)^a" "(?m)b$" "^.*$" "(?s)^.*$"
    "(?i)A$" "(?m)(?i)^A" "\\b$" "(?m)\\w+$"))

(define exercised 0)
(for-each
 (lambda (src)
   (let*-values (((sre opts) (java-pattern->sre src)))
     (let ((with-prims (apply irregex sre 'backtrack opts))
           (expanded (apply irregex (expand-prims sre) 'backtrack opts)))
       (unless (equal? sre (expand-prims sre)) (set! exercised (+ exercised 1)))
       (for-each
        (lambda (s)
          (ok (format "~s agrees with its look-around form on ~s" src s)
              (equal? (scan with-prims s) (scan expanded s))))
        inputs))))
 patterns)
;; …and the comparison has to be a comparison: a pattern whose anchors are
;; irregex's own (`^` without (?m) is `bos`, `\z` is `eos`) expands to itself and
;; would pass every row above while proving nothing.  Most of the battery must
;; actually carry a primitive.
(ok "the battery exercises the primitives" (>= exercised 20))

;; The primitives must actually be what jolt compiles, or every row above is
;; comparing the look-around form with itself.
(define (compiles-to? src sym)
  (let-values (((sre opts) (java-pattern->sre src)))
    (and (memq sym (sre-symbols sre)) #t)))
(ok "(?m)^ compiles to the bol primitive" (compiles-to? "(?m)^.*$" '%java-bol))
(ok "(?m)$ compiles to the eol primitive" (compiles-to? "(?m)^.*$" '%java-eol))
(ok "a bare $ compiles to the final-eol primitive" (compiles-to? "$" '%java-final-eol))
(ok "\\Z compiles to the final-eol primitive" (compiles-to? "\\Z" '%java-final-eol))
(ok "(?d)$ compiles to the UNIX_LINES final-eol primitive"
    (compiles-to? "(?d)$" '%java-final-eol-unix))
(ok "(?dm)^ compiles to the UNIX_LINES bol primitive"
    (compiles-to? "(?dm)^" '%java-bol-unix))

;; ── char classes fold to char sets ───────────────────────────────────────────
;; What may fold: single code units, however they are spelled.
(ok "an or of chars is cset-able" (%sre-cset-able? '(or #\a #\b #\c)))
(ok "a named class is cset-able" (%sre-cset-able? 'whitespace))
(ok "\\w's shape is cset-able" (%sre-cset-able? '(or alphanumeric #\_)))
(ok "a range is cset-able" (%sre-cset-able? '(/ #\a #\z)))
(ok "a negated class is cset-able" (%sre-cset-able? '(~ whitespace)))
;; What may NOT: sre->cset widens a string to the SET of its letters, so folding
;; (or "ab" "cd") would make it match "a", "b", "c" or "d".
(ok "an or of strings is not cset-able" (not (%sre-cset-able? '(or "ab" "cd"))))
(ok "an or with a sequence is not cset-able" (not (%sre-cset-able? '(or #\a (seq #\b #\c)))))
(ok "an empty or is not cset-able" (not (%sre-cset-able? '(or))))
(ok "an or of anchors is not cset-able" (not (%sre-cset-able? '(or bos eos))))
(ok "a look-around is not cset-able" (not (%sre-cset-able? '(look-ahead #\a))))
(ok "a line-anchor primitive is not cset-able" (not (%sre-cset-able? '%java-eol)))

;; …and matching still answers what it answered, folded or not.
(define (jmatches src s)
  (map (lambda (p) (substring s (car p) (cdr p)))
       (scan (regex-t-irx (jolt-regex src)) s)))
(ok "[abc] matches each member" (equal? (jmatches "[abc]+" "xabcax") '("abca")))
(ok "\\s folds without losing a member" (equal? (jmatches "\\s+" "a \t\r\n b") '(" \t\r\n ")))
(ok "\\w folds without losing _" (equal? (jmatches "\\w+" "a_1-b") '("a_1" "b")))
(ok "a negated class still negates" (equal? (jmatches "[^abc]+" "abxyab") '("xy")))
(ok "(?i) folds the class" (equal? (jmatches "(?i)[a-c]+" "xABCx") '("ABC")))
(ok "a string alternation is still a sequence" (equal? (jmatches "(?:ab|cd)" "cd") '("cd")))
(ok "…and does not match one of its letters" (equal? (jmatches "(?:ab|cd)" "ac") '()))

(printf "regex-anchor-prims: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
