;; regex-translate.ss — Java regex pattern → irregex SRE translator.
;;
;; Parses a Java/Clojure regex pattern string ONCE via recursive descent and emits
;; an irregex SRE (s-expression AST). This is the sole compile path: regex.ss
;; compiles every pattern through (java-pattern->sre ...).
;;
;; Loaded before regex.ss; exports (java-pattern->sre pat-string) → values(sre opts).
;; The SRE is passed directly to (irregex sre . opts), bypassing irregex's PCRE
;; string reader entirely.

;; ── helpers ───────────────────────────────────────────────────────────────────

(define (oct-value ch)
  (let ((n (char->integer ch)))
    (and (>= n 48) (<= n 55) (- n 48))))

(define (oct-value? ch)
  (let ((n (char->integer ch)))
    (and (>= n 48) (<= n 55))))

(define (hex-value c)
  (cond ((and (char<=? #\0 c) (char<=? c #\9)) (- (char->integer c) 48))
        ((and (char<=? #\a c) (char<=? c #\f)) (- (char->integer c) 87))
        ((and (char<=? #\A c) (char<=? c #\F)) (- (char->integer c) 55))
        (else #f)))

(define (str-scan-char s c start end)
  (let loop ((i start))
    (cond ((>= i end) #f)
          ((char=? (string-ref s i) c) i)
          (else (loop (+ i 1))))))

(define (jr-flag? flags f) (memq f flags))

;; Scan for the two-character sequence \E (used inside \Q...\E).
(define (scan-qe src start end)
  (let loop ((i start))
    (cond ((>= (+ i 1) end) #f)
          ((and (char=? (string-ref src i) #\\) (char=? (string-ref src (+ i 1)) #\E))
           i)
          (else (loop (+ i 1))))))

;; ── Pattern-syntax errors ─────────────────────────────────────────────────────
;;
;; A malformed pattern is a java.util.regex.PatternSyntaxException on the JVM, and
;; that exception carries two things beyond the description: the index into the
;; pattern where parsing stopped, and — derived from it — the caret line getMessage
;; renders. So a parse failure here is not a bare (error …) string; it is this
;; record, raised as-is, and regex.ss turns it into the JVM's exact message. index
;; is -1 when the JVM would name no position (its own getMessage then prints no
;; " near index" clause and no caret). A record, not an R6RS condition type: the
;; Gambit boot ##includes this file, and it has define-record-type (a shim) but
;; no define-condition-type.
(define-record-type java-pattern-error (fields desc index))

(define (java-re-error desc idx)
  (raise (make-java-pattern-error desc idx)))

;; ── (?x) whitespace/comment stripping (from regex.ss, duplicated for standalone use)

(define (regex-x-strip s start)
  (let ((n (string-length s)) (out (open-output-string)))
    (let loop ((i start))
      (if (>= i n)
          (get-output-string out)
          (let ((c (string-ref s i)))
            (cond
             ((and (char=? c #\\) (< (+ i 1) n))
              (write-char c out) (write-char (string-ref s (+ i 1)) out)
              (loop (+ i 2)))
             ((char=? c #\#)
              (let skip ((j (+ i 1)))
                (if (>= j n) (loop j)
                    (if (char=? (string-ref s j) #\newline)
                        (loop (+ j 1))
                        (skip (+ j 1))))))
             ((memv c '(#\space #\tab #\newline #\return #\x0B #\x0C))
              (loop (+ i 1)))
             (else (write-char c out) (loop (+ i 1)))))))))

(define (apply-global-x src)
  (let ((n (string-length src)))
    (let loop ((i 0) (in-class #f))
      (if (>= (+ i 2) n)
          src
          (let ((c (string-ref src i)))
            (cond
             ((and (char=? c #\\) (< (+ i 1) n)) (loop (+ i 2) in-class))
             ((and (not in-class) (char=? c #\[)) (loop (+ i 1) #t))
             ((and in-class (char=? c #\])) (loop (+ i 1) #f))
             ((and (not in-class) (char=? c #\()
                   (char=? (string-ref src (+ i 1)) #\?))
              (let scan ((j (+ i 2)) (fs '()))
                (if (>= j n) src
                    (let ((fc (string-ref src j)))
                      (cond
                       ((memv fc '(#\s #\i #\m #\x #\u #\d #\U))
                        (scan (+ j 1) (cons fc fs)))
                       ((and (char=? fc #\)) (pair? fs) (memv #\x fs))
                        (let ((others (reverse (remv #\x fs))))
                          (string-append
                           (substring src 0 i)
                           (apply string-append
                                  (map (lambda (f) (string #\( #\? f #\))) others))
                           (regex-x-strip src (+ j 1)))))
                       (else (loop (+ i 1) in-class)))))))
             (else (loop (+ i 1) in-class))))))))

;; ── Leading flags ─────────────────────────────────────────────────────────────

(define (regex-flag->opt c)
  (cond ((char=? c #\s) 'single-line)
        ((char=? c #\i) 'case-insensitive)
        ((char=? c #\m) 'multi-line)
        ((char=? c #\x) 'ignore-space)
        ;; d (UNIX_LINES) narrows the terminator set DOT / ^ / $ read — see
        ;; java-nel below. It used to be accepted and dropped, which was harmless
        ;; only because the narrow set was all jolt ever applied.
        ((char=? c #\d) 'unix-lines)
        (else #f)))

(define (parse-leading-flags src i end)
  (let loop ((i i) (opts '()))
    (if (>= (+ i 3) end)
        (values (reverse opts) i)
        (let ((c0 (string-ref src i))
              (c1 (string-ref src (+ i 1))))
          (if (and (char=? c0 #\() (char=? c1 #\?))
              (let scan ((j (+ i 2)) (fs '()))
                (if (>= j end)
                    (values (reverse opts) i)
                    (let ((c (string-ref src j)))
                      (cond
                       ((memv c '(#\u #\U)) (scan (+ j 1) fs))
                       ((regex-flag->opt c) =>
                        (lambda (opt) (scan (+ j 1) (cons opt fs))))
                       ((char=? c #\))
                        (if (and (< (+ j 1) end)
                                 (memv (string-ref src (+ j 1)) '(#\* #\+ #\?)))
                            (error 'java-pattern->sre
                                   "dangling quantifier after flag group" src)
                            (loop (+ j 1) (append opts (reverse fs)))))
                       ((char=? c #\:) (values (reverse opts) i))
                       (else (values (reverse opts) i))))))
              (values (reverse opts) i))))))

;; ── \p{...} property class → SRE char-set ─────────────────────────────────────
;; Covers the categories the current pipeline handles, extended to include
;; supplementary-plane letters (the known \p{L} above U+D7FF residual).

(define sre-Zs
  '(or #\space #\xA0 #\x1680 (/ #\x2000 #\x200A) #\x202F #\x205F #\x3000))
(define sre-Z
  '(or #\space #\xA0 #\x1680 (/ #\x2000 #\x200A) #\x2028 #\x2029 #\x202F #\x205F #\x3000))

;; \p{L}/\p{N} used to approximate with a hand-picked range ((/ #\x80
;; #\xD7FF) for L), which is nearly the whole BMP above ASCII and so
;; wrongly matched symbols/punctuation too, e.g. U+2192 → (#941). Build
;; the real Unicode ranges from Chez's own char-general-category (and, for
;; the binary properties, its R6RS char predicates) instead. ~10ms over the
;; full codepoint space, paid once per name and lazily, only if a pattern
;; actually uses it.
(define (unicode-property-ranges in?)
  (let loop ((cp 0) (start #f) (ranges '()))
    (define (close-at cp ranges)
      (if start (cons `(/ ,(integer->char start) ,(integer->char (- cp 1))) ranges) ranges))
    (cond
     ((> cp #x10FFFF) (cons 'or (reverse (close-at cp ranges))))
     ((and (>= cp #xD800) (<= cp #xDFFF)) (loop (+ cp 1) start ranges)) ; surrogates
     (else
      (let ((in? (in? (integer->char cp))))
        (cond
         ((and in? (not start)) (loop (+ cp 1) cp ranges))
         ((and (not in?) start) (loop (+ cp 1) #f (close-at cp ranges)))
         (else (loop (+ cp 1) start ranges))))))))

;; The JVM's rule, which these follow: a Unicode CATEGORY name (\p{L}, \p{Lu},
;; \p{N}, \p{Nd}, \p{P} ...) is the real category over every codepoint, while a
;; POSIX name (\p{Alpha}, \p{Digit}, \p{Upper}, \p{Punct} ...) is ASCII unless
;; UNICODE_CHARACTER_CLASS is on -- so \p{Alpha} matches "a" and not "é", and
;; \p{Nd} matches an Arabic-Indic digit but not a Roman numeral (that is \p{N}).
;;
;; Every general category and category group java.util.regex names (Pattern's
;; CharPredicates), spelled as the R6RS categories it unions. The binary
;; properties the JVM spells \p{IsAlphabetic}, \p{IsLowercase} … are the same
;; Unicode properties R6RS's char-alphabetic? / char-lower-case? … answer, and
;; Character.isLowerCase/isUpperCase/isAlphabetic (javaLowerCase …) are those
;; properties too, not the bare Ll/Lu categories. A script (\p{IsLatin}) or a
;; block (\p{InGreek}) has no data behind it here: jolt has no script or block
;; tables, so those names are refused as unsupported (known-divergences.edn).
(define unicode-category-groups
  '(("L" Lu Ll Lt Lm Lo) ("LC" Lu Ll Lt) ("Lu" Lu) ("Ll" Ll) ("Lt" Lt) ("Lm" Lm) ("Lo" Lo)
    ("M" Mn Mc Me) ("Mn" Mn) ("Mc" Mc) ("Me" Me)
    ("N" Nd Nl No) ("Nd" Nd) ("Nl" Nl) ("No" No)
    ("P" Pc Pd Ps Pe Pi Pf Po) ("Pc" Pc) ("Pd" Pd) ("Ps" Ps) ("Pe" Pe) ("Pi" Pi) ("Pf" Pf) ("Po" Po)
    ("S" Sm Sc Sk So) ("Sm" Sm) ("Sc" Sc) ("Sk" Sk) ("So" So)
    ("C" Cc Cf Cs Co Cn) ("Cc" Cc) ("Cf" Cf) ("Cs" Cs) ("Co" Co) ("Cn" Cn)))

(define unicode-binary-properties
  `(("ALPHABETIC" . ,char-alphabetic?)
    ("LOWERCASE" . ,char-lower-case?)
    ("UPPERCASE" . ,char-upper-case?)
    ("WHITE_SPACE" . ,char-whitespace?) ("WHITESPACE" . ,char-whitespace?)
    ("TITLECASE" . ,(lambda (c) (eq? (char-general-category c) 'Lt)))
    ("LETTER" . ,(lambda (c) (memq (char-general-category c) '(Lu Ll Lt Lm Lo))))
    ("DIGIT" . ,(lambda (c) (eq? (char-general-category c) 'Nd)))
    ("ALNUM" . ,(lambda (c) (or (char-alphabetic? c) (eq? (char-general-category c) 'Nd))))
    ("BLANK" . ,(lambda (c) (or (eq? (char-general-category c) 'Zs) (char=? c #\tab))))
    ("PUNCTUATION" . ,(lambda (c) (memq (char-general-category c) '(Pc Pd Ps Pe Pi Pf Po))))
    ("CONTROL" . ,(lambda (c) (eq? (char-general-category c) 'Cc)))
    ("ASSIGNED" . ,(lambda (c) (not (eq? (char-general-category c) 'Cn))))
    ;; UnicodeProp.HEXDIGIT is DIGIT.is(ch) || the ASCII and fullwidth spellings,
    ;; so EVERY Nd digit is a hex digit to java.util.regex — U+1C50, U+0660 and
    ;; U+0966 all answer \p{IsHex_Digit} on the JDK. A wider set than Unicode's
    ;; own Hex_Digit property, and the JVM's is what this has to answer.
    ("HEX_DIGIT" . ,(lambda (c) (or (eq? (char-general-category c) 'Nd)
                                    (and (char<=? #\0 c) (char<=? c #\9))
                                    (and (char<=? #\a c) (char<=? c #\f))
                                    (and (char<=? #\A c) (char<=? c #\F))
                                    (and (char<=? #\xFF10 c) (char<=? c #\xFF19))
                                    (and (char<=? #\xFF21 c) (char<=? c #\xFF26))
                                    (and (char<=? #\xFF41 c) (char<=? c #\xFF46)))))
    ("JOIN_CONTROL" . ,(lambda (c) (memv (char->integer c) '(#x200C #x200D))))
    ("NONCHARACTER_CODE_POINT" . ,(lambda (c) (let ((n (char->integer c)))
                                                (or (and (>= n #xFDD0) (<= n #xFDEF))
                                                    (= (bitwise-and n #xFFFE) #xFFFE)))))))

;; Character.isX for the javaX names, as the JDK defines them.
(define java-character-predicates
  `(("javaLowerCase" . ,char-lower-case?)
    ("javaUpperCase" . ,char-upper-case?)
    ("javaAlphabetic" . ,char-alphabetic?)
    ("javaTitleCase" . ,(lambda (c) (eq? (char-general-category c) 'Lt)))
    ("javaLetter" . ,(lambda (c) (memq (char-general-category c) '(Lu Ll Lt Lm Lo))))
    ("javaDigit" . ,(lambda (c) (eq? (char-general-category c) 'Nd)))
    ("javaLetterOrDigit" . ,(lambda (c) (memq (char-general-category c) '(Lu Ll Lt Lm Lo Nd))))
    ("javaDefined" . ,(lambda (c) (not (eq? (char-general-category c) 'Cn))))
    ("javaSpaceChar" . ,(lambda (c) (memq (char-general-category c) '(Zs Zl Zp))))
    ;; isWhitespace: a space separator that is not non-breaking, the line and
    ;; paragraph separators, and the ASCII controls \t \n \x0B \f \r \x1C-\x1F.
    ("javaWhitespace" . ,(lambda (c) (let ((n (char->integer c)))
                                       (or (and (memq (char-general-category c) '(Zs Zl Zp))
                                                (not (memv n '(#xA0 #x2007 #x202F))))
                                           (and (>= n 9) (<= n 13))
                                           (and (>= n #x1C) (<= n #x1F))))))
    ("javaISOControl" . ,(lambda (c) (let ((n (char->integer c)))
                                       (or (<= n #x1F) (and (>= n #x7F) (<= n #x9F))))))))

;; name -> built SRE, once per name (the walk over the codepoint space is the
;; cost, so a class is built the first time a pattern names it and kept). The
;; regex cache's lock already serializes the translator's callers; the table
;; takes its own so a direct caller (a gate, a REPL) is safe too — a Chez
;; hashtable written from two threads faults in the collector.
(define unicode-property-cache (make-hashtable string-hash string=?))
(define unicode-property-mutex (make-mutex 'unicode-properties))
(define (unicode-property-sre name in?)
  (or (hashtable-ref unicode-property-cache name #f)
      (jolt-with-mutex unicode-property-mutex
        (or (hashtable-ref unicode-property-cache name #f)
            (let ((sre (unicode-property-ranges in?)))
              (hashtable-set! unicode-property-cache name sre)
              sre)))))

;; The SRE for a \p{name}, or #f for a name jolt cannot build. The spellings
;; the JVM accepts for a category — L, IsL, gc=L, general_category=L — all
;; reach the same table; a binary property is Is<Property>.
(define (prop-class-sre name)
  (define (category-sre nm)
    (let ((e (assoc nm unicode-category-groups)))
      (and e (unicode-property-sre nm (lambda (c) (memq (char-general-category c) (cdr e)))))))
  (define (prefixed? pre) (and (> (string-length name) (string-length pre))
                               (string=? (substring name 0 (string-length pre)) pre)))
  (define (after pre) (substring name (string-length pre) (string-length name)))
  (cond
   ;; The Unicode separator categories are a short fixed list, so spell them out
   ;; rather than settling for irregex's ASCII `blank`. Zs is the space separators
   ;; (the non-breaking ones included — \p{Z} is a category, not Java's
   ;; isWhitespace), Zl the line separator, Zp the paragraph separator.
   ((string=? name "Zs") sre-Zs)
   ((string=? name "Zl") #\x2028)
   ((string=? name "Zp") #\x2029)
   ((string=? name "Z") sre-Z)
   ((category-sre name) => values)
   ;; POSIX names: ASCII, as on the JVM
   ((string=? name "Alpha") 'alpha)
   ((string=? name "Digit") 'numeric)
   ((string=? name "Lower") 'lower)
   ((string=? name "Upper") 'upper)
   ((string=? name "ASCII") 'ascii)
   ((string=? name "Alnum") 'alphanumeric)
   ((string=? name "Punct") 'punct)
   ((string=? name "Graph") 'graph)
   ((string=? name "Print") 'print)
   ((string=? name "Blank") 'blank)
   ((string=? name "Cntrl") 'cntrl)
   ((string=? name "XDigit") 'xdigit)
   ((string=? name "Space") 'whitespace)
   ((string=? name "all") 'any)
   ((assoc name java-character-predicates)
    => (lambda (e) (unicode-property-sre name (cdr e))))
   ((prefixed? "Is")
    (let ((nm (after "Is")))
      (cond ((assoc (string-upcase nm) unicode-binary-properties)
             => (lambda (e) (unicode-property-sre name (cdr e))))
            (else (prop-class-sre nm)))))
   ((prefixed? "gc=") (category-sre (after "gc=")))
   ((prefixed? "general_category=") (category-sre (after "general_category=")))
   (else #f)))

;; ── Literal string → SRE ──────────────────────────────────────────────────────

(define (make-lit s)
  (let ((len (string-length s)))
    (cond ((= len 0) 'epsilon)
          ((= len 1) (string-ref s 0))
          (else `(seq ,@(map (lambda (i) (string-ref s i)) (iota len)))))))

;; ── Entry point ───────────────────────────────────────────────────────────────


;; ── JDK-faithful pattern-syntax validator ─────────────────────────────────────
;; Java rejects patterns the SRE translation would otherwise quietly accept: a
;; quantifier with no atom, a malformed {...}, an unfinished group, a bad
;; \p / \x / \N / \k escape.  This mirrors java.util.regex.Pattern's own scan
;; (group0 / sequence / atom / closure / clazz / range / escape) so the reported
;; description and index match the JVM (host/chez/regex.ss renders them as
;; "<desc> near index <n>" plus the caret line).  It answers only "what would
;; the JVM say about this text"; whether jolt can BUILD what it accepts is the
;; translator's question, asked next.
;;
;; The JVM's indexes are cursor arithmetic (error() reports cursor - 1), and a
;; scan that has run off the end sits one past the sentinel — which is why an
;; unclosed group after a trailing backslash is "near index n+1" while a plain
;; unclosed group is "near index n".  Every such quirk here was captured from a
;; JDK run (test/chez/regex-syntax-test.ss), not derived.

;; Pattern.RemoveQEQuoting, exactly: the JVM rewrites every \Q…\E span BEFORE it
;; parses, and the index its PatternSyntaxException names is an index into that
;; rewritten buffer, not the source. A quoted ASCII letter or non-ASCII unit is
;; copied; a quoted digit is copied too, with a \x3 prefix when it opens the
;; quote (so a \u escape before the \Q cannot absorb it); any other quoted unit
;; is backslash-escaped, a quoted backslash doubled. A quote with no \E runs to
;; the end. Everything before the first \Q, and everything outside a quote after
;; it, is copied verbatim — an \E outside a quote stays for the scanner to reject.
(define (jsc-qe-rewrite s)
  (let* ((n (string-length s))
         (start (let loop ((i 0))
                  (cond ((>= i (- n 1)) #f)
                        ((not (char=? (string-ref s i) #\\)) (loop (+ i 1)))
                        ((char=? (string-ref s (+ i 1)) #\Q) i)
                        (else (loop (+ i 2)))))))
    (if (not start)
        s
        (let loop ((i (+ start 2)) (in-quote #t) (begin-quote #t)
                   (acc (reverse (string->list (substring s 0 start)))))
          (if (>= i n)
              (list->string (reverse acc))
              (let ((c (string-ref s i)) (i (+ i 1)))
                (cond
                  ((or (> (char->integer c) 127) (jsc-latin-letter? c))
                   (loop i in-quote #f (cons c acc)))
                  ((jsc-digit? c)
                   (loop i in-quote #f
                         (cons c (if begin-quote (append '(#\3 #\x #\\) acc) acc))))
                  ((not (char=? c #\\))
                   (loop i in-quote #f (cons c (if in-quote (cons #\\ acc) acc))))
                  (in-quote
                   (if (and (< i n) (char=? (string-ref s i) #\E))
                       (loop (+ i 1) #f #f acc)
                       (loop i #t #f (cons #\\ (cons #\\ acc)))))
                  ((and (< i n) (char=? (string-ref s i) #\Q))
                   (loop (+ i 1) #t #t acc))
                  (else
                   (loop (if (< i n) (+ i 1) i) #f #f
                         (if (< i n) (cons (string-ref s i) (cons c acc)) (cons c acc)))))))))))

(define (jsc-latin-letter? c)
  (or (and (char>=? c #\A) (char<=? c #\Z))
      (and (char>=? c #\a) (char<=? c #\z))))

(define (jsc-digit? c)
  (and (char>=? c #\0) (char<=? c #\9)))

(define (jsc-latin-char? c)
  (or (jsc-latin-letter? c) (jsc-digit? c)))

(define (jsc-octal? c)
  (and (char>=? c #\0) (char<=? c #\7)))

;; Is this a \p{…} name the JVM would accept?  The general categories and their
;; groups, the POSIX and java* names, `all`, and the prefixed spellings — an Is
;; (script, binary property or category), an In (block), gc= / general_category=
;; / sc= / script= / blk= / block= — with a non-empty argument.  A script or
;; block NAME is not checked (jolt has no table to check it against); the
;; translator refuses the ones it cannot build.
(define jvm-property-names
  '("Lower" "Upper" "ASCII" "Alpha" "Digit" "Alnum" "Punct" "Graph" "Print"
    "Blank" "Cntrl" "XDigit" "Space" "all"
    "javaLowerCase" "javaUpperCase" "javaAlphabetic" "javaIdeographic"
    "javaTitleCase" "javaDigit" "javaDefined" "javaLetter" "javaLetterOrDigit"
    "javaJavaIdentifierStart" "javaJavaIdentifierPart"
    "javaUnicodeIdentifierStart" "javaUnicodeIdentifierPart"
    "javaIdentifierIgnorable" "javaSpaceChar" "javaWhitespace" "javaISOControl"
    "javaMirrored"
    "C" "Cc" "Cf" "Cn" "Co" "Cs" "L" "LC" "Ll" "Lm" "Lo" "Lt" "Lu" "M" "Mc" "Me"
    "Mn" "N" "Nd" "Nl" "No" "P" "Pc" "Pd" "Pe" "Pf" "Pi" "Po" "Ps" "S" "Sc" "Sk"
    "Sm" "So" "Z" "Zl" "Zp" "Zs"))

(define (jvm-property-name? name)
  (define (prefixed? pre)
    (and (> (string-length name) (string-length pre))
         (string=? (substring name 0 (string-length pre)) pre)))
  (or (and (member name jvm-property-names) #t)
      (prefixed? "Is") (prefixed? "In")
      (prefixed? "gc=") (prefixed? "general_category=")
      (prefixed? "sc=") (prefixed? "script=")
      (prefixed? "blk=") (prefixed? "block=")))

;; COMMENTS mode. The JVM skips whitespace and #-to-end-of-line comments at
;; nearly every token boundary once an unscoped (?x) is in force — inside a
;; class, between ( and ?, after \p, between the digits of a {m,n} — and the
;; translator handles it the same way apply-global-x does: everything after the
;; first unscoped flag group naming x is stripped before parsing. The validator
;; scans that same stripped text, so it accepts exactly what the translator
;; parses; what it must then add back is the JVM's index, which is a position
;; in the UNSTRIPPED pattern. So this returns the stripped text and, for each
;; of its positions, the original one. Before the first (?x) nothing changes.
(define (jsc-x-strip s)
  (let ((n (string-length s)))
    (define (x-group-end i)             ; i at ( of (?…): index after ) when the
      (let scan ((j (+ i 2)) (x? #f))    ; group is unscoped flags naming x
        (and (< j n)
             (let ((c (string-ref s j)))
               (cond ((char=? c #\x) (scan (+ j 1) #t))
                     ;; the same flag set apply-global-x accepts, and no wider:
                     ;; a group naming "-" turns flags OFF, so (?-x), (?i-x) and
                     ;; (?idmsux-idmsux) all leave COMMENTS mode off. Taking the
                     ;; x on either side of the "-" as switching it on stripped
                     ;; whitespace and #-comments the translator kept, so the
                     ;; validator read a different pattern than the one built:
                     ;; (?-x)#\k compiled here and is an error on the JVM.
                     ((memv c '(#\s #\i #\m #\u #\d #\U)) (scan (+ j 1) x?))
                     ((and (char=? c #\)) x?) (+ j 1))
                     (else #f))))))
    (let find ((i 0) (in-class #f))
      (cond
        ((>= (+ i 2) n) (values s #f))
        ((char=? (string-ref s i) #\\) (find (+ i 2) in-class))
        ((and (not in-class) (char=? (string-ref s i) #\[)) (find (+ i 1) #t))
        ((and in-class (char=? (string-ref s i) #\])) (find (+ i 1) #f))
        ((and (not in-class) (char=? (string-ref s i) #\()
              (char=? (string-ref s (+ i 1)) #\?)
              (x-group-end i))
         => (lambda (start)
              (let ((out (open-output-string)) (map '()))
                (let loop ((k 0))
                  (when (< k start)
                    (write-char (string-ref s k) out) (set! map (cons k map)) (loop (+ k 1))))
                (let loop ((k start))
                  (if (>= k n)
                      (begin (set! map (cons n map))
                             (values (get-output-string out) (list->vector (reverse map))))
                      (let ((c (string-ref s k)))
                        (cond
                          ((and (char=? c #\\) (< (+ k 1) n))
                           (write-char c out) (write-char (string-ref s (+ k 1)) out)
                           (set! map (cons (+ k 1) (cons k map)))
                           (loop (+ k 2)))
                          ((char=? c #\#)
                           (let skip ((j (+ k 1)))
                             (cond ((>= j n) (loop j))
                                   ((char=? (string-ref s j) #\newline) (loop (+ j 1)))
                                   (else (skip (+ j 1))))))
                          ((memv c '(#\space #\tab #\newline #\return #\x0B #\x0C))
                           (loop (+ k 1)))
                          (else (write-char c out) (set! map (cons k map)) (loop (+ k 1))))))))))
        (else (find (+ i 1) in-class))))))

(define (java-syntax-check source)
  (let*-values (((qe) (jsc-qe-rewrite source))
                ((s index-map) (jsc-x-strip qe)))
   (let ((n (string-length s)))
    (define (rf k) (string-ref s k))
    ;; An index is a position in s; in COMMENTS mode it is mapped back to the
    ;; unstripped pattern. The JVM's end-relative indexes (n-1, n+1) and its
    ;; "the unit before" (Unmatched closing) are an offset from a mapped
    ;; position, so they land on a stripped unit when that is what is there.
    (define (err desc idx . delta)
      (let ((d (if (null? delta) 0 (car delta))))
        (java-re-error desc
                       (+ d (cond ((not index-map) idx)
                                  ((<= idx n) (vector-ref index-map idx))
                                  (else (+ (string-length qe) (- idx n))))))))
    (define seen '())                   ; the named groups defined so far
    (define refs 0)                     ; back-references read so far

    ;; ── escapes ──
    ;; Each reads one escape and answers (values kind code next): kind is char
    ;; (code = the code point, or #f for a \N{…} whose value jolt cannot look
    ;; up), class (\d \p{…} …), atom (an assertion or \R, quantifiable like the
    ;; JVM allows), or ref.  A class can be quantified but not end a range.

    ;; \0: one to three octal digits, the third only when the first is 0-3.
    (define (octal i)                   ; i = the first digit
      (if (or (>= i n) (not (jsc-octal? (rf i))))
          (err "Illegal octal escape sequence" i)
          (let ((d1 (- (char->integer (rf i)) 48)))
            (if (and (< (+ i 1) n) (jsc-octal? (rf (+ i 1))))
                (let ((d2 (- (char->integer (rf (+ i 1))) 48)))
                  (if (and (<= d1 3) (< (+ i 2) n) (jsc-octal? (rf (+ i 2))))
                      (values (+ (* d1 64) (* d2 8) (- (char->integer (rf (+ i 2))) 48)) (+ i 3))
                      (values (+ (* d1 8) d2) (+ i 2))))
                (values d1 (+ i 1))))))

    ;; \x: two hex digits, or {hex+} at most 0x10FFFF (Pattern.x()).
    (define (hex i)                     ; i = after the x
      (cond
        ((and (< i n) (hex-value (rf i)))
         (if (and (< (+ i 1) n) (hex-value (rf (+ i 1))))
             (values (+ (* 16 (hex-value (rf i))) (hex-value (rf (+ i 1)))) (+ i 2))
             (err "Illegal hexadecimal escape sequence" (+ i 1))))
        ((and (< i n) (char=? (rf i) #\{) (< (+ i 1) n) (hex-value (rf (+ i 1))))
         (let loop ((k (+ i 1)) (v 0))
           (cond ((>= k n) (err "Unclosed hexadecimal escape sequence" k))
                 ((hex-value (rf k))
                  (let ((v (+ (* v 16) (hex-value (rf k)))))
                    (if (> v #x10FFFF)
                        (err "Hexadecimal codepoint is too big" k)
                        (loop (+ k 1) v))))
                 ((char=? (rf k) #\}) (values v (+ k 1)))
                 (else (err "Unclosed hexadecimal escape sequence" k)))))
        (else (err "Illegal hexadecimal escape sequence" i))))

    ;; \u: exactly four hex digits (Pattern.uxxxx()) …
    (define (uxxxx i)                   ; i = after the u
      (let loop ((k i) (v 0))
        (cond ((>= k (+ i 4)) (values v k))
              ((and (< k n) (hex-value (rf k)))
               (loop (+ k 1) (+ (* v 16) (hex-value (rf k)))))
              (else (err "Illegal Unicode escape sequence" k)))))
    ;; … and a high surrogate followed by \u + a low one is a single code point
    ;; (Pattern.u()); the second escape is read, and so checked, either way.
    (define (unicode i)
      (let-values (((v k) (uxxxx i)))
        (if (and (<= #xD800 v) (<= v #xDBFF)
                 (< (+ k 1) n) (char=? (rf k) #\\) (char=? (rf (+ k 1)) #\u))
            (let-values (((v2 k2) (uxxxx (+ k 2))))
              (if (and (<= #xDC00 v2) (<= v2 #xDFFF))
                  (values (+ #x10000 (* (- v #xD800) #x400) (- v2 #xDC00)) k2)
                  (values v k)))
            (values v k))))

    ;; \N{name}: the braces are checked here, and a name no character can have
    ;; (Character.codePointOf takes letters, digits, space and hyphen, any case,
    ;; and every name has a letter) is refused as the JVM refuses it; whether a
    ;; well-formed name EXISTS is the translator's answer, which is that it has
    ;; no table to say.
    (define (charname i)                ; i = after the N → next
      (if (or (>= i n) (not (char=? (rf i) #\{)))
          (err "Illegal character name escape sequence" i)
          (let ((cl (str-scan-char s #\} (+ i 1) n)))
            (cond
              ((not cl)
               (if (>= (+ i 1) (- n 1))
                   (err "Unclosed character name escape sequence" (+ i 1))
                   (err "Unclosed character name escape sequence" n -1)))
              ((let ok ((k (+ i 1)) (letter #f))
                 (if (>= k cl)
                     letter
                     (and (or (jsc-latin-char? (rf k)) (memv (rf k) '(#\space #\-)))
                          (ok (+ k 1) (or letter (jsc-latin-letter? (rf k)))))))
               (+ cl 1))
              (else
               (err (string-append "Unknown character name [" (substring s (+ i 1) cl) "]") cl))))))

    ;; \p{name} / \pL: the shape, and that the JVM knows the name.
    (define (property i)                ; i = after the p/P → next
      (cond
        ((>= i n)
         (err (string-append "Unknown character property name {"
                             (string (integer->char 0)) "}")
              i))
        ((char=? (rf i) #\{)
         (let ((cl (str-scan-char s #\} (+ i 1) n)))
           (cond ((not cl) (err "Unclosed character family" n))
                 ((= cl (+ i 1)) (err "Empty character family" cl))
                 ((jvm-property-name? (substring s (+ i 1) cl)) (+ cl 1))
                 (else (err (string-append "Unknown character property name {"
                                           (substring s (+ i 1) cl) "}")
                            cl)))))
        ((jvm-property-name? (string (rf i))) (+ i 1))
        (else (err (string-append "Unknown character property name {" (string (rf i)) "}")
                   i))))

    ;; <name> of a named group or a \k back-reference: a Latin letter, then
    ;; Latin letters and digits, then > → (values name next)
    (define (groupname j)
      (if (or (>= j n) (not (jsc-latin-letter? (rf j))))
          (err "capturing group name does not start with a Latin letter" j)
          (let loop ((k (+ j 1)))
            (cond ((>= k n) (err "named capturing group is missing trailing '>'" n))
                  ((char=? (rf k) #\>) (values (substring s j k) (+ k 1)))
                  ((jsc-latin-char? (rf k)) (loop (+ k 1)))
                  (else (err "named capturing group is missing trailing '>'" k))))))

    (define (backref i)                 ; i = after the k → next
      (if (or (>= i n) (not (char=? (rf i) #\<)))
          (err "\\k is not followed by '<' for named capturing group" i)
          (let-values (((nm k) (groupname (+ i 1))))
            (if (member nm seen)
                k
                (err (string-append "named capturing group <" nm "> does not exist")
                     (- k 1))))))

    ;; One escape at i (the backslash). where is top, group or class: a trailing
    ;; backslash reads the JVM's end sentinel as a literal, and what then fails
    ;; is the enclosing construct.
    (define (escape i where)
      (if (>= (+ i 1) n)
          (case where
            ((class) (err "Unclosed character class" n))
            ((top) (err "Unescaped trailing backslash" n))
            (else (err "Unclosed group" n 1)))
          (let ((c (rf (+ i 1))) (inclass (eq? where 'class)))
            (define (illegal) (err "Illegal/unsupported escape sequence" (+ i 1)))
            (define (char v k) (values 'char v k))
            (case c
              ((#\0) (let-values (((v k) (octal (+ i 2)))) (char v k)))
              ((#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
               (if inclass (illegal) (begin (set! refs (+ refs 1)) (values 'ref #f (+ i 2)))))
              ((#\a) (char 7 (+ i 2)))
              ((#\e) (char 27 (+ i 2)))
              ((#\f) (char 12 (+ i 2)))
              ((#\n) (char 10 (+ i 2)))
              ((#\r) (char 13 (+ i 2)))
              ((#\t) (char 9 (+ i 2)))
              ((#\c)
               (if (>= (+ i 2) n)
                   (err "Illegal control escape sequence" (+ i 1))
                   (char (bitwise-xor (char->integer (rf (+ i 2))) 64) (+ i 3))))
              ((#\x) (let-values (((v k) (hex (+ i 2)))) (char v k)))
              ((#\u) (let-values (((v k) (unicode (+ i 2)))) (char v k)))
              ((#\N) (char #f (charname (+ i 2))))
              ((#\p #\P) (values 'class #f (property (+ i 2))))
              ((#\d #\D #\s #\S #\w #\W #\h #\H #\v #\V) (values 'class #f (+ i 2)))
              ((#\b #\B #\A #\G #\z #\Z #\R #\X)
               (if inclass (illegal) (values 'atom #f (+ i 2))))
              ((#\k) (if inclass (illegal)
                         (begin (set! refs (+ refs 1)) (values 'ref #f (backref (+ i 2))))))
              ((#\Q #\E) (illegal))
              (else
               (if (jsc-latin-char? c)
                   (illegal)
                   (char (char->integer c) (+ i 2))))))))

    ;; ── character classes (Pattern.clazz / range) ──
    ;; One class member that is not [, && or ] → (values kind code next)
    (define (element j)
      (if (char=? (rf j) #\\)
          (escape j 'class)
          (values 'char (char->integer (rf j)) (+ j 1))))

    ;; [ at i → the index after its ]. `members` counts what the class holds
    ;; so far: a ] closes only a non-empty class, otherwise it is a member, and
    ;; an && with nothing on either side is the JVM's "Bad class syntax".
    (define (cclass i)
      (let* ((j (+ i 1))
             (j (if (and (< j n) (char=? (rf j) #\^)) (+ j 1) j)))
        (let loop ((j j) (members 0))
          (cond
            ((>= j n) (err "Unclosed character class" n -1))
            ((char=? (rf j) #\[) (loop (cclass j) (+ members 1)))
            ((and (char=? (rf j) #\&) (< (+ j 1) n) (char=? (rf (+ j 1)) #\&))
             (if (and (= members 0)
                      (or (>= (+ j 2) n) (memv (rf (+ j 2)) '(#\] #\&))))
                 (err "Bad class syntax" (+ j 1))
                 (loop (+ j 2) members)))
            ((char=? (rf j) #\])
             (if (> members 0) (+ j 1) (loop (+ j 1) 1)))
            (else
             (let-values (((kind code k) (element j)))
               (if (and (eq? kind 'char) (< k n) (char=? (rf k) #\-))
                   ;; a single unit followed by - : a range, unless the - is
                   ;; itself last, or before ] or a nested [ (then both are
                   ;; literal)
                   (cond
                     ((>= (+ k 1) n) (err "Illegal character range" n))
                     ((memv (rf (+ k 1)) '(#\] #\[)) (loop k (+ members 1)))
                     ((and (char=? (rf (+ k 1)) #\\) (< (+ k 2) n)
                           (memv (rf (+ k 2)) '(#\p #\P)))
                      ;; a \p cannot end a range; the JVM's escape() refuses it
                      (err "Illegal/unsupported escape sequence" (+ k 2)))
                     (else
                      (let-values (((kind2 code2 k2) (element (+ k 1))))
                        (if (or (not (eq? kind2 'char))
                                (and code code2 (< code2 code)))
                            (err "Illegal character range" (- k2 1))
                            (loop k2 (+ members 1))))))
                   (loop k (+ members 1)))))))))

    ;; ── groups (Pattern.group0) ──
    ;; ( at i → (values next quantifiable?): a flags-only (?i) is not an atom,
    ;; so a quantifier after it dangles.
    (define (group i)
      (define (body j)
        (let ((k (scan j #f)))
          (if (>= k n) (err "Unclosed group" n) (values (+ k 1) #t))))
      (cond
        ((>= (+ i 1) n) (err "Unclosed group" n))
        ((not (char=? (rf (+ i 1)) #\?)) (body (+ i 1)))
        ((>= (+ i 2) n) (err "Unknown inline modifier" n))
        (else
         (let ((c2 (rf (+ i 2))))
           (case c2
             ((#\: #\= #\! #\>) (body (+ i 3)))
             ((#\<)
              (if (and (< (+ i 3) n) (memv (rf (+ i 3)) '(#\= #\!)))
                  ;; a look-behind body must have a bounded length, which on the
                  ;; JDK (25) only a back-reference fails; the check runs
                  ;; before the group is known to be closed
                  (let* ((before refs) (k (scan (+ i 4) #f)))
                    (cond ((> refs before)
                           (err "Look-behind group does not have an obvious maximum length" k -1))
                          ((>= k n) (err "Unclosed group" n))
                          (else (values (+ k 1) #t))))
                  (let-values (((nm k) (groupname (+ i 3))))
                    (if (member nm seen)
                        (err (string-append "Named capturing group <" nm "> is already defined")
                             (- k 1))
                        (begin (set! seen (cons nm seen))
                               (body k))))))
             ((#\$ #\@) (err "Unknown group type" (+ i 2)))
             (else (flags (+ i 2))))))))

    ;; (?flags) or (?flags:body), j = the first flag. One - switches to the
    ;; flags being turned off; a second is not a flag.
    (define (flags j)
      (let loop ((k j) (minus #f))
        (cond ((>= k n) (err "Unknown inline modifier" n))
              ((memv (rf k) '(#\i #\m #\s #\d #\u #\x #\U #\c)) (loop (+ k 1) minus))
              ((and (char=? (rf k) #\-) (not minus)) (loop (+ k 1) #t))
              ((char=? (rf k) #\)) (values (+ k 1) #f))
              ((char=? (rf k) #\:)
               (let ((m (scan (+ k 1) #f)))
                 (if (>= m n) (err "Unclosed group" n) (values (+ m 1) #t))))
              (else (err "Unknown inline modifier" k)))))

    ;; {n}, {n,}, {n,m} at i → the index after the }
    (define (brace i)
      (let ((j (+ i 1)))
        (if (or (>= j n) (not (jsc-digit? (rf j))))
            (err "Illegal repetition" j)
            (let ((k (let loop ((k j))
                       (if (and (< k n) (jsc-digit? (rf k))) (loop (+ k 1)) k))))
              (cond
                ((>= k n) (err "Unclosed counted closure" n))
                ((char=? (rf k) #\}) (+ k 1))
                ((char=? (rf k) #\,)
                 (let ((m (let loop ((m (+ k 1)))
                            (if (and (< m n) (jsc-digit? (rf m))) (loop (+ m 1)) m))))
                   (cond
                     ((>= m n) (err "Unclosed counted closure" n))
                     ((not (char=? (rf m) #\})) (err "Unclosed counted closure" m))
                     ((and (> m (+ k 1))
                           (< (string->number (substring s (+ k 1) m))
                              (string->number (substring s j k))))
                      (err "Illegal repetition range" m))
                     (else (+ m 1)))))
                (else (err "Unclosed counted closure" k)))))))

    ;; ── sequences (Pattern.expr / sequence / closure) ──
    ;; From i to the end or, below the top, to the ) that closes the group.
    ;; `prev` says whether a quantifier has an atom to apply to.
    (define (scan i top?)
      (let loop ((i i) (prev #f))
        (if (>= i n)
            i
            (let ((c (rf i)))
              (case c
                ((#\)) (if top? (err "Unmatched closing ')'" i -1) i))
                ((#\\)
                 (let-values (((kind code k) (escape i (if top? 'top 'group))))
                   (loop k #t)))
                ((#\[) (loop (cclass i) #t))
                ((#\() (let-values (((k p) (group i))) (loop k p)))
                ((#\* #\+ #\?)
                 (if prev
                     (let ((k (+ i 1)))
                       (loop (if (and (< k n) (memv (rf k) '(#\? #\+))) (+ k 1) k) #f))
                     (err (string-append "Dangling meta character '" (string c) "'") i)))
                ((#\{)
                 (let ((k (brace i)))
                   (loop (if (and (< k n) (memv (rf k) '(#\? #\+))) (+ k 1) k) #f)))
                ((#\|) (loop (+ i 1) #f))
                (else (loop (+ i 1) #t)))))))

    (scan 0 #t))))

(define (java-pattern->sre source)
  (java-syntax-check source)
  (let ((source (apply-global-x source)))
    (let* ((len (string-length source)))
      (let-values (((opts start) (parse-leading-flags source 0 len)))
        (let-values (((sre _end) (parse-expr source start len opts 0)))
          (values sre
                  (let lp ((opts opts) (out '()))
                    (cond ((null? opts) (reverse out))
                          ((memq (car opts) '(case-insensitive single-line multi-line))
                           (lp (cdr opts) (cons (car opts) out)))
                          (else (lp (cdr opts) out))))))))))
;; ── parse-expr: alternation level (handles |) ─────────────────────────────────

(define (parse-expr src i end flags depth)
  (let loop ((i i) (alts '()))
    (let-values (((sre i) (parse-seq src i end flags depth #f)))
      (if (and (< i end) (char=? (string-ref src i) #\|))
          (loop (+ i 1) (cons sre alts))
          (values (if (null? alts) sre `(or ,@(reverse (cons sre alts)))) i)))))

;; ── parse-seq: concatenation ──────────────────────────────────────────────────

(define (parse-seq src i end flags depth stop-at-depth)
  (let loop ((i i) (parts '()))
    (if (>= i end)
        (values (seq->sre parts) i)
        (let ((c (string-ref src i)))
          (cond
           ((and (char=? c #\)) (or (not stop-at-depth) (= depth stop-at-depth)))
            (values (seq->sre parts) i))
           ((char=? c #\|)
            (values (seq->sre parts) i))
           (else
            (let-values (((atom i) (parse-atom src i end flags depth)))
              (loop i (cons atom parts)))))))))

(define (seq->sre parts)
  (cond ((null? parts) 'epsilon)
        ((null? (cdr parts)) (car parts))
        (else `(seq ,@(reverse parts)))))

;; ── parse-atom: single atom + optional quantifier ─────────────────────────────

(define (parse-atom src i end flags depth)
  (let ((c (string-ref src i)))
    (cond
     ((char=? c #\\)  (let-values (((esc i) (parse-escape src (+ i 1) end flags)))
                         (maybe-quantifier esc src i end flags depth)))
     ((char=? c #\[)  (let-values (((cc i) (parse-cc src i end flags)))
                         (maybe-quantifier cc src i end flags depth)))
     ((char=? c #\()  (let-values (((grp i) (parse-group src i end flags depth)))
                         (maybe-quantifier grp src i end flags depth)))
     ((char=? c #\.)  (maybe-quantifier (if (jr-flag? flags 'single-line) 'any (jr-dot-sre flags))
                                        src (+ i 1) end flags depth))
     ((char=? c #\^)  (maybe-quantifier (if (jr-flag? flags 'multi-line) (jr-bol-sre flags) 'bos)
                                        src (+ i 1) end flags depth))
     ((char=? c #\$)
      (maybe-quantifier
       (if (jr-flag? flags 'multi-line) (jr-eol-sre flags) (jr-final-eol-sre flags))
       src (+ i 1) end flags depth))
      ((char=? c #\{)
       ;; A {n,m} with no preceding atom: Java still validates it and rejects
       ;; a malformed one (min > max), but treats a well-formed brace as literal.
       (let-values (((q i2) (parse-bounded c src i end flags depth)))
         (maybe-quantifier c src (+ i 1) end flags depth)))
      (else (maybe-quantifier c src (+ i 1) end flags depth)))))

;; ── Quantifiers ───────────────────────────────────────────────────────────────

(define (maybe-quantifier atom src i end flags depth)
  (if (>= i end)
      (values atom i)
      (let ((c (string-ref src i)))
        (cond
         ((char=? c #\*)
          (let ((i1 (+ i 1)))
            (cond ((and (< i1 end) (char=? (string-ref src i1) #\?))
                   (values `(*? ,atom) (+ i1 1)))
                   ((and (< i1 end) (char=? (string-ref src i1) #\+))
                    (values `(atomic (* ,atom)) (+ i1 1)))
                  (else (values `(* ,atom) i1)))))
         ((char=? c #\+)
          (let ((i1 (+ i 1)))
            (cond ((and (< i1 end) (char=? (string-ref src i1) #\?))
                   (values `(**? 1 #f ,atom) (+ i1 1)))
                  ((and (< i1 end) (char=? (string-ref src i1) #\+))
                   (values `(atomic (+ ,atom)) (+ i1 1)))
                  (else (values `(+ ,atom) i1)))))
         ((char=? c #\?)
          (let ((i1 (+ i 1)))
            (cond ((and (< i1 end) (char=? (string-ref src i1) #\?))
                   (values `(?? ,atom) (+ i1 1)))
                  ((and (< i1 end) (char=? (string-ref src i1) #\+))
                   (values `(atomic (? ,atom)) (+ i1 1)))
                  (else (values `(? ,atom) i1)))))
         ((char=? c #\{) (parse-bounded atom src i end flags depth))
         (else (values atom i))))))

(define (parse-bounded atom src i end flags depth)
  (let ((cb (str-scan-char src #\} (+ i 1) end)))
    (if (not cb)
        (values atom i)
        (let* ((body (substring src (+ i 1) cb))
               (comma (str-scan-char body #\, 0 (string-length body)))
               (n (if comma
                      (let ((s (substring body 0 comma)))
                        (if (> (string-length s) 0) (string->number s) #f))
                      (string->number body)))
               ;; {n} is EXACTLY n, so its upper bound is n — not #f, which is
               ;; irregex's "no bound" and made every {n} behave as {n,}: \d{4}
               ;; matched all of "20260729", [0-9]{2} all of "1234", and
               ;; (?:%[0-9a-f]{2})+ ran past the last percent-escape. Only a comma
               ;; opens the bound: {n,} (nothing after it) is unbounded, {n,m} is m.
               (m (if comma
                      (let ((s (substring body (+ comma 1) (string-length body))))
                        (if (> (string-length s) 0) (string->number s) #f))
                      n))
               (j (+ cb 1))
               (lazy? (and (< j end) (char=? (string-ref src j) #\?)))
               (j (if lazy? (+ j 1) j))
               (poss? (and (< j end) (char=? (string-ref src j) #\+)))
               (j (if poss? (+ j 1) j)))
          (cond
           ((not n) (values atom i))
           ((and m (< m n))
            (error 'java-pattern->sre "quantifier min greater than max" src))
           (else
            (let ((base (if lazy?
                           `(**? ,n ,(or m #f) ,atom)
                           `(** ,n ,(or m #f) ,atom))))
              (values (if poss? `(atomic ,base) base) j))))))))

;; ── Escape sequences ──────────────────────────────────────────────────────────
;;
;; An escape means the same thing in a bare pattern and inside a character class
;; unless Java says otherwise, and there are exactly three places it does:
;;   \b        a word boundary outside a class, a COMPILE ERROR inside one
;;   \R        a linebreak outside a class, an error inside one
;;   \1..\9 \k back-references, legal only outside
;; Everything else — \d \D \w \W \s \S, \p \P, \a \e \t \n \r \f, \cX, octal, \x,
;; \u — is parse-escape-shared's job, and both callers fall through to it.
;;
;; This used to be two hand-kept copies and they HAD drifted: \a was in the
;; bare-pattern copy only, so [\a] matched the letter a instead of BEL, and \c
;; was in neither, so \cA matched the letter c. Add an escape here, not there,
;; and both contexts get it.
;;
;; A miss answers (values #f i) — the caller decides what an unknown escape is.
;; No real escape value is #f (they are chars, symbols and lists), so #f is an
;; unambiguous sentinel.
(define (parse-uxxxx src i end)
  (and (< (+ i 3) end)
       (hex-value (string-ref src i)) (hex-value (string-ref src (+ i 1)))
       (hex-value (string-ref src (+ i 2))) (hex-value (string-ref src (+ i 3)))
       (+ (* 4096 (hex-value (string-ref src i)))
          (* 256 (hex-value (string-ref src (+ i 1))))
          (* 16 (hex-value (string-ref src (+ i 2))))
          (hex-value (string-ref src (+ i 3))))))

;; Java's \h and \v (JDK 8+): horizontal whitespace is
;; [ \t\xA0\u1680\u180e\u2000-\u200a\u202f\u205f\u3000], vertical is
;; [\n\x0B\f\r\x85\u2028\u2029]. Both used to fall through to the literal
;; letter.
(define horizontal-ws-sre
  '(or #\space #\tab #\xA0 #\x1680 #\x180E (/ #\x2000 #\x200A) #\x202F #\x205F #\x3000))
(define vertical-ws-sre
  `(or #\newline ,(integer->char #x0B) ,(integer->char #x0C) #\return
       ,(integer->char #x85) ,(integer->char #x2028) ,(integer->char #x2029)))

(define (parse-escape-shared src i end flags)
  (let ((c (string-ref src i)))
    (case c
      ((#\d) (values 'numeric (+ i 1)))
      ((#\D) (values '(~ numeric) (+ i 1)))
      ((#\w) (values '(or alphanumeric #\_) (+ i 1)))
      ((#\W) (values '(~ (or alphanumeric #\_)) (+ i 1)))
      ((#\s) (values 'whitespace (+ i 1)))
      ((#\S) (values '(~ whitespace) (+ i 1)))
      ((#\h) (values horizontal-ws-sre (+ i 1)))
      ((#\H) (values `(~ ,horizontal-ws-sre) (+ i 1)))
      ((#\v) (values vertical-ws-sre (+ i 1)))
      ((#\V) (values `(~ ,vertical-ws-sre) (+ i 1)))
      ((#\p #\P) (parse-prop c src i end))
      ;; Two escapes the JVM compiles and jolt cannot build, refused as syntax
      ;; errors rather than matched as the literal letter (which is what an
      ;; unknown escape falls to below): \N{NAME} needs the Unicode name table,
      ;; \X the grapheme-cluster rules. known-divergences.edn carries both.
      ((#\N)
       (java-re-error "\\N{name} is unsupported on jolt (no Unicode character name table)" i))
      ((#\X)
       (java-re-error "\\X (extended grapheme cluster) is unsupported on jolt" i))
      ((#\e) (values (integer->char #x1B) (+ i 1)))
      ((#\t) (values #\tab (+ i 1)))
      ((#\n) (values #\newline (+ i 1)))
      ((#\r) (values #\return (+ i 1)))
      ((#\f) (values (integer->char #x0C) (+ i 1)))
      ((#\a) (values (integer->char #x07) (+ i 1)))
      ;; \cX is X xor 64 on the RAW next character — no case folding first, so
      ;; \ca is 97 xor 64 = 33, not \cA's 1. A dangling \c is a pattern error.
      ((#\c)
       (if (>= (+ i 1) end)
           (error 'java-pattern->sre "incomplete \\c escape" src)
           (values (integer->char
                     (bitwise-xor (char->integer (string-ref src (+ i 1))) 64))
                   (+ i 2))))
      ((#\0) (parse-octal-escape src i end))
      ((#\x)
       (if (and (< (+ i 1) end) (char=? (string-ref src (+ i 1)) #\{))
           (let ((close (str-scan-char src #\} (+ i 2) end)))
             (if close
                 (let ((v (parse-hex src (+ i 2) close)))
                   (values (integer->char v) (+ close 1)))
                 (values #\x i)))
           (if (and (< (+ i 2) end) (hex-value (string-ref src (+ i 1)))
                    (hex-value (string-ref src (+ i 2))))
               (let ((v (+ (* 16 (hex-value (string-ref src (+ i 1))))
                           (hex-value (string-ref src (+ i 2))))))
                 (values (integer->char v) (+ i 3)))
               (values #\x (+ i 1)))))
      ;; \uXXXX. The JVM reads a high surrogate followed by \u + a low surrogate
      ;; as the one supplementary code point they encode (Pattern.u()), which is
      ;; how a pattern spells an emoji in Java source. A lone surrogate is a
      ;; legal Java char but not a Chez one — a jolt string cannot hold it — so
      ;; it is refused (known-divergences.edn), not silently read as something
      ;; else.
      ((#\u)
       (let ((cp (parse-uxxxx src (+ i 1) end)))
         (if (not cp)
             (values #\u (+ i 1))
             (let ((cp2 (and (<= #xD800 cp) (<= cp #xDBFF)
                             (< (+ i 6) end)
                             (char=? (string-ref src (+ i 5)) #\\)
                             (char=? (string-ref src (+ i 6)) #\u)
                             (parse-uxxxx src (+ i 7) end))))
               (cond
                 ((and cp2 (<= #xDC00 cp2) (<= cp2 #xDFFF))
                  (values (integer->char (+ #x10000 (* (- cp #xD800) #x400) (- cp2 #xDC00)))
                          (+ i 11)))
                 ((and (<= #xD800 cp) (<= cp #xDFFF))
                  (java-re-error "a lone surrogate is unsupported on jolt (strings hold code points, not UTF-16 units)" (+ i 4)))
                 (else (values (integer->char cp) (+ i 5))))))))
      (else (values #f i)))))

;; Java-compatible octal: \0 then up to 3 octal digits, value <= 0377. i points
;; at the 0.
(define (parse-octal-escape src i end)
  (let ((d1 (and (< (+ i 1) end) (oct-value? (string-ref src (+ i 1)))
                 (oct-value (string-ref src (+ i 1))))))
    (if (not d1)
        (values (integer->char 0) (+ i 1))
        (let ((d2 (and (< (+ i 2) end) (oct-value? (string-ref src (+ i 2)))
                       (oct-value (string-ref src (+ i 2))))))
          (if (not d2)
              (values (integer->char d1) (+ i 2))
              (if (<= d1 3)
                  (let ((d3 (and (< (+ i 3) end) (oct-value? (string-ref src (+ i 3)))
                                 (oct-value (string-ref src (+ i 3))))))
                    (if d3
                        (values (integer->char (+ (* d1 64) (* d2 8) d3)) (+ i 4))
                        (values (integer->char (+ (* d1 8) d2)) (+ i 3))))
                  (values (integer->char (+ (* d1 8) d2)) (+ i 3))))))))

;; Java's \R: a CRLF PAIR as one unit, or any single linebreak character. The
;; pair has to lead the alternation or "\r\n" matches as two linebreaks.
(define linebreak-sre
  `(or (seq #\return #\newline)
       #\newline ,(integer->char #x0B) ,(integer->char #x0C) #\return
       ,(integer->char #x85) ,(integer->char #x2028) ,(integer->char #x2029)))

;; ── Line terminators for DOT / ^ / $ ──────────────────────────────────────────
;; Java's terminator set is \n, \r, \r\n, NEL (U+0085), LS (U+2028) and PS
;; (U+2029); the UNIX_LINES flag ((?d)) narrows it to \n alone. irregex's own
;; `nonl`, `bol` and `eol` carry the NARROW set and nothing else, so mapping onto
;; them applied UNIX_LINES unconditionally (#956): `.` matched across a \r, (?m)^
;; did not match after one, and `(?m)^(.*)$` over CRLF input captured the \r —
;; found in an HTTP header parser, where every value came back with one attached.
;;
;; The wide forms are assertions rather than irregex ops, which costs the
;; backtracking matcher for a pattern that anchors (non-multiline `$` already
;; cost it — it has always been a look-ahead). Two rules shape them, and both are
;; Java's: a CRLF is ONE terminator, so neither anchor may sit between the \r and
;; the \n; and multiline ^ does not match at the very end of input, which is what
;; its look-ahead for one more character says.
(define java-nel (integer->char #x85))
(define java-ls (integer->char #x2028))
(define java-ps (integer->char #x2029))

(define dot-sre-wide `(~ #\newline #\return ,java-nel ,java-ls ,java-ps))
;; Multiline ^ never matches at the very end of input — not even after a final
;; terminator, and not on empty input: java.util.regex's Caret returns false at
;; endIndex before it looks at anything else (Perl's rule, which it cites). So
;; every branch, the start-of-input one included, wants one more character.
(define bol-sre-wide
  `(seq (or bos
            (look-behind (or #\newline ,java-nel ,java-ls ,java-ps))
            (seq (look-behind #\return) (look-ahead (~ #\newline))))
        (look-ahead any)))
(define bol-sre-unix `(seq bol (look-ahead any)))
(define eol-sre-wide
  `(or eos
       (look-ahead (or #\return ,java-nel ,java-ls ,java-ps))
       (seq (or bos (look-behind (~ #\return))) (look-ahead #\newline))))
;; `$` outside MULTILINE, and \Z: end of input, or just before a FINAL terminator
;; — where a CRLF is one terminator, so the position between its halves is not
;; "before a final \n" (Dollar's "No match between \r\n").
(define final-eol-sre-wide
  `(look-ahead (or eos
                   (seq #\return (? #\newline) eos)
                   (seq (or ,java-nel ,java-ls ,java-ps) eos)
                   (seq (or bos (look-behind (~ #\return))) #\newline eos))))
(define final-eol-sre-unix `(look-ahead (or eos (seq #\newline eos))))

;; Where an anchor can be emitted as a PRIMITIVE instead — each of these
;; assertions is decidable from three code units, and paying for the general
;; look-around machinery at every candidate position is what made `$` 70x the JVM
;; (#1062).  The primitives are jolt's own SRE extension, and only the Chez host
;; teaches irregex about them: host/chez/java/regex-anchors.ss registers their
;; expansions (the SREs above, which is what every other irregex walker then
;; reads them as) and regex-anchor-sre.scm compiles them.  It calls
;; `jr-use-anchor-prims!` when it loads.
;;
;; The Gambit boot ##includes THIS file and the vendored irregex and nothing
;; else — its `load` of a host/chez path is a deliberate no-op (host/gambit/
;; boot.ss) — so there the flag stays off and the SREs are emitted, exactly as
;; before #1062.  A primitive emitted into an irregex that has never heard of it
;; is an "unknown regexp" at compile.
(define jr-anchor-prims? #f)
(define (jr-use-anchor-prims!) (set! jr-anchor-prims? #t))

;; Multiline `$` under UNIX_LINES needs no primitive either way: irregex's own
;; `eol` already means "before a \n, or at the end of input", which is what
;; `(or eol eos)` said with the redundancy spelled out.
(define (jr-dot-sre flags) (if (jr-flag? flags 'unix-lines) 'nonl dot-sre-wide))
(define (jr-bol-sre flags)
  (if (jr-flag? flags 'unix-lines)
      (if jr-anchor-prims? '%java-bol-unix bol-sre-unix)
      (if jr-anchor-prims? '%java-bol bol-sre-wide)))
(define (jr-eol-sre flags)
  (if (jr-flag? flags 'unix-lines) 'eol
      (if jr-anchor-prims? '%java-eol eol-sre-wide)))
(define (jr-final-eol-sre flags)
  (if (jr-flag? flags 'unix-lines)
      (if jr-anchor-prims? '%java-final-eol-unix final-eol-sre-unix)
      (if jr-anchor-prims? '%java-final-eol final-eol-sre-wide)))

(define (parse-escape src i end flags)
  (if (>= i end)
      (values #\\ i)
      (let ((c (string-ref src i)))
        (case c
          ((#\b) (values '(or bow eow) (+ i 1)))
          ((#\B) (values 'nwb (+ i 1)))
          ((#\A) (values 'bos (+ i 1)))
          ((#\Z) (values (jr-final-eol-sre flags) (+ i 1)))
          ((#\z) (values 'eos (+ i 1)))
          ((#\R) (values linebreak-sre (+ i 1)))
          ((#\Q)
           (let* ((eos-q (scan-qe src (+ i 1) end))
                  (end-q (or eos-q end))
                  (lit (substring src (+ i 1) end-q))
                  (len (string-length lit))
                  (idx (+ end-q (if eos-q 2 0)))
                  (quant? (and (< idx end)
                               (> len 1)
                               (memv (string-ref src idx)
                                     '(#\* #\+ #\? #\{)))))
             (if quant?
                 ;; Quantifier scopes only last char in Java
                 (let* ((prefix (substring lit 0 (- len 1)))
                        (last (string-ref lit (- len 1)))
                        (prefix-chars (map (lambda (i) (string-ref prefix i))
                                           (iota (string-length prefix)))))
                   (let-values (((qm-sre qm-idx) (maybe-quantifier last src idx end flags 0)))
                     (values `(seq ,@prefix-chars ,qm-sre) qm-idx)))
                 (values (make-lit lit) idx))))
          ((#\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
           (values `(backref ,(- (char->integer c) (char->integer #\0))) (+ i 1)))
          ((#\k)
           (if (and (< (+ i 1) end) (char=? (string-ref src (+ i 1)) #\<))
               (let ((gt (str-scan-char src #\> (+ i 2) end)))
                 (if (not gt)
                     (values #\k (+ i 1))
                     (let ((nm (string->symbol (substring src (+ i 2) gt))))
                       (values `(backref ,nm) (+ gt 1)))))
               (values #\k (+ i 1))))
          (else
           (let-values (((v j) (parse-escape-shared src i end flags)))
             (if v (values v j) (values c (+ i 1)))))))))

(define (parse-prop prefix src i end)
  ;; i points at p/P; next char is either { (braced) or property name (brace-less)
  (if (>= (+ i 1) end)
      (error 'java-pattern->sre "incomplete \\p or \\P escape" src)
      (if (char=? (string-ref src (+ i 1)) #\{)
          ;; Brace form: \p{Lu} — name between { and }
          (let ((close (str-scan-char src #\} (+ i 2) end)))
            (if (not close)
                (error 'java-pattern->sre "unterminated \\p{...} property" src)
                (let* ((name (substring src (+ i 2) close))
                       (sre (prop-class-sre name)))
                  (if sre
                      (values (if (char=? prefix #\P) `(~ ,sre) sre) (+ close 1))
                      (java-re-error (prop-unsupported-message name) close)))))
          ;; Brace-less: \pL — single char at i+1 is the property name
          (let* ((ch (string-ref src (+ i 1)))
                 (name (string ch))
                 (sre (prop-class-sre name)))
            (if sre
                (values (if (char=? prefix #\P) `(~ ,sre) sre) (+ i 2))
                (java-re-error (prop-unsupported-message name) (+ i 1)))))))

;; A \p name the validator let through is one the JVM knows (a script, a block,
;; a binary property jolt has no data for); say so rather than call it unknown.
(define (prop-unsupported-message name)
  (string-append "\\p{" name "} is unsupported on jolt (no Unicode "
                 (cond ((and (> (string-length name) 2) (string=? (substring name 0 2) "In")) "block")
                       ((and (> (string-length name) 2) (string=? (substring name 0 2) "Is")) "script or property")
                       (else "property"))
                 " table for it)"))

(define (parse-hex src start end)
  (let loop ((i start) (v 0))
    (if (>= i end) v
        (let ((h (hex-value (string-ref src i))))
          (if h (loop (+ i 1) (+ (* v 16) h)) v)))))

;; ── Character classes [...] ──────────────────────────────────────────────────

(define (parse-cc src i end flags)
  (let ((i1 (+ i 1)))
    (if (>= i1 end)
        (error 'java-pattern->sre "unterminated character class" src)
        (let ((negated? (and (char=? (string-ref src i1) #\^))))
          (let-values (((members i2)
                        (parse-cc-body src (if negated? (+ i1 1) i1) end flags #t)))
            (if (>= i2 end)
                (error 'java-pattern->sre "unterminated character class" src)
                (let ((result (cond ((null? members) 'epsilon)
                                    ((null? (cdr members)) (car members))
                                    (else `(or ,@members)))))
                  (values (if negated? `(~ ,result) result)
                          (+ i2 1)))))))))

(define (parse-cc-body src start end flags outer)
  (let loop ((i start) (members '()))
    (if (>= i end)
        (values (reverse members) i)
        (let ((c (string-ref src i)))
          (cond
           ((and outer (= i start) (char=? c #\]))
            (maybe-cc-range #\] src (+ i 1) end flags loop members))
           ((char=? c #\]) (values (reverse members) i))
           ;; nested char class [a-z&&[^b]] — parse the inner class as a member
           ((char=? c #\[)
            (let-values (((nested i2) (parse-cc src i end flags)))
              (loop i2 (cons nested members))))
           ;; intersection: a-z&&[^b]
            ((and (char=? c #\&) (< (+ i 1) end)
                  (char=? (string-ref src (+ i 1)) #\&))
             (when (and outer (null? members)
                        (< (+ i 2) end)
                        (memv (string-ref src (+ i 2)) '(#\& #\])))
               (error 'java-pattern->sre "bad class intersection syntax" src))
             (let-values (((nested i2) (parse-cc-body src (+ i 2) end flags #f)))
              (if (>= i2 end)
                  (error 'java-pattern->sre "unterminated class intersection" src)
                  (let ((prev (if (null? members) 'any (cc-members->sre (reverse members))))
                        (nested-sre (if (null? nested) 'any (cc-members->sre nested))))
                    (if (char=? (string-ref src i2) #\])
                        (values (list `(& ,prev ,nested-sre)) i2)
                        (loop (+ i2 1) (list `(& ,prev ,nested-sre))))))))
           ((char=? c #\\)
            (let-values (((atom i2) (parse-cc-escape src (+ i 1) end flags)))
              (maybe-cc-range atom src i2 end flags loop members)))
           (else
            (maybe-cc-range c src (+ i 1) end flags loop members)))))))

(define (cc-members->sre members)
  (cond ((null? members) 'epsilon)
        ((null? (cdr members)) (car members))
        (else `(or ,@members))))

;; A - after a member opens a range unless what follows is ] (the - is then a
;; literal) or a nested [ (the JVM's range() answers the single unit and the
;; - is a literal too: [a-[b]] is a, -, and the class b).
(define (maybe-cc-range atom src i end flags cont members)
  (if (and (< i end) (char=? (string-ref src i) #\-)
           (< (+ i 1) end)
           (not (memv (string-ref src (+ i 1)) '(#\] #\[))))
      (let ((i2 (+ i 1)))
        (let-values (((end-atom i3) (parse-cc-atom src i2 end flags)))
          (cond
           ((and (char? atom) (char? end-atom) (char>? atom end-atom))
            (error 'java-pattern->sre "range out of order in character class" src))
           ((and (char? atom) (char? end-atom))
            (cont i3 (cons `(/ ,atom ,end-atom) members)))
           (else (cont (+ i 1) (cons #\- (cons atom members)))))))
      (cont i (cons atom members))))

(define (parse-cc-atom src i end flags)
  (let ((c (string-ref src i)))
    (if (char=? c #\\)
        (parse-cc-escape src (+ i 1) end flags)
        (values c (+ i 1)))))

(define (parse-cc-escape src i end flags)
  (if (>= i end)
      (values #\\ i)
      (let ((c (string-ref src i)))
        (case c
          ;; The two Java rejects. A backspace for \b is PERL: java.util.regex
          ;; refuses the pattern, so refusing it here is the parity behaviour.
          ((#\b)
           (error 'java-pattern->sre "escape \\b not allowed in character class" src))
          ((#\R)
           (error 'java-pattern->sre "linebreak escape not allowed in character class" src))
          ;; \Q…\E inside a class contributes its characters as members, so the
          ;; bare-pattern copy's quantifier scoping does not apply here.
          ((#\Q)
           (let ((eos-q (scan-qe src (+ i 1) end)))
             (let* ((end-q (or eos-q end))
                    (lit (substring src (+ i 1) end-q)))
               (if (and eos-q (zero? (string-length lit)))
                   (error 'java-pattern->sre "empty quote escape in character class" src)
                   (values (make-lit lit) (+ end-q (if eos-q 2 0)))))))
          (else
           (let-values (((v j) (parse-escape-shared src i end flags)))
             (if v (values v j) (values c (+ i 1)))))))))

;; ── Groups ────────────────────────────────────────────────────────────────────

(define (parse-group src i end flags depth)
  (let ((i1 (+ i 1)))
    (if (>= i1 end)
        (java-re-error "Unclosed group" end)
        (let ((c1 (string-ref src i1)))
          (if (not (char=? c1 #\?))
              (parse-capturing-group src i1 end flags depth)
              (parse-special-group src (+ i1 1) end flags depth))))))

(define (parse-capturing-group src i end flags depth)
  (let-values (((sre i2) (parse-expr src i end flags (+ depth 1))))
    (if (and (< i2 end) (char=? (string-ref src i2) #\)))
        (values `(submatch ,sre) (+ i2 1))
        (java-re-error "Unclosed group" end))))

(define (parse-special-group src i end flags depth)
  (if (>= i end)
      (java-re-error "Unclosed group" end)
      (let ((c (string-ref src i)))
        (case c
          ((#\:)
           (let-values (((sre i2) (parse-expr src (+ i 1) end flags (+ depth 1))))
             (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                 (values sre (+ i2 1))
                 (java-re-error "Unclosed group" end))))
          ((#\=)
           (let-values (((sre i2) (parse-expr src (+ i 1) end flags (+ depth 1))))
             (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                 (values `(look-ahead ,sre) (+ i2 1))
                 (java-re-error "Unclosed group" end))))
          ((#\!)
           (let-values (((sre i2) (parse-expr src (+ i 1) end flags (+ depth 1))))
             (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                 (values `(neg-look-ahead ,sre) (+ i2 1))
                 (java-re-error "Unclosed group" end))))
          ((#\<)
           (if (>= (+ i 1) end)
               (java-re-error "Unclosed group" end)
               (let ((c2 (string-ref src (+ i 1))))
                 (case c2
                   ((#\=)
                    (let-values (((sre i2) (parse-expr src (+ i 2) end flags (+ depth 1))))
                      (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                          (values `(look-behind ,sre) (+ i2 1))
                          (java-re-error "Unclosed group" end))))
                   ((#\!)
                    (let-values (((sre i2) (parse-expr src (+ i 2) end flags (+ depth 1))))
                      (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                          (values `(neg-look-behind ,sre) (+ i2 1))
                          (java-re-error "Unclosed group" end))))
                   (else
                    (let ((gt (str-scan-char src #\> (+ i 1) end)))
                      (if (not gt)
                          (error 'java-pattern->sre "unterminated named group" src)
                          (let ((name (string->symbol (substring src (+ i 1) gt))))
                            (let-values (((sre i2) (parse-expr src (+ gt 1) end flags (+ depth 1))))
                              (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                                  (values `(=> ,name ,sre) (+ i2 1))
                                  (error 'java-pattern->sre "unterminated named group" src)))))))))))
          ((#\>)
           (let-values (((sre i2) (parse-expr src (+ i 1) end flags (+ depth 1))))
             (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                 (values `(atomic ,sre) (+ i2 1))
                 (java-re-error "Unclosed group" end))))
           ((#\c #\i #\s #\m #\x #\u #\U #\d #\- #\))
           (parse-inline-flags-group src i end flags depth))
          ((#\#)
           (let ((close (str-scan-char src #\) (+ i 1) end)))
             (if close
                 (values 'epsilon (+ close 1))
                 (error 'java-pattern->sre "unterminated comment" src))))
          (else
           (error 'java-pattern->sre "unknown (?… group type" src))))))

;; ── Inline flags: (?imsx-imsx:body) ─────────────────────────────────────────

(define (parse-inline-flags-group src i end flags depth)
  (let scan ((j i) (fs '()) (neg #f))
    (if (>= j end)
        (error 'java-pattern->sre "unterminated inline flags" src)
        (let ((c (string-ref src j)))
          (cond
           ((char=? c #\-) (scan (+ j 1) fs #t))
           ((char=? c #\i)
            (scan (+ j 1)
                  (cons (if neg 'case-sensitive 'case-insensitive) fs) neg))
           ((char=? c #\s)
            (scan (+ j 1)
                  (cons (if neg 'not-single-line 'single-line) fs) neg))
           ((char=? c #\m)
            (scan (+ j 1)
                  (cons (if neg 'not-multi-line 'multi-line) fs) neg))
           ((char=? c #\x)
            (scan (+ j 1)
                  (cons (if neg 'not-ignore-space 'ignore-space) fs) neg))
           ((char=? c #\d)
            (scan (+ j 1)
                  (cons (if neg 'not-unix-lines 'unix-lines) fs) neg))
            ;; u (UNICODE_CASE) and U (UNICODE_CHARACTER_CLASS): accept and
            ;; ignore — they don't change matching for our engine.
            ((memv c '(#\c #\u #\U))
             (scan (+ j 1) fs neg))
           ((char=? c #\:)
            (let ((new-flags (apply-inline-flags flags fs)))
              (let-values (((sre i2) (parse-expr src (+ j 1) end new-flags (+ depth 1))))
                (if (and (< i2 end) (char=? (string-ref src i2) #\)))
                    (values (wrap-case-flag sre fs) (+ i2 1))
                    (java-re-error "Unclosed group" end)))))
           ((char=? c #\))
            ;; Unscoped toggle (?i) — parse remainder with new flags
            (let ((new-flags (apply-inline-flags flags fs))
                  (k (+ j 1)))
              (let ((qc (and (< k end) (string-ref src k))))
                (cond
                 ((and qc (memv qc '(#\* #\+ #\?)))
                  (error 'java-pattern->sre "dangling quantifier after flag group" src))
                 ((and qc (char=? qc #\{))
                  (let-values (((qi i2) (parse-bounded 'epsilon src k end flags depth)))
                    (let-values (((sre i3) (parse-expr src i2 end new-flags (+ depth 1))))
                      (values (wrap-flags-sre sre fs) i3))))
                 (else
                  (let-values (((sre i2) (parse-expr src k end new-flags (+ depth 1))))
                    (values (wrap-flags-sre sre fs) i2)))))))
           (else
            (error 'java-pattern->sre "unrecognized inline flag" src)))))))

(define (apply-inline-flags flags fs)
  (let loop ((fs fs) (flags flags))
    (if (null? fs) flags
        (let ((f (car fs)))
          (cond
           ((eq? f 'case-sensitive) (loop (cdr fs) (remq 'case-insensitive flags)))
           ((eq? f 'not-single-line) (loop (cdr fs) (remq 'single-line flags)))
           ((eq? f 'not-multi-line) (loop (cdr fs) (remq 'multi-line flags)))
           ((eq? f 'not-ignore-space) (loop (cdr fs) (remq 'ignore-space flags)))
           ((eq? f 'not-unix-lines) (loop (cdr fs) (remq 'unix-lines flags)))
           (else (loop (cdr fs) (cons f flags))))))))

(define (wrap-case-flag sre fs)
  (cond
   ((memq 'case-insensitive fs) `(w/nocase ,sre))
   ((memq 'case-sensitive fs)   `(w/case ,sre))
   (else sre)))

(define (wrap-flags-sre sre fs)
  (let loop ((fs fs) (sre sre))
    (if (null? fs) sre
        (let ((f (car fs)))
          (cond
           ((eq? f 'case-insensitive) (loop (cdr fs) `(w/nocase ,sre)))
           ((eq? f 'case-sensitive)   (loop (cdr fs) `(w/case ,sre)))
           ((memq f '(not-single-line not-multi-line not-ignore-space not-unix-lines))
            (loop (cdr fs) sre))
           (else (loop (cdr fs) sre)))))))
