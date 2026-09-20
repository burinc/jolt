;; regex-anchors.ss — java.util.regex's line anchors as O(1) SRE primitives (#1062).
;;
;; Java's `^`, `$` and `\Z` are defined over a SIX-character terminator set (\n,
;; \r, \r\n, NEL, LS, PS), and `\r\n` is ONE terminator, so an anchor has to look
;; at the unit before the position as well as the one or two after it.  irregex has
;; no such assertion, so regex-translate.ss expressed each of them as an SRE built
;; from `look-ahead` and `look-behind` — correct, but every evaluation ran the
;; general look-around machinery, and a look-behind additionally wrapped the chunk
;; and re-entered the matcher.  #1062 measured `(re-find #"$" line)` at 70x the
;; JVM's cost for exactly that reason; bounding the look-behind rescan
;; (regex-anchor-sre.scm) removed the quadratic term but left the constant.
;;
;; Every one of those assertions is decidable from at most three code units — the
;; one before the position and the two after it — so each is written here as a
;; direct predicate and compiled by regex-anchor-sre.scm into a single zero-width
;; test.  The SREs they replace stay in regex-translate.ss and are registered below
;; as the primitives' `sre-named-definitions` expansions, so every OTHER irregex
;; walker (sre-length-ranges, sre->nfa, sre->cset) still sees the full semantics and
;; needs no teaching; only the matcher takes the short path.
;;
;; Loaded from regex.ss after irregex.scm (for sre-named-definitions and the
;; chunker accessors) and after regex-translate.ss (for the SREs and Java's
;; terminator characters).

;; The code unit K units past i, or #f when the input ends before it.  Walks the
;; chunker so a chunked source answers the same as a string; the k=0, in-chunk case
;; is every anchor's hot path and is read straight off the string.
(define (%java-ahead cnk src str i end k)
  (if (and (eqv? k 0) (< i end))
      (string-ref str i)
      (let lp ((src src) (str str) (i i) (end end) (k k))
        (cond
          ((< i end)
           (if (eqv? k 0) (string-ref str i) (lp src str (+ i 1) end (- k 1))))
          (else
           (let ((src2 ((chunker-get-next cnk) src)))
             (and src2
                  (lp src2 ((chunker-get-str cnk) src2)
                      ((chunker-get-start cnk) src2)
                      ((chunker-get-end cnk) src2)
                      k))))))))

;; The code unit before i, or #f at the search origin — the same read the vendored
;; `bol` arm makes, so "no previous unit" means `bos` here exactly as it does there.
(define (%java-prev cnk init src str i)
  (if (> i ((chunker-get-start cnk) src))
      (string-ref str (- i 1))
      (chunker-prev-char cnk init src)))

(define (%java-terminator-after? ch)
  (and ch (or (eqv? ch #\newline) (eqv? ch #\return)
              (eqv? ch java-nel) (eqv? ch java-ls) (eqv? ch java-ps))))

;; MULTILINE `$`, wide terminators — regex-translate.ss's eol-sre-wide.
;; End of input, or before a terminator, except BETWEEN a \r and its \n: a CRLF is
;; one terminator and no anchor may sit inside it.
(define (%java-eol? cnk init src str i end)
  (let ((c0 (%java-ahead cnk src str i end 0)))
    (cond
      ((not c0) #t)
      ((eqv? c0 #\newline)
       (let ((p (%java-prev cnk init src str i)))
         (not (eqv? p #\return))))
      (else (%java-terminator-after? c0)))))

;; MULTILINE `^`, wide terminators — regex-translate.ss's bol-sre-wide.
;; After a terminator (or at the origin) and NOT at the very end of input: Java's
;; Caret returns false at endIndex before it looks at anything, which the SRE says
;; as a trailing `(look-ahead any)`.  Inside a CRLF is not a line start either.
(define (%java-bol? cnk init src str i end)
  (and (%java-ahead cnk src str i end 0)
       (let ((p (%java-prev cnk init src str i)))
         (cond
           ((not p) #t)                   ; bos
           ((eqv? p #\return)
            (not (eqv? (%java-ahead cnk src str i end 0) #\newline)))
           (else (or (eqv? p #\newline) (eqv? p java-nel)
                     (eqv? p java-ls) (eqv? p java-ps)))))))

;; `$` outside MULTILINE, and `\Z`, wide terminators — final-eol-sre-wide.
;; End of input, or before the FINAL terminator; again a CRLF is one terminator, so
;; the position between its halves is not "before a final \n".
(define (%java-final-eol? cnk init src str i end)
  (let ((c0 (%java-ahead cnk src str i end 0)))
    (cond
      ((not c0) #t)
      ((eqv? c0 #\return)
       (let ((c1 (%java-ahead cnk src str i end 1)))
         (or (not c1)
             (and (eqv? c1 #\newline) (not (%java-ahead cnk src str i end 2))))))
      ((eqv? c0 #\newline)
       (and (not (%java-ahead cnk src str i end 1))
            (not (eqv? (%java-prev cnk init src str i) #\return))))
      ((or (eqv? c0 java-nel) (eqv? c0 java-ls) (eqv? c0 java-ps))
       (not (%java-ahead cnk src str i end 1)))
      (else #f))))

;; The UNIX_LINES ((?d)) forms, whose terminator set is \n alone.  Multiline `$` is
;; already irregex's own `eol`, so only these two need a primitive.
(define (%java-bol-unix? cnk init src str i end)
  (and (%java-ahead cnk src str i end 0)
       (let ((p (%java-prev cnk init src str i)))
         (or (not p) (eqv? p #\newline)))))

(define (%java-final-eol-unix? cnk init src str i end)
  (let ((c0 (%java-ahead cnk src str i end 0)))
    (or (not c0)
        (and (eqv? c0 #\newline) (not (%java-ahead cnk src str i end 1))))))

;; The primitive -> predicate table regex-anchor-sre.scm compiles against, and the
;; primitive -> SRE table the rest of irregex reads it through.  Both are keyed by
;; the same symbols; %java-anchor-sre? is what the matcher's zero-width check asks.
(define %java-anchor-procs
  (list (cons '%java-bol %java-bol?)
        (cons '%java-eol %java-eol?)
        (cons '%java-final-eol %java-final-eol?)
        (cons '%java-bol-unix %java-bol-unix?)
        (cons '%java-final-eol-unix %java-final-eol-unix?)))

(define (%java-anchor-proc sre) (cond ((assq sre %java-anchor-procs) => cdr) (else #f)))

;; ── Character classes as char SETS, not alternations (#1062) ──────────────────
;; java.util.regex's classes all reach irregex as `or`: the translator emits
;; `[a-z_]` as `(or (/ #\a #\z) #\_)`, `\w` as `(or alphanumeric #\_)`, and `\s` as
;; irregex's own `whitespace`, whose definition is another `or`.  irregex compiles
;; `(~ - & /)` into a char set but an `or` into a CHAIN of alternation closures,
;; each with its own failure continuation, so every class test walked the chain
;; instead of doing one binary search: `\s` cost ~70 ns per position where `[\s]`
;; written as a range cost ~26 ns, and #1062's per-line `\s`-anchored scans paid it
;; at every position of every line.
;;
;; An alternation of single code units is a char set — at one position at most one
;; branch can match, so there is nothing for leftmost-first order to decide, and no
;; branch can capture — and `sre->cset` already computes it.  This says when that
;; rewrite is legal.  It is deliberately narrow: a STRING leaf is refused, because
;; `sre->cset` widens "ab" to the set {a,b} while the matcher means the two-unit
;; sequence, and `w/case`/`w/nocase` are refused because the fold they ask for is
;; not the one `flags` carries at this point.
(define (%sre-cset-able? sre)
  (cond
    ((char? sre) #t)
    ((pair? sre)
     (and (memq (car sre) '(~ & - / or))
          (pair? (cdr sre))
          (let lp ((xs (cdr sre)))
            (or (null? xs)
                (and (if (eq? (car sre) '/) (char? (car xs)) (%sre-cset-able? (car xs)))
                     (lp (cdr xs)))))))
    ((symbol? sre)
     (let ((cell (assq sre sre-named-definitions)))
       (and cell (not (procedure? (cdr cell))) (%sre-cset-able? (cdr cell)))))
    (else #f)))

;; Zero-width, every one of them: a `*` or `+` over one is the "empty repetition"
;; irregex rejects, and it has to keep rejecting it — the vendored `sre-empty?`
;; answers #f for a symbol it does not know, which would compile `$*` into a loop
;; that never advances.  regex-anchor-sre.scm asks THIS instead.
(define (%sre-empty? sre)
  (if (pair? sre)
      (case (car sre)
        ((* ? look-ahead look-behind neg-look-ahead neg-look-behind) #t)
        ((**) (or (not (number? (cadr sre))) (zero? (cadr sre))))
        ((or) (let lp ((xs (cdr sre)))
                (and (pair? xs) (or (%sre-empty? (car xs)) (lp (cdr xs))))))
        ((: seq $ submatch => submatch-named + atomic)
         (let lp ((xs (cdr sre)))
           (or (null? xs) (and (%sre-empty? (car xs)) (lp (cdr xs))))))
        (else #f))
      (or (and (%java-anchor-proc sre) #t)
          (and (memq sre '(epsilon bos eos bol eol bow eow commit)) #t))))

;; Registering the expansions is what keeps the rest of irregex ignorant of these
;; symbols: sre-length-ranges ERRORS on an unknown one, and sre->nfa answers #f,
;; which would silently drop the DFA.  Each expansion still contains a look-around,
;; so sre->nfa declines exactly as it declined the SRE these replaced — the engine
;; choice for an anchored pattern is unchanged, only its matcher is faster.
(define sre-named-definitions
  (append (list (cons '%java-bol bol-sre-wide)
                (cons '%java-eol eol-sre-wide)
                (cons '%java-final-eol final-eol-sre-wide)
                (cons '%java-bol-unix bol-sre-unix)
                (cons '%java-final-eol-unix final-eol-sre-unix))
          sre-named-definitions))
