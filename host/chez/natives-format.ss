;; natives-format.ss — a small %-format engine for clojure.core `format` over the
;; all-flonum number model: %d (integer), %s (str), %f / %.Nf (fixed-point), %x/%X
;; (hex int), %o (octal), %c (char int), %b (boolean), %% (literal). Enough for the
;; corpus, not the full Java Formatter spec. Loaded after natives-misc.ss (uses
;; jolt-str-render-one via converters + jolt-truthy?).

(define (->long x) (exact (truncate x)))

;; Guard for the conversions that need a number. The JVM renders a nil argument as
;; "null" whatever the conversion, and rejects one it cannot take with
;; IllegalFormatConversionException, whose message names the conversion and the
;; argument's class ("d != java.lang.String"). Without this the argument reached a
;; Chez numeric primitive and the raw condition escaped with no class, so no catch
;; clause could select it. %c also takes a char.
(define (fmt-numeric d a f)
  (cond ((jolt-nil? a) "null")
        ((or (number? a) (and (char? a) (char=? d #\c))) (f a))
        (else (jolt-throw (jolt-host-throwable "java.util.IllegalFormatConversionException"
                (string-append (string d) " != " (jolt-class-name a)))))))
;; %x / %X / %o are UNSIGNED conversions on the JVM: a negative argument prints the
;; two's complement of its integer type, not a signed magnitude ("%x" -1 was "-1"
;; here, which is wrong under any width). The WIDTH is the argument's Java type —
;; Byte 8 bits, Short 16, Integer 32, Long 64 — and jolt unifies every integer as
;; one type, so it cannot read the width off the argument and one of the two ends
;; must diverge. jolt takes the NARROWEST width that holds the value, which is the
;; JVM's answer whenever the value's origin type is the narrowest that holds it:
;; a byte out of a byte[] prints two digits and an int-sized hash prints eight,
;; so the hex-dump and percent-encode idioms match the JVM unmasked. The cost is a
;; long whose value fits narrower — (format "%x" (long -1)) is "ff" here and
;; "ffffffffffffffff" on the JVM — allowlisted under :integer-box-model. Masking
;; ((bit-and b 0xff)) pins the width explicitly and is identical on both.
;; A value outside the signed-64 range has no fixed-width two's complement to print
;; — the JVM would be holding a BigInteger there, whose %x is a signed magnitude
;; with a leading minus — so that is what it gets. Masking it to 64 bits, as the
;; width search would, silently rendered -(2^70) as "0".
(define (fmt-radix v radix)
  (let ((n (->long v)))
    (cond
      ((>= n 0) (number->string n radix))
      ((< n (- (expt 2 63))) (string-append "-" (number->string (- n) radix)))
      (else
       (let loop ((bits 8))
         (if (>= n (- (expt 2 (- bits 1))))
             (number->string (bitwise-and n (- (expt 2 bits) 1)) radix)
             (loop (fx* bits 2))))))))
(define (pad-left s n c) (if (fx>=? (string-length s) n) s (string-append (make-string (fx- n (string-length s)) c) s)))
;; The decimal separator %f renders. "." everywhere except inside a
;; String.format(Locale, …) call, which binds this to the locale's separator —
;; the JVM formats 123.045 as "123,045" under de. Bound rather than passed so
;; every directive path picks it up without threading an argument through.
(define format-decimal-sep (make-parameter "."))
;; --- the decimal digits of a number ---------------------------------------------
;; (num-digits x) -> (values digits expo) for a finite x >= 0: digits are the
;; significant decimal digits with no leading or trailing zeros ("0" for zero),
;; and x = 0.DIGITS x 10^expo. A flonum's digits are Chez's shortest round-trip
;; print, which is the digit string java.util.Formatter rounds too: it formats
;; from FloatingDecimal's digits, not from the binary value, so 1.005 rounds to
;; 1.01 at two places where the binary value 1.00499… would round down, and
;; (format "%.20f" 0.1) pads zeros rather than printing the expansion. A
;; BigDecimal's digits are its unscaled value against its scale, exact.
(define (str-index s c)
  (let loop ((i 0))
    (cond ((fx=? i (string-length s)) #f) ((char=? (string-ref s i) c) i) (else (loop (fx+ i 1))))))
(define (digits-normalize raw expo)      ; drop leading zeros (each lowers expo) and trailing ones
  (let lead ((i 0))
    (if (and (fx<? i (string-length raw)) (char=? (string-ref raw i) #\0))
        (lead (fx+ i 1))
        (let trail ((j (string-length raw)))
          (cond ((fx=? j i) (values "0" 1))
                ((char=? (string-ref raw (fx- j 1)) #\0) (trail (fx- j 1)))
                (else (values (substring raw i j) (- expo i))))))))
(define (num-digits x)
  (if (jbigdec? x)
      (let ((u (number->string (abs (jbigdec-unscaled x)))))
        (digits-normalize u (- (string-length u) (jbigdec-scale x))))
      (let* ((s (number->string (inexact x)))   ; "123.45" | "1e100" | "1.5e-7" | "123456789.0"
             ;; a denormal prints with its bit count after a bar ("1e-320|11"):
             ;; cut there before splitting the exponent off
             (bar (or (str-index s #\|) (string-length s)))
             (s (substring s 0 bar))
             (epos (or (str-index s #\e) (string-length s)))
             (mant (substring s 0 epos))
             (e10 (if (fx<? epos (string-length s))
                      (string->number (substring s (fx+ epos 1) (string-length s)))
                      0))
             (dot (str-index mant #\.))
             (int-part (if dot (substring mant 0 dot) mant))
             (frac-part (if dot (substring mant (fx+ dot 1) (string-length mant)) "")))
        (digits-normalize (string-append int-part frac-part) (+ e10 (string-length int-part))))))
;; (digits-round digits n) -> (cons digits* carry?): the first n digits, rounded
;; half up on the one after them -- java.util.Formatter's applyPrecision looks
;; at exactly that one digit. carry? says the round went past the top digit
;; (99.5 -> 100): digits* is then "1" and the caller's exponent grows by one.
(define (digits-round digits n)
  (let ((len (string-length digits)))
    (cond
      ((< n 0) (cons "" #f))
      ((>= n len) (cons digits #f))
      ((char<? (string-ref digits n) #\5) (cons (substring digits 0 n) #f))
      (else
       (let ((s (number->string (+ 1 (if (fx=? n 0) 0 (string->number (substring digits 0 n)))))))
         (if (fx>? (string-length s) n) (cons "1" #t) (cons s #f)))))))
;; the k-th digit (0-based from the top) of a digit string, 0 past either end
(define (digit-at d k)
  (if (and (fx>=? k 0) (fx<? k (string-length d))) (string-ref d k) #\0))
;; %f: prec fraction digits. The digits kept are the expo integer ones plus prec.
(define (fmt-fixed digits expo prec)
  (let* ((r (digits-round digits (+ expo prec)))
         (d (car r)) (expo (if (cdr r) (+ expo 1) expo))
         (int (if (<= expo 0)
                  "0"
                  (let ((s (make-string expo)))
                    (do ((k 0 (fx+ k 1))) ((fx=? k expo) s) (string-set! s k (digit-at d k))))))
         (frac (let ((s (make-string prec)))
                 (do ((i 0 (fx+ i 1))) ((fx=? i prec) s) (string-set! s i (digit-at d (+ expo i)))))))
    (if (fx>? prec 0) (string-append int (format-decimal-sep) frac) int)))
;; %e: d.dddddde+xx, prec fraction digits, the exponent at least two digits with
;; a sign. prec+1 significant digits are kept.
(define (fmt-sci digits expo prec)
  (let* ((r (digits-round digits (fx+ prec 1)))
         (d (car r)) (expo (if (cdr r) (+ expo 1) expo))
         (e (- expo 1))
         (frac (let ((s (make-string prec)))
                 (do ((i 0 (fx+ i 1))) ((fx=? i prec) s) (string-set! s i (digit-at d (fx+ i 1))))))
         (es (number->string (abs e))))
    (string-append (string (digit-at d 0))
                   (if (fx>? prec 0) (string-append (format-decimal-sep) frac) "")
                   "e" (if (< e 0) "-" "+")
                   (if (fx<? (string-length es) 2) (string-append "0" es) es))))
;; %g: prec significant digits (a 0 reads as 1); fixed notation when the ROUNDED
;; value is in [10^-4, 10^prec), scientific otherwise -- Java's rule, which is
;; why (format "%.3g" 1234.5) is 1.23e+03 and 0.00001234 is 1.23400e-05. The
;; digits are rounded once, here; the notation only lays them out.
(define (fmt-general digits expo prec)
  (let* ((prec (if (fx=? prec 0) 1 prec))
         (r (digits-round digits prec))
         (d (car r)) (expo (if (cdr r) (+ expo 1) expo))
         (e (- expo 1)))
    (if (and (>= e -4) (< e prec))
        (fmt-fixed d expo (fx- prec (fx+ e 1)))
        (fmt-sci d expo (fx- prec 1)))))
;; digit grouping for the , flag: the integer part in threes, the fraction as is
(define (fmt-group s)
  (let* ((sep (format-decimal-sep))
         (dot (str-index s (string-ref sep 0)))
         (int (if dot (substring s 0 dot) s))
         (rest (if dot (substring s dot (string-length s)) "")))
    (let loop ((i (string-length int)) (acc '()))
      (if (fx<=? i 3)
          (apply string-append (substring int 0 i) (append acc (list rest)))
          (loop (fx- i 3) (cons (string-append "," (substring int (fx- i 3) i)) acc))))))

;; --- one conversion --------------------------------------------------------------
;; A signed numeric conversion renders (vector neg? magnitude zero-pad?) and then
;; shares the sign, the grouping and the padding with every other one: the sign
;; is "-" (or "(…)" under the ( flag), "+" under +, " " under space; a 0 flag
;; pads with zeros AFTER the sign, as the JVM does ("-0003.00", not "000-3.00");
;; NaN and Infinity take the sign but never the zeros.
(define (fmt-flag? flags c) (and (memv c flags) #t))
(define (fmt-sign-pad neg? body flags width zero-ok?)
  (let* ((prefix (cond (neg? (if (fmt-flag? flags #\() "(" "-"))
                       ((fmt-flag? flags #\+) "+")
                       ((fmt-flag? flags #\space) " ")
                       (else "")))
         (suffix (if (and neg? (fmt-flag? flags #\()) ")" ""))
         (n (fx+ (string-length prefix) (fx+ (string-length body) (string-length suffix)))))
    (cond ((or (not width) (fx>=? n width)) (string-append prefix body suffix))
          ((fmt-flag? flags #\-) (string-append prefix body suffix (make-string (fx- width n) #\space)))
          ((and zero-ok? (fmt-flag? flags #\0)) (string-append prefix (make-string (fx- width n) #\0) body suffix))
          (else (string-append (make-string (fx- width n) #\space) prefix body suffix)))))
;; pad to width: left-justify with spaces, else right-justify (zero-pad only
;; where the caller says the conversion takes it)
(define (fmt-pad s flags width zero-ok?)
  (if (and width (fx<? (string-length s) width))
      (let ((p (fx- width (string-length s))))
        (cond ((fmt-flag? flags #\-) (string-append s (make-string p #\space)))
              (else (string-append (make-string p (if (and zero-ok? (fmt-flag? flags #\0)) #\0 #\space)) s))))
      s))
(define (fmt-conversion-throw d a)
  (jolt-throw (jolt-host-throwable "java.util.IllegalFormatConversionException"
                                   (string-append (string d) " != " (jolt-class-name a)))))
;; %d %x %X %o take an integer -- Byte through BigInteger on the JVM, never a
;; Double or a Ratio (IllegalFormatConversionException there, so here too).
(define (fmt-integer? a) (and (number? a) (exact? a) (integer? a)))
;; %f %e %g take a Float, a Double or a BigDecimal; an integer or a ratio is the
;; same refusal. NaN and the infinities print as the JVM prints them.
(define (fmt-real d a flags width render)
  (cond
    ((jolt-nil? a) (fmt-pad "null" flags width #f))
    ((flonum? a)
     (cond ((nan? a) (fmt-sign-pad #f "NaN" flags width #f))
           ((infinite? a) (fmt-sign-pad (< a 0) "Infinity" flags width #f))
           (else (let-values (((ds ex) (num-digits (abs a))))
                   (fmt-sign-pad (or (< a 0) (eqv? a -0.0)) (render ds ex) flags width #t)))))
    ((jbigdec? a)
     (let-values (((ds ex) (num-digits a)))
       (fmt-sign-pad (< (jbigdec-unscaled a) 0) (render ds ex) flags width #t)))
    (else (fmt-conversion-throw d a))))
(define (fmt-directive d a flags width prec)
  (let ((grouped (lambda (s) (if (fmt-flag? flags #\,) (fmt-group s) s)))
        (up (lambda (f) (lambda (ds ex) (string-upcase (f ds ex))))))
    (case d
      ((#\d) (cond ((jolt-nil? a) (fmt-pad "null" flags width #f))
                   ((fmt-integer? a) (fmt-sign-pad (< a 0) (grouped (number->string (abs a))) flags width #t))
                   (else (fmt-conversion-throw d a))))
      ((#\f) (fmt-real d a flags width (lambda (ds ex) (grouped (fmt-fixed ds ex (or prec 6))))))
      ((#\e) (fmt-real d a flags width (lambda (ds ex) (fmt-sci ds ex (or prec 6)))))
      ((#\E) (fmt-real d a flags width (up (lambda (ds ex) (fmt-sci ds ex (or prec 6))))))
      ((#\g) (fmt-real d a flags width (lambda (ds ex) (grouped (fmt-general ds ex (or prec 6))))))
      ((#\G) (fmt-real d a flags width (up (lambda (ds ex) (grouped (fmt-general ds ex (or prec 6)))))))
      ((#\x #\X #\o)
       (cond ((jolt-nil? a) (fmt-pad "null" flags width #f))
             ((fmt-integer? a)
              ;; Chez spells hex digits in upper case; %x is the lower-case conversion
              (let ((s (fmt-radix a (if (char=? d #\o) 8 16))))
                (fmt-pad (cond ((char=? d #\X) (string-upcase s))
                               ((char=? d #\x) (string-downcase s))
                               (else s))
                         flags width #t)))
             (else (fmt-conversion-throw d a))))
      ((#\s) (fmt-pad (if (jolt-nil? a) "null" (jolt-str-render-one a)) flags width #f))
      ((#\S) (fmt-pad (string-upcase (if (jolt-nil? a) "null" (jolt-str-render-one a))) flags width #f))
      ((#\b) (fmt-pad (if (jolt-truthy? a) "true" "false") flags width #f))
      ((#\c) (fmt-pad (fmt-numeric d a (lambda (n) (if (char? n) (string n) (string (integer->char (->long n))))))
                      flags width #f))
      (else (jolt-throw (jolt-host-throwable "java.util.UnknownFormatConversionException"
                                             (string-append "Conversion = '" (string d) "'")))))))

(define (jolt-format fmt . args)
  (let ((fmt (jolt-need-string fmt))
        (out (open-output-string)))
    (let loop ((i 0) (as args))
      (if (fx>=? i (string-length fmt))
          (get-output-string out)
          (let ((c (string-ref fmt i)))
            (if (char=? c #\%)
                ;; parse a directive: %[flags][width][.prec]conv, the flags any of
                ;; - # + space 0 , ( in any order (a 0 is a flag only ahead of the width)
                (let scan ((j (fx+ i 1)) (flags '()) (width #f) (prec #f) (seen-dot #f))
                  (let ((d (string-ref fmt j)))
                    (cond
                      ((char=? d #\%) (write-char #\% out) (loop (fx+ j 1) as))
                      ((and (not seen-dot) (not width) (memv d '(#\- #\# #\+ #\space #\0 #\, #\()))
                       (scan (fx+ j 1) (cons d flags) width prec seen-dot))
                      ((char=? d #\.) (scan (fx+ j 1) flags width 0 #t))
                      ((and (char>=? d #\0) (char<=? d #\9))
                       (if seen-dot
                           (scan (fx+ j 1) flags width (fx+ (fx* (or prec 0) 10) (fx- (char->integer d) 48)) seen-dot)
                           (scan (fx+ j 1) flags (fx+ (fx* (or width 0) 10) (fx- (char->integer d) 48)) prec seen-dot)))
                      ;; %n: literal newline, consumes no argument
                      ((char=? d #\n) (write-char #\newline out) (loop (fx+ j 1) as))
                      (else
                       (let ((a (if (null? as) jolt-nil (car as)))
                             (rest (if (null? as) '() (cdr as))))
                         (display (fmt-directive d a flags width prec) out)
                         (loop (fx+ j 1) rest))))))
                (begin (write-char c out) (loop (fx+ i 1) as))))))))
(def-var! "clojure.core" "format" jolt-format)
