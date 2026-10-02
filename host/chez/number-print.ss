;; number-print.ss — how jolt prints a number: Double.toString's layout over the
;; host's shortest round-trip digits. Portable (R7RS strings and arithmetic), so
;; Chez (rt.ss loads it) and Gambit (rt-core.ss includes it) print alike.

;; jolt has a numeric tower (exact integer / ratio / double, distinguished by
;; class). Exact integer-valued values print without a ".0" ((+ 1 2) -> "3");
;; a double prints with one ((* 1.0 5) -> "5.0", as the JVM does).

;; Double.toString layout: plain decimal when 1e-3 <= |x| < 1e7, otherwise
;; scientific d.dddE±x with one digit before the point; the mantissa always
;; carries a decimal point ("1.0E100", "2.3E-4", "1.2345678E7"). The host's
;; shortest-round-trip digits are kept and only the layout is rearranged, except
;; for a subnormal (see flonum-two-digits).
;; The two significant digits nearest the finite, positive double X, as
;; (digits . point) in jolt-flonum->string's terms (value = 0.DIGITS x 10^POINT,
;; trailing zero dropped), or #f when that decimal does not read back as X.
(define (flonum-two-digits x)
  (let* ((v (exact x))
         ;; e: 10^e <= v < 10^(e+1)
         (e (let loop ((e (exact (floor (/ (log x) (log 10.0))))))
              (cond ((> (expt 10 e) v) (loop (- e 1)))
                    ((<= (expt 10 (+ e 1)) v) (loop (+ e 1)))
                    (else e))))
         (n (round (/ v (expt 10 (- e 1)))))              ; 10..100
         (point (if (= n 100) (+ e 2) (+ e 1)))
         (n (if (= n 100) 10 n)))
    (and (= (exact->inexact (* n (expt 10 (- point 2)))) x)
         (let ((s (number->string n)))
           (cons (if (char=? (string-ref s 1) #\0) (substring s 0 1) s) point)))))

;; At 16 or 17 significant digits the double can lie exactly halfway between
;; two decimals of that length that both read back as it, and the host and the
;; JVM may break that tie differently: Chez rounds it up, Double.toString to the
;; even digit (1338163280546708.25 is 1.3381632805467082E15 on the JVM,
;; -650605845684.15625 is -6.506058456841562E11). Only an odd last digit D can
;; be the wrong side of a tie, with the double exactly half a unit of the last
;; place from D; that needs x * 2^(1-p) to be an odd integer, which is checked
;; first in flonum arithmetic, so an ordinary long double costs a parity test
;; and a few float operations, never the exact arithmetic. Answers the even neighbour's digits, or
;; #f to keep the host's.
(define (flonum-long-digits x digits point)
  (let ((dlen (string-length digits)))
    (and (odd? (char->integer (string-ref digits (fx- dlen 1))))   ; #\1 is 49
         (let ((p (- point dlen)))                 ; the last digit's place
           ;; x * 2^(1-p) is an odd integer: exact in flonum arithmetic, since
           ;; scaling by a power of two only moves the exponent
           (and (if (< p 0)
                    (let ((y (* x (expt 2.0 (- 1 p)))))
                      (and (= y (round y)) (not (= (* y 0.5) (round (* y 0.5))))))
                    (and (> p 0) (integer? x)))
                (let* ((v (exact x))
                       (d (string->number digits))
                       (unit (expt 10 p))
                       (even (cond ((= v (* (- d 1/2) unit)) (- d 1))
                                   ((= v (* (+ d 1/2) unit)) (+ d 1))
                                   (else #f)))
                       (s (and even (number->string even))))
                  (and s (fx=? (string-length s) dlen)
                       (let loop ((k dlen))
                         (if (and (fx>? k 1) (char=? (string-ref s (fx- k 1)) #\0))
                             (loop (fx- k 1))
                             (substring s 0 k))))))))))

(define (jolt-flonum->string x)
  (let* ((s (number->string x))
         (neg? (char=? (string-ref s 0) #\-))
         (body0 (if neg? (substring s 1 (string-length s)) s))
         ;; Chez appends a "|prec" suffix to subnormal strings (e.g. "5e-324|1").
         ;; Strip it before the exponent substring is parsed, else string->number
         ;; misreads "-324|1" as a precision-qualified flonum (-256.0) and corrupts
         ;; the value.
         (bar (let loop ((i 0))
                (cond ((fx>=? i (string-length body0)) #f)
                      ((char=? (string-ref body0 i) #\|) i)
                      (else (loop (fx+ i 1))))))
         (body (if bar (substring body0 0 bar) body0))
         (blen (string-length body))
         (epos (let loop ((i 0))
                 (cond ((fx>=? i blen) #f)
                       ((memv (string-ref body i) '(#\e #\E)) i)
                       (else (loop (fx+ i 1))))))
         (mant (if epos (substring body 0 epos) body))
         (eexp (if epos (string->number (substring body (fx+ epos 1) blen)) 0))
         (mlen (string-length mant))
         (dot (let loop ((i 0))
                (cond ((fx>=? i mlen) #f)
                      ((char=? (string-ref mant i) #\.) i)
                      (else (loop (fx+ i 1))))))
         (digits (if dot
                     (string-append (substring mant 0 dot) (substring mant (fx+ dot 1) mlen))
                     mant))
         (point (+ (if dot dot mlen) eexp)))
    ;; normalize: drop leading zeros (adjusting the point), then trailing zeros
    (let* ((dlen0 (string-length digits))
           (lead (let loop ((i 0))
                   (if (and (fx<? i (fx- dlen0 1)) (char=? (string-ref digits i) #\0))
                       (loop (fx+ i 1)) i)))
           (digits (substring digits lead dlen0))
           (point (- point lead))
           (dlen (let loop ((i (string-length digits)))
                   (if (and (fx>? i 1) (char=? (string-ref digits (fx- i 1)) #\0))
                       (loop (fx- i 1)) i)))
           (digits (substring digits 0 dlen))
           (digits (or (and (fx>=? dlen 16) (flonum-long-digits (flabs x) digits point)) digits))
           (dlen (string-length digits))
           ;; Double.toString never prints fewer than two significant digits, and
           ;; it picks the two-digit decimal NEAREST the double rather than padding
           ;; the shortest one with a 0. For a normal double that is the same
           ;; thing; a subnormal has so few bits that it is not: MIN_VALUE is
           ;; 4.94...E-324, shortest "5" but printed 4.9E-324, and twice it is
           ;; 9.88...E-324, shortest "1" (1.0E-323) but printed 9.9E-324.
           (two (and (fx=? dlen 1) (not (string=? digits "0"))
                     (fl< (flabs x) 2.2250738585072014e-308)   ; subnormal
                     (flonum-two-digits (flabs x))))
           (digits (if two (car two) digits))
           (point (if two (cdr two) point))
           (dlen (string-length digits))
           (res (cond
                  ((string=? digits "0") "0.0")
                  ((and (>= point -2) (<= point 7))   ; 1e-3 <= |x| < 1e7
                   (cond
                     ((<= point 0)
                      (string-append "0." (make-string (- point) #\0) digits))
                     ((>= point dlen)
                      (string-append digits (make-string (- point dlen) #\0) ".0"))
                     (else (string-append (substring digits 0 point) "."
                                          (substring digits point dlen)))))
                  (else
                   (string-append (substring digits 0 1) "."
                                  (if (fx>? dlen 1) (substring digits 1 dlen) "0")
                                  "E" (number->string (- point 1)))))))
      (if neg? (string-append "-" res) res))))

(define (jolt-num->string x)
  (cond
    ;; the -e / element printer renders the infinities and NaN in READABLE form
    ;; (##Inf reads back, like Clojure's REPL/pr); str/print uses "Infinity"/"NaN"
    ;; (see jolt-str-render-one in converters.ss).
    ((and (flonum? x) (fl= x +inf.0)) "##Inf")
    ((and (flonum? x) (fl= x -inf.0)) "##-Inf")
    ((and (flonum? x) (not (fl= x x))) "##NaN")
    ;; str of a bigint has NO N suffix (BigInt.toString); only the readable
    ;; printer adds it (see jolt-pr-readable-base).
    ((fixnum? x) (jolt-fixnum->string x))
    ((and (exact? x) (integer? x)) (number->string x))
    ((flonum? x) (jolt-flonum->string x))
    (else (number->string x))))
