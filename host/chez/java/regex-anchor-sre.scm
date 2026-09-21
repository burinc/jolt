;; regex-anchor-sre.scm — O(1) look-behind for single-character anchors (jolt #1062).
;;
;; `sre->procedure` below is a verbatim copy of the vendored IrRegex definition
;; (vendor/irregex/irregex.scm), redefined globally so it wins over the vendored
;; one at load time.  The changes are marked "jolt #1062" and are these: the
;; `look-behind` arm gains an O(1) fast path for single-character bodies and a
;; width-bounded rescan for wider ones; the symbol arm gains the zero-width
;; `%look-behind-end` assertion that bounded rescan needs, and a direct compilation
;; of the java.util.regex line anchors (host/chez/java/regex-anchors.ss); and the
;; three "empty repetition" guards ask `%sre-empty?`, which knows those anchors are
;; zero-width, rather than the vendored `sre-empty?`, which does not.
;;
;; Why: the vendored `look-behind` compiles its body as `(* any) X eos` against a
;; chunk wrapped to end at the current position, so it rescans from the chunk
;; start to that position on every evaluation.  A one-character look-behind only
;; ever inspects the immediately preceding code unit, yet pays O(n) per position
;; and O(n^2) for a scan.  The java.util.regex `^`/`$`/`\A`/`\Z` anchors are built
;; from such look-behinds (host/chez/java/regex-translate.ss), so every anchor —
;; and every pattern containing one — was quadratic.
;;
;; Keep in sync with upstream by hand, exactly as host/chez/regex-dfa.ss redefines
;; the vendored `nfa->dfa`; host/chez/regex-dfa-check.sh is the same kind of hook.

;; The char set of a look-behind body when that body is a single character or a
;; char-set operator (`or`, `~`, `/`, `&`, `-`), else #f so the general path runs.
;; `flags` is threaded through so a case-insensitive match folds the body exactly
;; as the general path does.  `sre->cset` also accepts strings, but a multi-char
;; string is a sequence, not a single unit, so only the shapes above are admitted.
(define (%prev-char-cset sre flags)
  ;; A body is a one-unit look-behind only when it is a char, or a char-set
  ;; operator (~ & - / or) whose leaves are ALL chars.  A string leaf is
  ;; rejected outright: `sre->cset` maps a string to the set of its characters
  ;; (`(rec (list sre))` -> `string->cset`), so `(or "ab" "cd")` would wrongly
  ;; read as the single-unit set {a,b,c,d} and the fast path would misfire.
  (define (chars-only? x)
    (cond ((char? x) #t)
          ((and (pair? x) (memq (car x) '(~ & - / or)))
           (let loop ((xs (cdr x)))
             (or (null? xs) (and (chars-only? (car xs)) (loop (cdr xs))))))
          (else #f)))
  (and (chars-only? sre)
       (guard (e (#t #f)) (sre->cset sre (flag-set? flags ~case-insensitive?)))))

;; Set by the bounded look-behind rescan to the width it clamped to, so the
;; clock-free test (test/chez/regex-anchor-test.ss) can witness that the rescan
;; window is the body's own width and never grows with the input.  Never read by
;; matching code.
(define %look-behind-window 0)

;; jolt #1062 / drg-bba2: the target end position for the innermost look-behind
;; currently evaluating its body.  Bound around the body's evaluation so the
;; zero-width `%look-behind-end` assertion can pin the body's end back to i even
;; when the wrapped chunk was widened past i to let a nested look-around read.
(define %look-behind-target 0)

;; An UPPER BOUND, in code units, on how many units an SRE body can consume — or
;; #f when the body is unbounded or its width is not statically known.  A
;; look-behind body that spans at most K units cannot have begun more than K units
;; behind the current position, so the rescan below only has to start at (i - K)
;; instead of walking back to the chunk start; that walk was #1062's O(n) per
;; evaluation.
;;
;; The result is always a valid over-approximation (or #f, which disables the
;; bound), so it can never hide a match: `or` takes its widest branch, a bounded
;; quantifier its widest expansion, and any shape not modelled answers #f, leaving
;; the general rescan in place.
(define (%sre-max-length sre)
  (define (seq-max xs)
    (let loop ((xs xs) (tot 0))
      (cond ((null? xs) tot)
            (else (let ((m (%sre-max-length (car xs))))
                    (and m (loop (cdr xs) (+ tot m))))))))
  (cond
    ((char? sre) 1)
    ((string? sre) (string-length sre))
    ((symbol? sre)
     (case sre
       ((any nonl) 1)
       ((bos bol bow eos eol eow nwb epsilon) 0)
       ;; jolt #1062: the java.util.regex line-anchor primitives
       ;; (regex-anchors.ss) are zero-width assertions, exactly like `eos`
       ;; and `eol` above, and are bounded the same way.
       ((%java-bol %java-eol %java-final-eol
         %java-bol-unix %java-final-eol-unix) 0)
       (else #f)))
    ((pair? sre)
     (case (car sre)
       ((seq : atomic w/case w/nocase w/utf8 w/noutf8 word) (seq-max (cdr sre)))
       ((or) (let loop ((xs (cdr sre)) (best 0))
               (if (null? xs)
                   best
                   (let ((m (%sre-max-length (car xs))))
                     (and m (loop (cdr xs) (max best m)))))))
       ((~ & - / posix-string) 1)
       ((? ??) (%sre-max-length (cadr sre)))
       ((* *? + +? word+) #f)
       ((** **?) (let ((hi (caddr sre)))
                   (and (number? hi)
                        (let ((w (seq-max (cdddr sre))))
                          (and w (* hi w))))))
       ((=) (and (number? (cadr sre))
                 (let ((w (seq-max (cddr sre))))
                   (and w (* (cadr sre) w)))))
       ((>=) #f)
       ((look-ahead neg-look-ahead look-behind neg-look-behind) 0)
       (else #f)))
    (else #f)))

;; Forward reach of an SRE matched FORWARD from the current position: how far past
;; its start a match may read.  A look-around contributes the reach of its own
;; body.  #f means unbounded (or not modelled).  Bounds a nested look-ahead's body
;; so a look-behind can size the chunk it hands to that look-ahead (drg-bba2).
(define (%sre-forward-span sre)
  (define (seq-span xs)
    (let loop ((xs xs) (tot 0))
      (cond ((null? xs) tot)
            (else (let ((m (%sre-forward-span (car xs))))
                    (and m (loop (cdr xs) (+ tot m))))))))
  (cond
    ((char? sre) 1)
    ((string? sre) (string-length sre))
    ((symbol? sre)
     (case sre
       ((any nonl) 1)
       ((bos bol bow eos eol eow nwb epsilon) 0)
       ;; jolt #1062: the java.util.regex line-anchor primitives
       ;; (regex-anchors.ss) are zero-width assertions, exactly like `eos`
       ;; and `eol` above, and are bounded the same way.
       ((%java-bol %java-eol %java-final-eol
         %java-bol-unix %java-final-eol-unix) 0)
       (else #f)))
    ((pair? sre)
     (case (car sre)
       ((seq : atomic w/case w/nocase w/utf8 w/noutf8 word) (seq-span (cdr sre)))
       ((or) (let loop ((xs (cdr sre)) (best 0))
               (if (null? xs)
                   best
                   (let ((m (%sre-forward-span (car xs))))
                     (and m (loop (cdr xs) (max best m)))))))
       ((~ & - / posix-string) 1)
       ((? ??) (seq-span (cdr sre)))
       ((* *? + +? word+) #f)
       ((** **?) (let ((hi (caddr sre)))
                   (and (number? hi)
                        (let ((w (seq-span (cdddr sre))))
                          (and w (* hi w))))))
       ((=) (and (number? (cadr sre))
                 (let ((w (seq-span (cddr sre))))
                   (and w (* (cadr sre) w)))))
       ((>=) #f)
       ((look-ahead neg-look-ahead look-behind neg-look-behind)
        (%sre-forward-span (cadr sre)))
       (else #f)))
    (else #f)))

;; How far past i a forward-reading assertion in a look-behind body must be able
;; to see; see the symbol arm of %sre-lookbehind-ext below for why three.
(define %lookbehind-assertion-ext 3)

;; The extra forward reach a LOOK-BEHIND body needs PAST the position i at which it
;; must end: its consuming parts all end at or before i, so only a nested
;; look-AROUND reads past i.  This is the width to extend the wrapped chunk by so an
;; inner look-ahead can see the unit the outer tail matches; an explicit
;; `(= ext any)` re-anchors the body's end back to i (drg-bba2).  Always a valid
;; over-approximation -- or #f, which restores the plain full-chunk wrap.
(define (%sre-lookbehind-ext sre)
  (define (max-ext xs)
    (let loop ((xs xs) (best 0))
      (cond ((null? xs) best)
            (else (let ((m (%sre-lookbehind-ext (car xs))))
                    (and m (loop (cdr xs) (max best m))))))))
  (cond
    ((pair? sre)
     (case (car sre)
       ((=) (max-ext (cddr sre)))
       ((** **?) (max-ext (cdddr sre)))
       ((>=) #f)
       ((~ & - / posix-string) 0)
       ((look-ahead neg-look-ahead look-behind neg-look-behind)
        (%sre-forward-span (cadr sre)))
       ((seq : atomic w/case w/nocase w/utf8 w/noutf8 word or
         ? ?? * *? + +? word+) (max-ext (cdr sre)))
       (else #f)))
    ;; jolt-69q: an assertion that READS FORWARD from the position it is tested
    ;; at cannot be evaluated against a chunk wrapped to end at i — the wrap IS
    ;; the end of input as far as it can tell, so it answers about the wrap
    ;; instead of about the subject.  Whether i ends the input, ends a line, or
    ;; ends a word are all questions about what comes AFTER i:
    ;;
    ;;   (re-find #"(?<=a$)" "ab")   matched at 1, where the JVM does not
    ;;   (re-find #"(?<=a\b)" "ab")  likewise — eow saw the wrap, not the 'b'
    ;;   (re-find #"(?m)(?<=^)" "ab") found NOTHING, where the JVM finds 0:
    ;;     %java-bol is "...and not at the end of input", so the wrap made
    ;;     every position look like the end and the anchor declined them all
    ;;
    ;; A FINITE widening is enough, and #f (the whole chunk) is not needed: each of
    ;; these assertions only has to see a bounded distance past i to answer.  The
    ;; chunk is wrapped to min(i + ext, real end), so when the real input runs out
    ;; first the assertion is reading the true end, and when it does not the window
    ;; stays full — which is itself the answer, because a full window means more
    ;; input follows.  %look-behind-end then pins the body's own end back to i, so
    ;; the widening lets the assertion LOOK past i without letting the body MATCH
    ;; past it.
    ;;
    ;; Three is the widest any of them needs:
    ;;   \z, eos          1 — is there any unit after i at all
    ;;   bow, eow, nwb     1 — the character AT i (bow reads forward, despite the name)
    ;;   %java-bol         1 — Java's ^ is "...and not at the end of input"
    ;;   $, \Z            3 — "end of input, or before the FINAL line terminator".
    ;;                         The longest terminator is \r\n, two units, so a
    ;;                         still-full three-unit window cannot be a lone
    ;;                         terminator and the assertion correctly declines.
    ;;
    ;; Keeping it finite is the point: ext = #f would be correct too, but it hands
    ;; the body the whole chunk, and the (* any) prefix then runs to the end of the
    ;; input at every position — O(n^2) for a scan, which is exactly the cost #1062
    ;; exists to remove.  Measured over a 10k-unit subject: (?<=a$) scans in 1.8 ms
    ;; with the bounded window against 1582 ms with the whole chunk, and (?<=\b) in
    ;; 2.8 ms against 2814 ms.
    ;;
    ;; bos is the one assertion left at 0: \A is i = 0 and nothing else, a purely
    ;; backward question no wrap can affect.
    ((symbol? sre)
     (case sre
       ((eos eol eow nwb bow bol
         %java-bol %java-eol %java-final-eol
         %java-bol-unix %java-final-eol-unix) %lookbehind-assertion-ext)
       (else 0)))
    (else 0)))

;; The "word character" a word BOUNDARY is a boundary between.  java.util.regex
;; defines \b in terms of \w, which is [a-zA-Z0-9_], and regex-translate.ss
;; already spells \w as (or alphanumeric #\_) for exactly that reason.  irregex's
;; char-alphanumeric? leaves the underscore out -- its own (word ...) SRE adds it
;; back by hand, which is the tell -- so bow/eow/nwb disagreed with the \w sitting
;; beside them in the same pattern: (re-seq #"\b" "a_b") was (0 1 2 3), splitting
;; the identifier at its underscore, against the JVM's (0 3).  jolt-406.
(define (%word-char? c) (or (char-alphanumeric? c) (eqv? c #\_)))

(define (sre->procedure sre . o)
  (define names
    (if (and (pair? o) (pair? (cdr o))) (cadr o) (sre-names sre 1 '())))
  (let lp ((sre sre)
           (n 1)
           (flags (if (pair? o) (car o) ~none))
           (next (lambda (cnk init src str i end matches fail)
                   (irregex-match-start-chunk-set! matches 0 (car init))
                   (irregex-match-start-index-set! matches 0 (cdr init))
                   (irregex-match-end-chunk-set! matches 0 src)
                   (irregex-match-end-index-set! matches 0 i)
                   (%irregex-match-fail-set! matches fail)
                   matches)))
    ;; XXXX this should be inlined
    (define (rec sre) (lp sre n flags next))
    (cond
     ((pair? sre)
      (if (string? (car sre))
          (sre-cset->procedure
           (sre->cset (car sre) (flag-set? flags ~case-insensitive?))
           next)
          (case (car sre)
            ((~ - & /)
             (sre-cset->procedure
              (sre->cset sre (flag-set? flags ~case-insensitive?))
              next))
            ((or)
             ;; jolt #1062: an alternation of single code units is a char SET, and
             ;; one binary search beats a chain of alternation closures — which is
             ;; how every java.util.regex character class arrives here (`[a-z_]`,
             ;; `\w`, `\s` are all `or`).  regex-anchors.ss says when the rewrite
             ;; is legal; when it is not, the vendored alternation below runs.
             (if (%sre-cset-able? sre)
                 (sre-cset->procedure
                  (sre->cset sre (flag-set? flags ~case-insensitive?))
                  next)
             (case (length (cdr sre))
               ((0) (lambda (cnk init src str i end matches fail) (fail)))
               ((1) (rec (cadr sre)))
               (else
                (let* ((first (rec (cadr sre)))
                       (rest (lp (sre-alternate (cddr sre))
                                 (+ n (sre-count-submatches (cadr sre)))
                                 flags
                                 next)))
                  (lambda (cnk init src str i end matches fail)
                    (first cnk init src str i end matches
                           (lambda ()
                             (rest cnk init src str i end matches fail)))))))))
            ((w/case)
             (lp (sre-sequence (cdr sre))
                 n
                 (flag-clear flags ~case-insensitive?)
                 next))
            ((w/nocase)
             (lp (sre-sequence (cdr sre))
                 n
                 (flag-join flags ~case-insensitive?)
                 next))
            ((w/utf8)
             (lp (sre-sequence (cdr sre)) n (flag-join flags ~utf8?) next))
            ((w/noutf8)
             (lp (sre-sequence (cdr sre)) n (flag-clear flags ~utf8?) next))
            ((seq :)
             (case (length (cdr sre))
               ((0) next)
               ((1) (rec (cadr sre)))
               (else
                (let ((rest (lp (sre-sequence (cddr sre))
                                (+ n (sre-count-submatches (cadr sre)))
                                flags
                                next)))
                  (lp (cadr sre) n flags rest)))))
            ((?)
             (let ((body (rec (sre-sequence (cdr sre)))))
               (lambda (cnk init src str i end matches fail)
                 (body cnk init src str i end matches
                       (lambda () (next cnk init src str i end matches fail))))))
            ((??)
             (let ((body (rec (sre-sequence (cdr sre)))))
               (lambda (cnk init src str i end matches fail)
                 (next cnk init src str i end matches
                       (lambda () (body cnk init src str i end matches fail))))))
            ((*)
             (cond
              ((%sre-empty? (sre-sequence (cdr sre)))
               (error "invalid sre: empty *" sre))
              (else
               (let ((body (rec (list '+ (sre-sequence (cdr sre))))))
                 (lambda (cnk init src str i end matches fail)
                   (body cnk init src str i end matches
                         (lambda ()
                           (next cnk init src str i end matches fail))))))))
            ((*?)
             (cond
              ((%sre-empty? (sre-sequence (cdr sre)))
               (error "invalid sre: empty *?" sre))
              (else
               (letrec
                   ((body
                     (lp (sre-sequence (cdr sre))
                         n
                         flags
                         (lambda (cnk init src str i end matches fail)
                           (next cnk init src str i end matches
                                 (lambda ()
                                   (body cnk init src str i end matches fail)
                                   ))))))
                 (lambda (cnk init src str i end matches fail)
                   (next cnk init src str i end matches
                         (lambda ()
                           (body cnk init src str i end matches fail))))))))
            ((+)
             (cond
              ((%sre-empty? (sre-sequence (cdr sre)))
               (error "invalid sre: empty +" sre))
              (else
               (letrec
                   ((body
                     (lp (sre-sequence (cdr sre))
                         n
                         flags
                         (lambda (cnk init src str i end matches fail)
                           (body cnk init src str i end matches
                                 (lambda ()
                                   (next cnk init src str i end matches fail)
                                   ))))))
                 body))))
            ((=)
             (rec `(** ,(cadr sre) ,(cadr sre) ,@(cddr sre))))
            ((>=)
             (rec `(** ,(cadr sre) #f ,@(cddr sre))))
            ((**)
             (cond
              ((or (and (number? (cadr sre))
                        (number? (caddr sre))
                        (> (cadr sre) (caddr sre)))
                   (and (not (cadr sre)) (caddr sre)))
               (lambda (cnk init src str i end matches fail) (fail)))
              (else
               (letrec
                   ((from (cadr sre))
                    (to (caddr sre))
                    (body-contents (sre-sequence (cdddr sre)))
                    (body
                     (lambda (count)
                       (lp body-contents
                           n
                           flags
                           (lambda (cnk init src str i end matches fail)
                             (if (and to (= count to))
                                 (next cnk init src str i end matches fail)
                                 ((body (+ 1 count))
                                  cnk init src str i end matches
                                  (lambda ()
                                    (if (>= count from)
                                        (next cnk init src str i end matches fail)
                                        (fail))))))))))
                 (if (and (zero? from) to (zero? to))
                     next
                     (lambda (cnk init src str i end matches fail)
                       ((body 1) cnk init src str i end matches
                        (lambda ()
                          (if (zero? from)
                              (next cnk init src str i end matches fail)
                              (fail))))))))))
            ((**?)
             (cond
              ((or (and (number? (cadr sre))
                        (number? (caddr sre))
                        (> (cadr sre) (caddr sre)))
                   (and (not (cadr sre)) (caddr sre)))
               (lambda (cnk init src str i end matches fail) (fail)))
              (else
               (letrec
                   ((from (cadr sre))
                    (to (caddr sre))
                    (body-contents (sre-sequence (cdddr sre)))
                    (body
                     (lambda (count)
                       (lp body-contents
                           n
                           flags
                           (lambda (cnk init src str i end matches fail)
                             (if (< count from)
                                 ((body (+ 1 count)) cnk init
                                  src str i end matches fail)
                                 (next cnk init src str i end matches
                                       (lambda ()
                                         (if (and to (= count to))
                                             (fail)
                                             ((body (+ 1 count)) cnk init
                                              src str i end matches fail))))))))))
                 (if (and (zero? from) to (zero? to))
                     next
                     (lambda (cnk init src str i end matches fail)
                       (if (zero? from)
                           (next cnk init src str i end matches
                                 (lambda ()
                                   ((body 1) cnk init src str i end matches fail)))
                           ((body 1) cnk init src str i end matches fail))))))))
            ((word)
             (rec `(seq bow ,@(cdr sre) eow)))
            ((word+)
             (rec `(seq bow (+ (& (or alphanumeric "_")
                                  (or ,@(cdr sre)))) eow)))
            ((posix-string)
             (rec (string->sre (cadr sre))))
            ((look-ahead)
             (let ((check
                    (lp (sre-sequence (cdr sre))
                        n
                        flags
                        (lambda (cnk init src str i end matches fail) i))))
               (lambda (cnk init src str i end matches fail)
                 (if (check cnk init src str i end matches (lambda () #f))
                     (next cnk init src str i end matches fail)
                     (fail)))))
            ((neg-look-ahead)
             (let ((check
                    (lp (sre-sequence (cdr sre))
                        n
                        flags
                        (lambda (cnk init src str i end matches fail) i))))
               (lambda (cnk init src str i end matches fail)
                 (if (check cnk init src str i end matches (lambda () #f))
                     (fail)
                     (next cnk init src str i end matches fail)))))
             ((look-behind neg-look-behind)
              ;; jolt #1062: a look-behind only inspects the units just before
              ;; the current position.  A single-unit body is tested directly
              ;; (O(1)); a body of bounded width K begins its rescan at (i - K)
              ;; instead of re-running (`(* any)` X eos) from the chunk start
              ;; (O(position)).  A body of unknown width keeps the general path.
              (cond
                ((and (pair? (cdr sre)) (null? (cddr sre)) (%prev-char-cset (cadr sre) flags))
                 (let ((pos? (eq? (car sre) 'look-behind))
                       (cs (%prev-char-cset (cadr sre) flags)))
                   (lambda (cnk init src str i end matches fail)
                     (let ((ch (if (> i ((chunker-get-start cnk) src))
                                   (string-ref str (- i 1))
                                   (chunker-prev-char cnk init src))))
                       (if (eq? pos? (and ch (cset-contains? cs ch)))
                           (next cnk init src str i end matches fail)
                           (fail))))))
                (else
                  ;; jolt #1062 / drg-bba2: a look-behind only inspects the units
                  ;; just before the current position.  Compile the body to end AT
                  ;; i via `(* any) BODY <end>`, and rescan back no farther than
                  ;; the body's width K.  When the body nests a look-around it may
                  ;; legitimately read PAST i, so widen the wrapped chunk to
                  ;; i + EXT and terminate the body with the zero-width
                  ;; `%look-behind-end` assertion instead of `eos`: it pins the
                  ;; body's end back to i without consuming, so it never demands
                  ;; characters that need not exist.  EXT is #f when the inner
                  ;; reach is unbounded, in which case the body gets the whole
                  ;; chunk (correct, but O(position) to rescan).
                  (let* ((ext (%sre-lookbehind-ext (cadr sre)))
                         (maxlen (%sre-max-length (cadr sre)))
                         (pin? (not (and (number? ext) (= ext 0))))
                         (suffix (if pin?
                                     (append (cdr sre) (list '%look-behind-end))
                                     (append (cdr sre) '(eos))))
                         (check
                          (lp (sre-sequence (cons '(* any) suffix))
                              n
                              flags
                              (lambda (cnk init src str i end matches fail) i))))
                    (lambda (cnk init src str i end matches fail)
                      ;; A body of bounded width K cannot have begun more than K
                      ;; units back, so begin the rescan at (i - K).  Unknown
                      ;; width, or a scan that began in an earlier chunk: keep the
                      ;; general rescan from the chunk start.
                      (let ((i* (if (and maxlen (eq? (car init) src))
                                    (max (cdr init) (- i maxlen))
                                    (cdr init))))
                        (if (and maxlen (eq? (car init) src)
                                 (> (- i (cdr init)) maxlen))
                            (set! %look-behind-window maxlen))
                        (let* ((cnk* (cond ((eq? ext #f) cnk)
                                           ((> ext 0)
                                            (wrap-end-chunker
                                             cnk src
                                             (min (+ i ext)
                                                  ((chunker-get-end cnk) src))))
                                           (else (wrap-end-chunker cnk src i))))
                               (str* ((chunker-get-str cnk*) (car init)))
                               (end* ((chunker-get-end cnk*) (car init)))
                               (saved %look-behind-target)
                               (ok (begin
                                     (set! %look-behind-target i)
                                     ((if (eq? (car sre) 'look-behind)
                                          (lambda (x) x) not)
                                      (check cnk* init (car init) str* i* end*
                                             matches (lambda () #f))))))
                          (set! %look-behind-target saved)
                          (if ok
                              (next cnk init src str i end matches fail)
                              (fail)))))))))
            ((atomic)
             (let ((once
                    (lp (sre-sequence (cdr sre))
                        n
                        flags
                        (lambda (cnk init src str i end matches fail) i))))
               (lambda (cnk init src str i end matches fail)
                 (let ((j (once cnk init src str i end matches (lambda () #f))))
                   (if j
                       (next cnk init src str j end matches fail)
                       (fail))))))
            ((if)
             (let* ((test-submatches (sre-count-submatches (cadr sre)))
                    (pass (lp (caddr sre) flags (+ n test-submatches) next))
                    (fail (if (pair? (cdddr sre))
                              (lp (cadddr sre)
                                  (+ n test-submatches
                                     (sre-count-submatches (caddr sre)))
                                  flags
                                  next)
                              (lambda (cnk init src str i end matches fail)
                                (fail)))))
               (cond
                ((or (number? (cadr sre)) (symbol? (cadr sre)))
                 (let ((index
                        (if (symbol? (cadr sre))
                            (cond
                             ((assq (cadr sre) names) => cdr)
                             (else
                              (error "unknown named backref in SRE IF" sre)))
                            (cadr sre))))
                   (lambda (cnk init src str i end matches fail2)
                     (if (%irregex-match-end-chunk matches index)
                         (pass cnk init src str i end matches fail2)
                         (fail cnk init src str i end matches fail2)))))
                (else
                 (let ((test (lp (cadr sre) n flags pass)))
                   (lambda (cnk init src str i end matches fail2)
                     (test cnk init src str i end matches
                           (lambda () (fail cnk init src str i end matches fail2)))
                     ))))))
            ((backref backref-ci)
             (let ((n (cond ((number? (cadr sre)) (cadr sre))
                            ((assq (cadr sre) names) => cdr)
                            (else (error "unknown backreference" (cadr sre)))))
                   (compare (if (or (eq? (car sre) 'backref-ci)
                                    (flag-set? flags ~case-insensitive?))
                                string-ci=?
                                string=?)))
               (lambda (cnk init src str i end matches fail)
                 (let ((s (irregex-match-substring matches n)))
                   (if (not s)
                       (fail)
                       ;; XXXX create an abstract subchunk-compare
                       (let lp ((src src)
                                (str str)
                                (i i)
                                (end end)
                                (j 0)
                                (len (string-length s)))
                         (cond
                          ((<= len (- end i))
                           (cond
                            ((compare (substring s j (string-length s))
                                      (substring str i (+ i len)))
                             (next cnk init src str (+ i len) end matches fail))
                            (else
                             (fail))))
                          (else
                           (cond
                            ((compare (substring s j (+ j (- end i)))
                                      (substring str i end))
                             (let ((src2 ((chunker-get-next cnk) src)))
                               (if src2
                                   (lp src2
                                       ((chunker-get-str cnk) src2)
                                       ((chunker-get-start cnk) src2)
                                       ((chunker-get-end cnk) src2)
                                       (+ j (- end i))
                                       (- len (- end i)))
                                   (fail))))
                            (else
                             (fail)))))))))))
            ((dsm)
             (lp (sre-sequence (cdddr sre)) (+ n (cadr sre)) flags next))
            (($ submatch)
             (let ((body
                    (lp (sre-sequence (cdr sre))
                        (+ n 1)
                        flags
                        (lambda (cnk init src str i end matches fail)
                          (let ((old-source
                                 (%irregex-match-end-chunk matches n))
                                (old-index
                                 (%irregex-match-end-index matches n)))
                            (irregex-match-end-chunk-set! matches n src)
                            (irregex-match-end-index-set! matches n i)
                            (next cnk init src str i end matches
                                  (lambda ()
                                    (irregex-match-end-chunk-set!
                                     matches n old-source)
                                    (irregex-match-end-index-set!
                                     matches n old-index)
                                    (fail))))))))
               (lambda (cnk init src str i end matches fail)
                 (let ((old-source (%irregex-match-start-chunk matches n))
                       (old-index (%irregex-match-start-index matches n)))
                   (irregex-match-start-chunk-set! matches n src)
                   (irregex-match-start-index-set! matches n i)
                   (body cnk init src str i end matches
                         (lambda ()
                           (irregex-match-start-chunk-set!
                            matches n old-source)
                           (irregex-match-start-index-set!
                            matches n old-index)
                           (fail)))))))
            ((=> submatch-named)
             (rec `(submatch ,@(cddr sre))))
            (else
             (error "unknown regexp operator" sre)))))
     ((symbol? sre)
      (case sre
        ((any)
         (lambda (cnk init src str i end matches fail)
           (if (< i end)
               (next cnk init src str (+ i 1) end matches fail)
               (let ((src2 ((chunker-get-next cnk) src)))
                 (if src2
                     (let ((str2 ((chunker-get-str cnk) src2))
                           (i2 ((chunker-get-start cnk) src2))
                           (end2 ((chunker-get-end cnk) src2)))
                       (next cnk init src2 str2 (+ i2 1) end2 matches fail))
                     (fail))))))
        ((nonl)
         (lambda (cnk init src str i end matches fail)
           (if (< i end)
               (if (not (eqv? #\newline (string-ref str i)))
                   (next cnk init src str (+ i 1) end matches fail)
                   (fail))
               (let ((src2 ((chunker-get-next cnk) src)))
                 (if src2
                     (let ((str2 ((chunker-get-str cnk) src2))
                           (i2 ((chunker-get-start cnk) src2))
                           (end2 ((chunker-get-end cnk) src2)))
                       (if (not (eqv? #\newline (string-ref str2 i2)))
                           (next cnk init src2 str2 (+ i2 1) end2 matches fail)
                           (fail)))
                     (fail))))))
        ((bos)
         (lambda (cnk init src str i end matches fail)
           (if (and (eq? src (car init)) (eqv? i (cdr init)))
               (next cnk init src str i end matches fail)
               (fail))))
        ((bol)
         (lambda (cnk init src str i end matches fail)
           (if (let ((ch (if (> i ((chunker-get-start cnk) src))
                             (string-ref str (- i 1))
                             (chunker-prev-char cnk init src))))
                 (or (not ch) (eqv? #\newline ch)))
               (next cnk init src str i end matches fail)
               (fail))))
        ((bow)
         (lambda (cnk init src str i end matches fail)
           (if (and (if (> i ((chunker-get-start cnk) src))
                        (not (%word-char? (string-ref str (- i 1))))
                        (let ((ch (chunker-prev-char cnk init src)))
                          (or (not ch) (not (%word-char? ch)))))
                    (if (< i end)
                        (%word-char? (string-ref str i))
                        (let ((next ((chunker-get-next cnk) src)))
                          (and next
                               (%word-char?
                                (string-ref ((chunker-get-str cnk) next)
                                            ((chunker-get-start cnk) next)))))))
               (next cnk init src str i end matches fail)
               (fail))))
        ((eos)
         (lambda (cnk init src str i end matches fail)
           (if (and (>= i end) (not ((chunker-get-next cnk) src)))
               (next cnk init src str i end matches fail)
               (fail))))
        ((eol)
         (lambda (cnk init src str i end matches fail)
           (if (if (< i end)
                   (eqv? #\newline (string-ref str i))
                   (let ((src2 ((chunker-get-next cnk) src)))
                     (if (not src2)
                         #t
                         (eqv? #\newline
                               (string-ref ((chunker-get-str cnk) src2)
                                           ((chunker-get-start cnk) src2))))))
               (next cnk init src str i end matches fail)
               (fail))))
        ((eow)
         (lambda (cnk init src str i end matches fail)
           (if (and (if (< i end)
                        (not (%word-char? (string-ref str i)))
                        (let ((ch (chunker-next-char cnk src)))
                          (or (not ch) (not (%word-char? ch)))))
                    (if (> i ((chunker-get-start cnk) src))
                        (%word-char? (string-ref str (- i 1)))
                        ;; jolt-406: `(or (not prev) ...)` here read the ABSENCE of
                        ;; a preceding character as a word character, so every
                        ;; subject beginning with a non-word character reported a
                        ;; word ending at position 0 — (re-seq #"\b" " ab") was
                        ;; (0 1 3) against the JVM's (1 3).  There is no word
                        ;; before the start of input, so there is nothing for one
                        ;; to end.
                        (let ((prev (chunker-prev-char cnk init src)))
                          (and prev (%word-char? prev)))))
               (next cnk init src str i end matches fail)
               (fail))))
        ((nwb)  ;; non-word-boundary
         (lambda (cnk init src str i end matches fail)
           (let ((c1 (if (< i end)
                         (string-ref str i)
                         (chunker-next-char cnk src)))
                 (c2 (if (> i ((chunker-get-start cnk) src))
                         (string-ref str (- i 1))
                         (chunker-prev-char cnk init src))))
             ;; jolt-406: \B is the complement of \b, so it must answer for the
             ;; positions at the very edges too — and there it has only one
             ;; neighbour.  The old `(and c1 c2 ...)` failed outright whenever a
             ;; neighbour was missing, which made \B unmatchable at position 0 and
             ;; at the end of input: (re-seq #"\B" "ab ") was (1) against the
             ;; JVM's (1 3).  The edge of the input is not a word character, it is
             ;; the absence of one, which is exactly how a non-word character
             ;; behaves for this test — so treat a missing neighbour as non-word
             ;; and ask the real question: do both sides have the SAME wordness?
             ;; If they do there is no transition here, which is what \B means.
             (let ((w1 (and c1 (%word-char? c1)))
                   (w2 (and c2 (%word-char? c2))))
               (if (eq? w1 w2)
                   (next cnk init src str i end matches fail)
                   (fail))))))
        ((epsilon)
         next)
        ((%look-behind-end)
         ;; jolt #1062 / drg-bba2: zero-width assertion that succeeds only when the
         ;; current position equals the look-behind's target end.  The target is
         ;; set around the body's evaluation (%look-behind-target), letting a
         ;; look-behind body's end be pinned to i while its chunk is widened past i
         ;; so a nested look-around can read there.
         (lambda (cnk init src str i end matches fail)
           (if (= i %look-behind-target)
               (next cnk init src str i end matches fail)
               (fail))))
        (else
         ;; jolt #1062: java.util.regex's line anchors (host/chez/java/
         ;; regex-anchors.ss).  Each is decidable from the unit before the position
         ;; and the two after it, so it compiles to ONE zero-width test rather than
         ;; the look-around SRE it is registered as.  This arm has to precede the
         ;; sre-named-definitions lookup below, which would expand it back into
         ;; that SRE — which is exactly what every other irregex walker wants, and
         ;; what the matcher must not do.
         (cond
           ((%java-anchor-proc sre)
            => (lambda (anchor?)
                 (lambda (cnk init src str i end matches fail)
                   (if (anchor? cnk init src str i end)
                       (next cnk init src str i end matches fail)
                       (fail)))))
           ;; …and a named class (`whitespace`, `alphanumeric`, `punctuation`, …)
           ;; whose definition is an alternation of units folds to a char set for
           ;; the same reason the `or` arm above does; expanding it first would
           ;; hand the alternation chain back.
           ((%sre-cset-able? sre)
            (sre-cset->procedure
             (sre->cset sre (flag-set? flags ~case-insensitive?))
             next))
           ((assq sre sre-named-definitions) => (lambda (cell) (rec (cdr cell))))
           (else (error "unknown regexp" sre))))))
     ((char? sre)
      (if (flag-set? flags ~case-insensitive?)
          ;; case-insensitive
          (lambda (cnk init src str i end matches fail)
            (if (>= i end)
                (let lp ((src2 ((chunker-get-next cnk) src)))
                  (if src2
                      (let ((str2 ((chunker-get-str cnk) src2))
                            (i2 ((chunker-get-start cnk) src2))
                            (end2 ((chunker-get-end cnk) src2)))
                        (if (>= i2 end2)
                            (lp ((chunker-get-next cnk) src2))
                            (if (char-ci=? sre (string-ref str2 i2))
                                (next cnk init src2 str2 (+ i2 1) end2
                                      matches fail)
                                (fail))))
                      (fail)))
                (if (char-ci=? sre (string-ref str i))
                    (next cnk init src str (+ i 1) end matches fail)
                    (fail))))
          ;; case-sensitive
          (lambda (cnk init src str i end matches fail)
            (if (>= i end)
                (let lp ((src2 ((chunker-get-next cnk) src)))
                  (if src2
                      (let ((str2 ((chunker-get-str cnk) src2))
                            (i2 ((chunker-get-start cnk) src2))
                            (end2 ((chunker-get-end cnk) src2)))
                        (if (>= i2 end2)
                            (lp ((chunker-get-next cnk) src2))
                            (if (char=? sre (string-ref str2 i2))
                                (next cnk init src2 str2 (+ i2 1) end2
                                      matches fail)
                                (fail))))
                      (fail)))
                (if (char=? sre (string-ref str i))
                    (next cnk init src str (+ i 1) end matches fail)
                    (fail))))
          ))
     ((string? sre)
      (rec (sre-sequence (string->list sre)))
;; XXXX reintroduce faster string matching on chunks
;;       (if (flag-set? flags ~case-insensitive?)
;;           (rec (sre-sequence (string->list sre)))
;;           (let ((len (string-length sre)))
;;             (lambda (cnk init src str i end matches fail)
;;               (if (and (<= (+ i len) end)
;;                        (%substring=? sre str 0 i len))
;;                   (next str (+ i len) matches fail)
;;                   (fail)))))
      )
     (else
      (error "unknown regexp" sre)))))
