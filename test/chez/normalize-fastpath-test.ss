;; The java.text.Normalizer fast paths (jolt-lang/jolt#1066). Run:
;;   chez --script test/chez/normalize-fastpath-test.ss
;;
;; host/chez/java/text-normalize.ss answers normalize/isNormalized from a
;; per-character classification instead of rebuilding every string through
;; Chez. It derives that classification from Chez's own tables, so it tracks
;; whatever Unicode version the running Chez carries — with ONE exception. The
;; "composes backward" property (does any starter compose with this character?)
;; cannot be probed from outside one character at a time; deriving it means
;; decomposing the whole code point space, which is ~20 ms this run pays once
;; here rather than on a user's first normalize. So the file pins that set and
;; this gate re-derives it.
;;
;; A miss there is a WRONG ANSWER, not a slow one: a character wrongly believed
;; not to compose backward becomes a place the fast path is willing to split,
;; and a Hangul LVT syllable or an Indic vowel sign split from its base
;; normalizes to the wrong text. Unicode does keep adding these — 17.0 brought
;; the Tulu-Tigalari, Gurung Khema and Kirat Rai signs — so a Chez bump that
;; ships a newer UCD has to fail here, loudly, rather than in someone's text.
;;
;; Drift the other way is harmless and is only reported: an entry the running
;; Chez does not know is an unassigned code point that classifies as unsafe,
;; which costs a Chez call it did not need and nothing else.
;;
;; The last section is the differential: every code point on its own, then
;; exhaustive pairs and triples over an alphabet built from the characters that
;; make the boundary rules interesting (marks, Hangul jamo, Indic and Tibetan
;; signs, composition exclusions, singletons, compatibility forms), then random
;; strings. The fast path must agree with Chez character for character.

(import (chezscheme))
(load "host/chez/scheme-adapter-runtime.ss")   ; sa-string-copy-range!
(load "host/chez/java/text-normalize.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (hex s) (map (lambda (c) (number->string (char->integer c) 16)) (string->list s)))

;; ---- 1. the pinned backward composers vs. this Chez ------------------------
;; Every character that lands anywhere but first in a canonical decomposition
;; can compose backward. Only the starters need pinning: a character with a
;; non-zero combining class is already unsafe by text-normalize.ss's ordering
;; probe, which is jtn-starter? — the same one used here, so this also checks
;; the probe agrees with itself over the whole code point space.
(define derived (make-eqv-hashtable 256))
(let loop ((cp 0))
  (when (< cp #x110000)
    (unless (and (>= cp #xD800) (< cp #xE000))
      (let ((d (string-normalize-nfd (string (integer->char cp)))))
        (let tail ((i 1))
          (when (< i (string-length d))
            (let ((c (string-ref d i)))
              (when (jtn-starter? c) (hashtable-set! derived c #t)))
            (tail (+ i 1))))))
    (loop (+ cp 1))))
(define derived-list
  (sort < (map char->integer (vector->list (hashtable-keys derived)))))
(printf "normalize-fastpath: ~a backward-composing starters in this Chez\n"
        (length derived-list))
(for-each
  (lambda (cp)
    (ok (format "U+~a is pinned as a backward composer"
                (string-upcase (number->string cp 16)))
        (jtn-backward-composer? (integer->char cp))))
  derived-list)
;; The reverse direction is not a failure — report it so a Chez downgrade is
;; visible as the slowdown it is rather than looking like nothing happened.
(let loop ((i 0) (extra '()))
  (if (= i (vector-length jtn-backward-composers))
      (unless (null? extra)
        (printf "normalize-fastpath: ~a pinned code points this Chez does not decompose into: ~a\n"
                (length extra) (map (lambda (cp) (number->string cp 16)) (reverse extra))))
      (loop (+ i 2)
            (let range ((cp (vector-ref jtn-backward-composers i)) (acc extra))
              (if (> cp (vector-ref jtn-backward-composers (+ i 1)))
                  acc
                  (range (+ cp 1)
                         (if (hashtable-ref derived (integer->char cp) #f)
                             acc
                             (cons cp acc))))))))
;; Ascending and non-overlapping, which is what jtn-backward-composer?'s early
;; exit relies on.
(let loop ((i 0) (prev -1))
  (when (< i (vector-length jtn-backward-composers))
    (let ((lo (vector-ref jtn-backward-composers i))
          (hi (vector-ref jtn-backward-composers (+ i 1))))
      (ok (format "range ~a is ordered" (number->string lo 16)) (and (> lo prev) (<= lo hi)))
      (loop (+ i 2) hi))))

;; ---- 2. the ASCII short circuit --------------------------------------------
;; jtn-scan answers 'inert for every code point below #x80 without reading the
;; table, which is what keeps a megabyte of source at one compare per
;; character. Nothing below #x80 may decompose, carry a combining class, or
;; compose backward in any form.
(do ((idx 0 (+ idx 1))) ((= idx 4))
  (do ((cp 0 (+ cp 1))) ((= cp #x80))
    (ok (format "U+~2,'0x is inert in form ~a" cp idx)
        (eq? 'inert (jtn-classify-cp cp idx)))))

;; ---- 3. an already-normalized string comes back as itself ------------------
;; Not merely equal: the same object. A string that needs no work must not be
;; rebuilt, which is the whole of the ASCII rows in #1066.
(let ((s "plain ascii, nothing to normalize\n"))
  (do ((idx 0 (+ idx 1))) ((= idx 4))
    (ok (format "inert input is returned unchanged in form ~a" idx)
        (eq? s (jtn-normalize s idx)))))

;; ---- 4. the differential ----------------------------------------------------
(define checked 0)
(define (chk s)
  (do ((idx 0 (+ idx 1))) ((= idx 4))
    (set! checked (+ checked 1))
    (let ((want (jtn-normalize-1 s idx))
          (got (jtn-normalize s idx)))
      (unless (string=? want got)
        (set! fails (+ fails 1)) (set! total (+ total 1))
        (when (< fails 12)
          (printf "FAIL: normalize form ~a of ~a: want ~a got ~a\n" idx (hex s) (hex want) (hex got))))
      (let ((want? (string=? s want)) (got? (jtn-normalized? s idx)))
        (unless (eq? want? got?)
          (set! fails (+ fails 1)) (set! total (+ total 1))
          (when (< fails 12)
            (printf "FAIL: isNormalized form ~a of ~a: want ~a got ~a\n" idx (hex s) want? got?)))))))

(let loop ((cp 0))
  (when (< cp #x110000)
    (unless (and (>= cp #xD800) (< cp #xE000))
      (chk (string (integer->char cp))))
    (loop (+ cp 1))))

;; The alphabet the boundary rules turn on, plus plain text to surround it with.
(define alphabet
  (map integer->char
       '(#x41 #x61 #x20 #x0A #x30                                  ; ascii
         #xC0 #xE9 #x300 #x301 #x303 #x323 #x327 #x334 #x345 #x308 ; latin + marks
         #x1100 #x1161 #x11A8 #xAC00 #xAC01 #xD7A3                 ; hangul jamo + syllables
         #x9C7 #x9BE #x9D7 #x9CB #xBBE #xBD7 #xBC6                 ; bengali, tamil
         #xCC6 #xCC2 #xCD5 #xCCA #xCCB                             ; kannada two-step
         #xFB5 #xF40 #xF69 #xFB7 #xFB2 #xF76 #xF71 #xF72 #xF73     ; tibetan
         #x102E #x1025 #x1026 #x1B05 #x1B35 #x1B06                 ; myanmar, balinese
         #x958 #x1E69 #x2126 #x212B #xA0 #x2026 #xFB01 #xFF37      ; exclusions, singletons, compat
         #xB2 #x2162 #x1D160 #x11127 #x11131 #x1133E #x1134B       ; supplementary
         #x1611E #x16121 #xA7F1)))
(for-each (lambda (a)
            (for-each (lambda (b)
                        (chk (string a b))
                        (for-each (lambda (c) (chk (string a b c))) alphabet))
                      alphabet))
          alphabet)

(random-seed 1066)
(define pool (list->vector (append alphabet
  (let loop ((i 0) (acc '()))
    (if (= i 400)
        acc
        (let ((cp (random #x10000)))
          (loop (+ i 1) (if (and (>= cp #xD800) (< cp #xE000)) acc (cons (integer->char cp) acc)))))))))
(do ((t 0 (+ t 1))) ((= t 20000))
  (let* ((n (+ 1 (random 40))) (s (make-string n)))
    (do ((i 0 (+ i 1))) ((= i n)) (string-set! s i (vector-ref pool (random (vector-length pool)))))
    (chk s)))

(printf "normalize-fastpath: ~a property checks, ~a differential comparisons, ~a failures\n" total checked fails)
(when (> fails 0) (exit 1))
