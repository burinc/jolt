;; float.ss — java.lang.Float as a jolt value (the jfloat record, converters.ss).
;;
;; A Float holds a single-precision value, which jolt keeps as the flonum it
;; widens to. What makes it a Float rather than that double is everything a
;; program can observe besides the value, and this file registers each with
;; the hook that owns it, as java/bigdec.ss does for BigDecimal:
;;   - arithmetic widens to double, as the JVM's Numbers ops do for a Float
;;     ((+ (float 0.5) 1) is the Double 1.5, (+ (float 0.1) (float 0.2)) a
;;     Double too); quot/rem/mod, the sign tests and inc/dec likewise.
;;   - = is Numbers.equiv: a float equals a float or a double of the same value
;;     ((= (float 0.5) 0.5) is true, (= (float 0.1) 0.1) false) and never an
;;     integer, ratio or bigdec. == compares values across the tower.
;;   - str and pr print Float.toString's digits: the shortest decimal that
;;     reads back as the float, so (float 0.1) prints 0.1.
;;   - hash is Numbers.hasheq's Float case, Float.hashCode (floatToIntBits) with
;;     -0.0 at 0, so it is not a double's hash, as on the JVM.
;;   - class is java.lang.Float; float? is true, double? false.
;; Shared by the Chez and Gambit hosts.

(define (jfloat-either? a b) (or (jfloat? a) (jfloat? b)))

;; --- numeric tower -----------------------------------------------------------
;; Each slow hook sees a jfloat operand, unboxes both sides and asks the full
;; op again, so the double then meets whatever the other side is (a bigdec
;; included) by the ordinary rules.
(register-num-arm! 'num-slow? (lambda (prev) (lambda (x) (or (jfloat? x) (prev x)))))
(define (jfloat-num-arm op redo)
  (register-num-arm! op
    (lambda (prev)
      (lambda (a b)
        (if (jfloat-either? a b) (redo (jfloat-unbox a) (jfloat-unbox b)) (prev a b))))))
(jfloat-num-arm 'add-slow jolt-add2)
(jfloat-num-arm 'sub-slow jolt-sub2)
(jfloat-num-arm 'mul-slow jolt-mul2)
(jfloat-num-arm 'div-slow jolt-div2)
(jfloat-num-arm 'quot-slow jolt-quot)
(jfloat-num-arm 'rem-slow jolt-rem)
(jfloat-num-arm 'mod-slow jolt-mod)
(jfloat-num-arm 'num-cmp-slow
  (lambda (a b)
    (if (and (number? a) (number? b)) (jolt-cmp3 a b) (jolt-num-cmp-slow a b))))
(jfloat-num-arm 'num-equiv-slow jolt-num-equiv-slow)
(define (jfloat-unary-arm op)
  (register-num-arm! op (lambda (prev) (lambda (x) (prev (jfloat-unbox x))))))
(for-each jfloat-unary-arm '(inc dec zero? pos? neg?))
(register-num-arm! 'number? (lambda (prev) (lambda (x) (or (jfloat? x) (prev x)))))
(def-var! "clojure.core" "number?" jolt-number?)
(def-var! "clojure.core" "inc" jolt-inc)
(def-var! "clojure.core" "dec" jolt-dec)
(def-var! "clojure.core" "zero?" jolt-zero?)
(def-var! "clojure.core" "pos?" jolt-pos?)
(def-var! "clojure.core" "neg?" jolt-neg?)
;; (long (float 2.7)) is 2: RT.longCast takes a Float through its doubleValue,
;; so a NaN is 0 and the narrow cast range-checks what is left.
(register-num-arm! 'cast-truncate-slow
  (lambda (prev)
    (lambda (x)
      (if (jfloat? x)
          (let ((d (jfloat-fl x)))
            (cond ((nan? d) 0)
                  ((infinite? d) (if (> d 0.0) (expt 2 64) (- (expt 2 64))))
                  (else (exact (truncate d)))))
          (prev x)))))

;; --- equality, ordering, hashing ---------------------------------------------
(define (jfloat-floating? x) (or (flonum? x) (jfloat? x)))
(register-eq-arm! jfloat-either?
  (lambda (a b)
    (and (jfloat-floating? a) (jfloat-floating? b)
         (= (jfloat-unbox a) (jfloat-unbox b)))))
(register-compare-arm! jfloat-either?
  (lambda (a b) (jolt-compare (jfloat-unbox a) (jfloat-unbox b))))
(define (jfloat-hasheq x)
  (let ((d (jfloat-fl x)))
    (if (= d 0.0) 0 (unsigned->signed (flt->bits d) 32))))
(register-hash-arm! jfloat? jfloat-hasheq)

;; --- printing and class ------------------------------------------------------
(define (jfloat->string x) (jolt-str-render-one (flt-shortest (jfloat-fl x))))
(register-str-render! jfloat? jfloat->string)
(register-pr-arm! jfloat?
  (lambda (x)
    (let ((d (jfloat-fl x)))
      (cond ((nan? d) "##NaN")
            ((fl= d +inf.0) "##Inf")
            ((fl= d -inf.0) "##-Inf")
            (else (jfloat->string x))))))
(register-class-arm! jfloat? (lambda (x) "java.lang.Float"))

;; --- instance members ----------------------------------------------------------
;; java.lang.Float's own methods. The integral projections truncate like the
;; casts; floatValue is the Float itself.
(define (jfloat->long x)
  (let ((d (jfloat-fl x)))
    (cond ((nan? d) 0)
          ((>= d 9223372036854775807.0) 9223372036854775807)
          ((<= d -9223372036854775808.0) -9223372036854775808)
          (else (exact (truncate d))))))
(define (jfloat->int x)
  (let ((n (jfloat->long x)))
    (max -2147483648 (min 2147483647 n))))
(define jfloat-instance-tbl (make-hashtable string-hash string=?))
(for-each (lambda (p) (hashtable-set! jfloat-instance-tbl (car p) (cdr p)))
  (list (cons "doubleValue" jfloat-fl)
        (cons "floatValue" (lambda (x) x))
        (cons "longValue" jfloat->long)
        (cons "intValue" jfloat->int)
        (cons "shortValue" (lambda (x) (unsigned->signed (bitwise-and (jfloat->int x) #xffff) 16)))
        (cons "byteValue" (lambda (x) (unsigned->signed (bitwise-and (jfloat->int x) #xff) 8)))
        (cons "isNaN" (lambda (x) (nan? (jfloat-fl x))))
        (cons "isInfinite" (lambda (x) (infinite? (jfloat-fl x))))
        (cons "compareTo" (lambda (x y) (jolt-float-compare x y)))
        ;; Float.equals: another Float with the same bits, so never a Double
        (cons "equals" (lambda (x y) (and (jfloat? y) (= (flt->bits (jfloat-fl x)) (flt->bits (jfloat-fl y))))))
        (cons "hashCode" (lambda (x) (unsigned->signed (flt->bits (jfloat-fl x)) 32)))
        (cons "toString" jfloat->string)))
(register-method-arm! arm-priority-float
  (lambda (obj method-name rest-args)
    (if (jfloat? obj)
        (let ((f (hashtable-ref jfloat-instance-tbl method-name #f)))
          (if f
              (apply f obj (if (jolt-nil? rest-args) '() (seq->list rest-args)))
              'pass))
        'pass)))

;; --- java.lang.Math's float overloads ------------------------------------------
;; A Float argument picks Math's float overload where there is one, so the answer
;; is a Float computed at single precision: (Math/ulp (float 2.5)) is the gap to
;; the next FLOAT, 2.3841858E-7, not the next double. round(float) is an int.
;; Anything else (a double among the arguments, or a method with no float
;; overload) keeps the double path in java/math.ss.
(define flt-min-value 1.401298464324817e-45)
(define (flt-of-bits b) (jfloat-fl (jolt-int-bits->float b)))
(define (flt-bits x) (flt->bits x))
;; the unbiased exponent field of a float's pattern: 128 for Inf/NaN, -127 for
;; zero and subnormals
(define (flt-exponent d)
  (- (bitwise-and (bitwise-arithmetic-shift-right (flt-bits d) 23) #xff) 127))
(define (flt-next-up d)
  (let ((d (+ d 0.0)))
    (cond ((or (nan? d) (= d +inf.0)) d)
          ((= d 0.0) flt-min-value)
          ((> d 0.0) (flt-of-bits (+ (flt-bits d) 1)))
          (else (flt-of-bits (- (flt-bits d) 1))))))
(define (flt-next-down d)
  (let ((d (+ d 0.0)))
    (cond ((or (nan? d) (= d -inf.0)) d)
          ((= d 0.0) (- flt-min-value))
          ((> d 0.0) (flt-of-bits (- (flt-bits d) 1)))
          (else (flt-of-bits (+ (flt-bits d) 1))))))
(define (flt-ulp d)
  (let ((e (flt-exponent d)))
    (cond ((= e 128) (abs d))
          ((= e -127) flt-min-value)
          (else (exact->inexact (expt 2 (- e 23)))))))
(define (flt-result d) (make-jfloat (jolt-unchecked-float->flonum d)))
(define (math-float-overload name double-impl float-impl)
  (cons name
        (lambda (x)
          (if (jfloat? x) (float-impl (jfloat-fl x)) (double-impl (jolt-need-num x))))))
(define (math-float-overload2 name double-impl float-impl)
  (cons name
        (lambda (x y)
          (if (jfloat? x) (float-impl (jfloat-fl x) y) (double-impl (jolt-need-num x) (jolt-need-num y))))))
(define (both-floats name double-impl float-impl)
  (cons name
        (lambda (a b)
          (if (and (jfloat? a) (jfloat? b))
              (make-jfloat (float-impl (jfloat-fl a) (jfloat-fl b)))
              (double-impl (jolt-need-num a) (jolt-need-num b))))))
(register-class-statics! "Math"
  (list
    (math-float-overload "abs" abs (lambda (d) (make-jfloat (abs d))))
    (math-float-overload "signum" jolt-math-signum (lambda (d) (make-jfloat (jolt-math-signum d))))
    (math-float-overload "ulp" jolt-math-ulp (lambda (d) (make-jfloat (flt-ulp d))))
    (math-float-overload "nextUp" jolt-math-next-up (lambda (d) (make-jfloat (flt-next-up d))))
    (math-float-overload "nextDown" jolt-math-next-down (lambda (d) (make-jfloat (flt-next-down d))))
    (math-float-overload "getExponent" jolt-math-get-exponent flt-exponent)
    ;; Math.round(float): an int, so past the int range it saturates there
    (math-float-overload "round" jolt-math-round
      (lambda (d) (max -2147483648 (min 2147483647 (jolt-math-round d)))))
    ;; nextAfter(float, double) and scalb(float, int): the second argument is
    ;; whatever it is, the result a float
    (math-float-overload2 "nextAfter" jolt-math-next-after
      (lambda (d dir)
        (let ((dir (jolt-double dir)))
          (make-jfloat
            (cond ((> d dir) (flt-next-down d))
                  ((< d dir) (flt-next-up d))
                  ((= d dir) (jolt-unchecked-float->flonum dir))
                  (else (+ d dir)))))))
    (math-float-overload2 "scalb" jolt-math-scalb
      (lambda (d n) (flt-result (jolt-math-scalb d n))))
    (both-floats "max" jolt-math-max jolt-math-max)
    (both-floats "min" jolt-math-min jolt-math-min)
    (both-floats "copySign" jolt-math-copy-sign jolt-math-copy-sign)))
