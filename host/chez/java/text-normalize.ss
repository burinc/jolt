;; text-normalize.ss — the quick-check fast paths under java.text.Normalizer.
;;
;; Chez normalizes by rebuilding: decompose every character, canonically
;; reorder, recompose. That costs the same whether the input is "café" or a
;; megabyte of ASCII source, and Normalizer/isNormalized had no answer but
;; "normalize it and compare" — so a string that was already normalized paid
;; the full price, and one that fails at its first character paid it too. The
;; JVM instead pays for the work the text actually needs, which left jolt
;; 2.7x-33x behind it, worst exactly where the text was cleanest (gh-1066).
;;
;; THE MODEL. A character c has a NORMALIZATION BOUNDARY BEFORE IT, in form F,
;; when the first character of its F-decomposition is a starter (canonical
;; combining class 0) that does not compose backward. Nothing to its left can
;; then reorder into it or compose with it, so c begins a normalization segment
;; of its own: when every character of a string has a boundary before it,
;;
;;     (normalize s F) = (apply string-append (map (normalize _ F) (chars s)))
;;
;; and the per-character results can be memoized. That splits the code point
;; space three ways, per form:
;;
;;   inert      boundary, and normalizing the character alone returns it —
;;              every ASCII character, every CJK ideograph, every emoji, most
;;              letters. Copy the run verbatim; a wholly inert string is
;;              returned unchanged, with nothing allocated at all.
;;   expansion  boundary, but the character normalizes to something else
;;              (ﬁ -> fi under NFKC, U+2126 OHM SIGN -> U+03A9 under NFC).
;;              Splice the memoized result in.
;;   unsafe     no boundary: a combining mark, a Hangul jamo, a Tibetan or
;;              Indic sign that belongs to whatever segment its neighbour
;;              starts. Hand the stretch to Chez, which is what a real
;;              normalizer is for — and only that stretch.
;;
;; isNormalized reads the same table and answers at the first character that is
;; not inert: an expansion means the text changes there, so it is false without
;; normalizing anything, and unsafe stretches are compared segment by segment.
;;
;; WHERE THE TABLE COMES FROM. Not from a shipped DerivedNormalizationProps.txt:
;; the classifier reads every property back out of the Chez that will do the
;; normalizing, so the fast path cannot disagree with the slow path about which
;; Unicode version this is. Two probes do it, per code point, once, lazily, one
;; 256-code-point block at a time:
;;
;;   the F-decomposition   (string-normalize-nfd / -nfkd of the lone character)
;;                         gives the character the boundary test is about.
;;   combining class 0     canonical ordering is observable: a character with a
;;                         non-zero class reorders when it is put next to a mark
;;                         of a higher class. U+0345 (class 240) catches classes
;;                         1..239 and U+0334 (class 1) catches 240, so a
;;                         character that survives both probes unmoved is a
;;                         starter.
;;
;; The third property, "composes backward", is the one no probe can read back
;; in isolation — it asks whether ANY starter composes with this character, and
;; the only way to answer that from outside is to decompose the whole code point
;; space and collect every character that lands after the first (~20 ms on a
;; desktop). Paying that on the first non-ASCII normalize costs more than it
;; saves for anything short of a megabyte, so the answer is pinned below and
;; `make normalizecheck` re-derives it from the running Chez and fails on drift.

;; The starters that compose backward: the ccc=0 half of Unicode's NFC_QC=Maybe,
;; derived from Chez 10.4.1's tables (Unicode 17.0) by test/chez/normalize-
;; fastpath-test.ss, which is `make normalizecheck`. The other half — combining
;; marks — needs no entry here: a non-zero combining class already fails the
;; ordering probe. Unicode does keep adding these — the Tulu-Tigalari, Gurung
;; Khema and Kirat Rai signs at the end of the table arrived with 16.0 — which
;; is what the gate is for. Drift in the safe direction costs nothing: against an
;; older Chez the extra entries are unassigned code points that simply classify
;; as unsafe, and an unsafe character is normalized by Chez, not by this file.
;; Pairs are inclusive lo/hi, ascending.
(define jtn-backward-composers
  '#(#x009BE #x009BE #x009D7 #x009D7 #x00B3E #x00B3E #x00B56 #x00B57
     #x00BBE #x00BBE #x00BD7 #x00BD7 #x00CC2 #x00CC2 #x00CD5 #x00CD6
     #x00D3E #x00D3E #x00D57 #x00D57 #x00DCF #x00DCF #x00DDF #x00DDF
     #x00FB5 #x00FB5 #x00FB7 #x00FB7 #x0102E #x0102E #x01161 #x01175
     #x011A8 #x011C2 #x01B35 #x01B35 #x11127 #x11127 #x1133E #x1133E
     #x11357 #x11357 #x113B8 #x113B8 #x113BB #x113BB #x113C2 #x113C2
     #x113C9 #x113C9 #x114B0 #x114B0 #x114BA #x114BA #x114BD #x114BD
     #x115AF #x115AF #x11930 #x11930 #x1611E #x16120 #x16129 #x16129
     #x16D67 #x16D67))

(define (jtn-backward-composer? c)
  (let ((cp (char->integer c)) (v jtn-backward-composers))
    (let loop ((i 0))
      (cond ((fx= i (vector-length v)) #f)
            ((fx< cp (vector-ref v i)) #f)                  ; ascending: past it
            ((fx<= cp (vector-ref v (fx+ i 1))) #t)
            (else (loop (fx+ i 2)))))))

;; Canonical combining class 0, read out of canonical ordering: U+0345 is class
;; 240 and U+0334 is class 1, so a non-starter reorders against one or the
;; other (240 catches 1..239, 1 catches 240 — the only class Unicode assigns
;; above 239). Both probe characters are themselves fully decomposed, and NFD
;; never composes, so the only thing either normalize can do is the swap being
;; tested for. Callers pass the FIRST character of a decomposition, which is
;; already decomposed for the same reason.
(define (jtn-starter? x)
  (and (let ((p (string #\x345 x))) (string=? p (string-normalize-nfd p)))
       (let ((p (string x #\x334))) (string=? p (string-normalize-nfd p)))))

;; Form index: 0 NFC, 1 NFD, 2 NFKC, 3 NFKD — what normalizer-form-index maps a
;; Normalizer.Form constant to (java/host-static-methods.ss).
(define (jtn-normalize-1 s idx)
  (cond ((fx= idx 0) (string-normalize-nfc s))
        ((fx= idx 1) (string-normalize-nfd s))
        ((fx= idx 2) (string-normalize-nfkc s))
        (else        (string-normalize-nfkd s))))
;; The decomposition the form's own boundaries are drawn from: canonical for
;; the two canonical forms, compatibility for the two K forms.
(define (jtn-decompose-1 s idx)
  (if (fx< idx 2) (string-normalize-nfd s) (string-normalize-nfkd s)))

;; One lazily filled table per form, one lazily filled 256-entry block per table.
;; A block holds 'inert, 'unsafe, or the character's normalized expansion — the
;; expansion strings are shared and only ever copied out of, never mutated.
;; Racing threads can duplicate a fill or drop a table another thread just
;; installed; both lose work and neither loses correctness, since every fill
;; recomputes the same classification from the same Chez tables.
(define jtn-tables (vector #f #f #f #f))
(define (jtn-table idx)
  (or (vector-ref jtn-tables idx)
      (let ((v (make-vector (fx+ 1 (fxsrl #x10FFFF 8)) #f)))
        (vector-set! jtn-tables idx v)
        v)))

(define (jtn-classify-cp cp idx)
  (let* ((s (string (integer->char cp)))
         (d0 (string-ref (jtn-decompose-1 s idx) 0)))
    (if (and (jtn-starter? d0) (not (jtn-backward-composer? d0)))
        (let ((e (jtn-normalize-1 s idx)))
          (if (string=? e s) 'inert e))
        'unsafe)))

(define (jtn-fill-block! tbl hi idx)
  (let ((blk (make-vector 256 'unsafe))
        (base (fxsll hi 8)))
    (let loop ((k 0))
      (when (fx< k 256)
        (let ((cp (fx+ base k)))
          ;; A surrogate code point is not a Chez character, so no string can
          ;; hold one and the 'unsafe seeded above is never read.
          (unless (and (fx>= cp #xD800) (fx<= cp #xDFFF))
            (vector-set! blk k (jtn-classify-cp cp idx))))
        (loop (fx+ k 1))))
    (vector-set! tbl hi blk)
    blk))

(define (jtn-class s i tbl idx)
  (let ((cp (char->integer (string-ref s i))))
    (let* ((hi (fxsrl cp 8))
           (blk (vector-ref tbl hi)))
      (vector-ref (or blk (jtn-fill-block! tbl hi idx)) (fxand cp #xFF)))))

;; The scan every path starts with: the index of the first character that is not
;; inert, or the length. ASCII short-circuits ahead of the table — no ASCII
;; character decomposes, none has a combining class, and none composes backward
;; in any of the four forms (asserted by `make normalizecheck`) — which is what
;; keeps a megabyte of source code at a bare read-and-compare per character.
(define (jtn-scan s i len tbl idx)
  (let loop ((i i))
    (if (fx= i len)
        len
        (let ((cp (char->integer (string-ref s i))))
          (if (fx< cp #x80)
              (loop (fx+ i 1))
              (let* ((hi (fxsrl cp 8))
                     (blk (vector-ref tbl hi)))
                (if (eq? 'inert (vector-ref (or blk (jtn-fill-block! tbl hi idx))
                                            (fxand cp #xFF)))
                    (loop (fx+ i 1))
                    i)))))))

;; The end of an unsafe stretch: the next character that has a boundary before
;; it, which is where Chez's segment may stop.
(define (jtn-next-safe s i len tbl idx)
  (let loop ((i i))
    (cond ((fx= i len) len)
          ((eq? 'unsafe (jtn-class s i tbl idx)) (loop (fx+ i 1)))
          (else i))))

(define (jtn-grow buf pos need)
  (let ((cap (string-length buf)))
    (if (fx>= cap need)
        buf
        (let loop ((c (fxmax 32 (fx* cap 2))))
          (if (fx< c need)
              (loop (fx* c 2))
              (let ((b (make-string c)))
                (sa-string-copy-range! b 0 buf 0 pos)
                b))))))

;; Append str[from..to) at buf[pos], growing buf if it must. The caller carries
;; pos itself (it is pos + to - from), so this returns only the buffer.
(define (jtn-put buf pos str from to)
  (let ((n (fx- to from)))
    (if (fx= n 0)
        buf
        (let ((b (jtn-grow buf pos (fx+ pos n))))
          (sa-string-copy-range! b pos str from to)
          b))))

;; normalize(s, form). Walks inert runs with jtn-scan and copies them whole,
;; splices expansions, and calls Chez only for the stretches with no boundary.
;;
;; `run` is the start of the verbatim stretch not yet copied out, so `buf` plus
;; s[run..i) is the answer so far. An unsafe character has no boundary before
;; it, so its segment starts at the previous character — which the loop has
;; already emitted. `xi`/`xpos` are how that is taken back: when the previous
;; character was an expansion, xi is its index and xpos the buffer position
;; before its expansion went in, so rewinding is a matter of dropping back to
;; xpos. When it was inert it is still inside s[run..i) and simply not copied.
(define (jtn-normalize s idx)
  (let* ((len (string-length s))
         (tbl (jtn-table idx))
         (j (jtn-scan s 0 len tbl idx)))
    (if (fx= j len)
        s                                      ; wholly inert: nothing to do
        (let loop ((i j) (run 0) (buf "") (pos 0) (xi -1) (xpos 0))
          (let ((i (jtn-scan s i len tbl idx)))
            (if (fx= i len)
                (let ((b (jtn-put buf pos s run len)))
                  (substring b 0 (fx+ pos (fx- len run))))
                (let ((cls (jtn-class s i tbl idx)))
                  (if (string? cls)
                      (let* ((b (jtn-put buf pos s run i))
                             (p (fx+ pos (fx- i run)))
                             (n (string-length cls))
                             (b2 (jtn-put b p cls 0 n)))
                        (loop (fx+ i 1) (fx+ i 1) b2 (fx+ p n) i p))
                      (let* ((b0 (if (fx> i 0) (fx- i 1) 0))
                             (back? (fx= xi b0))
                             (pos1 (if back? xpos pos))
                             (run1 (if back? b0 run))
                             (b (jtn-put buf pos1 s run1 b0))
                             (p (fx+ pos1 (fx- b0 run1)))
                             (k (jtn-next-safe s (fx+ i 1) len tbl idx))
                             (seg (jtn-normalize-1 (substring s b0 k) idx))
                             (n (string-length seg))
                             (b2 (jtn-put b p seg 0 n)))
                        (loop k k b2 (fx+ p n) -1 0))))))))))

;; isNormalized(s, form). The first non-inert character decides it: an expansion
;; is text that changes, so the answer is false there and then; an unsafe
;; stretch is the one thing that has to be normalized, and only that stretch.
(define (jtn-normalized? s idx)
  (let ((len (string-length s))
        (tbl (jtn-table idx)))
    (let loop ((i 0))
      (let ((i (jtn-scan s i len tbl idx)))
        (if (fx= i len)
            #t
            (and (not (string? (jtn-class s i tbl idx)))
                 (let* ((b0 (if (fx> i 0) (fx- i 1) 0))
                        (k (jtn-next-safe s (fx+ i 1) len tbl idx))
                        (seg (substring s b0 k)))
                   (and (string=? seg (jtn-normalize-1 seg idx))
                        (loop k)))))))))
