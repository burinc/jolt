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
(define (fmt-float x prec)
  (let* ((neg (< x 0)) (ax (abs x))
         (scale (expt 10 prec))
         (scaled (round (* (inexact ax) scale)))
         (i (exact (truncate (/ scaled scale))))
         (frac (exact (truncate (- scaled (* i scale))))))
    (string-append (if neg "-" "")
                   (number->string i)
                   (if (fx>? prec 0)
                       (string-append (format-decimal-sep) (pad-left (number->string frac) prec #\0))
                       ""))))
(define (jolt-format fmt . args)
  (let ((fmt (jolt-need-string fmt))
        (out (open-output-string)))
    (let loop ((i 0) (as args))
      (if (fx>=? i (string-length fmt))
          (get-output-string out)
          (let ((c (string-ref fmt i)))
            (if (char=? c #\%)
                ;; parse a directive: %[-][0][width][.prec]conv
                (let scan ((j (fx+ i 1)) (left #f) (zero #f) (width #f) (prec #f) (seen-dot #f))
                  (let ((d (string-ref fmt j)))
                    (cond
                      ((char=? d #\%) (write-char #\% out) (loop (fx+ j 1) as))
                      ((and (not seen-dot) (not width) (char=? d #\-))
                       (scan (fx+ j 1) #t zero width prec seen-dot))
                      ((and (not seen-dot) (not width) (char=? d #\0))
                       (scan (fx+ j 1) left #t width prec seen-dot))
                      ((char=? d #\.) (scan (fx+ j 1) left zero width 0 #t))
                      ((and (char>=? d #\0) (char<=? d #\9))
                       (if seen-dot
                           (scan (fx+ j 1) left zero width (fx+ (fx* (or prec 0) 10) (fx- (char->integer d) 48)) seen-dot)
                           (scan (fx+ j 1) left zero (fx+ (fx* (or width 0) 10) (fx- (char->integer d) 48)) prec seen-dot)))
                      (else
                       ;; %n: literal newline, consumes no argument
                       (if (char=? d #\n)
                           (begin (write-char #\newline out) (loop (fx+ j 1) as))
                           (let* ((a (if (null? as) jolt-nil (car as)))
                                  (rest (if (null? as) '() (cdr as)))
                                  (s (case d
                                       ((#\d) (fmt-numeric d a (lambda (n) (number->string (->long n)))))
                                       ((#\s) (if (jolt-nil? a) "null" (jolt-str-render-one a)))
                                       ((#\S) (string-upcase (if (jolt-nil? a) "null" (jolt-str-render-one a))))
                                       ((#\f) (fmt-numeric d a (lambda (n) (fmt-float n (or prec 6)))))
                                       ((#\x) (fmt-numeric d a (lambda (n) (string-downcase (fmt-radix n 16)))))
                                       ((#\X) (fmt-numeric d a (lambda (n) (string-upcase (fmt-radix n 16)))))
                                       ((#\o) (fmt-numeric d a (lambda (n) (fmt-radix n 8))))
                                       ((#\b) (if (jolt-truthy? a) "true" "false"))
                                       ((#\c) (fmt-numeric d a (lambda (n) (if (char? n) (string n)
                                                                               (string (integer->char (->long n)))))))
                                       (else (jolt-throw (jolt-host-throwable "java.util.UnknownFormatConversionException"
                                                        (string-append "Conversion = '" (string d) "'"))))))
                                  ;; pad to width: left-justify with spaces, else right-justify
                                  ;; (zero-pad only a right-justified number).
                                  (s (if (and width (fx<? (string-length s) width))
                                         (let ((p (fx- width (string-length s))))
                                           (if left (string-append s (make-string p #\space))
                                               (string-append (make-string p (if (and zero (memv d '(#\d #\f #\x #\X #\o))) #\0 #\space)) s)))
                                         s)))
                             (display s out)
                             (loop (fx+ j 1) rest)))))))
                (begin (write-char c out) (loop (fx+ i 1) as))))))))
(def-var! "clojure.core" "format" jolt-format)
