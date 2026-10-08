;; clojure.math and java.lang.Math — one implementation for both, over the
;; host's numeric procedures. Portable: R7RS arithmetic plus jolt's own runtime
;; names, so the Chez and Gambit hosts include the same file.
;;
;; clojure.math is registered as native bindings, NOT a .clj file — so there's no
;; source tier to emit. The def-var! shims here back each clojure.math fn. The
;; analyzer knows the clojure.math ns exists, so a ref like clojure.math/sqrt
;; lowers to a var-deref; these cells back it at runtime.
;;
;; Every clojure.math result is a double (inputs arrive as flonums; the host's
;; sqrt/sin/expt/... return flonums for flonum args). Semantics match
;; Clojure 1.11 clojure.math: round = floor(x+0.5), rint = round-half-even,
;; floor/ceil/floor-div return doubles, to-degrees/to-radians via PI.

;; clojure.math's PI/E are java.lang.Math's, which the JDK defines as compile-time
;; double literals — not the host libm's atan(1)/exp(1). Pinned as literals so a
;; host whose libm rounds exp(1) one ulp high (bionic's) still answers the JVM's
;; value. java.lang.Math's PI and E below are these.
(define jolt-math-pi 3.141592653589793)
(define jolt-math-e 2.718281828459045)

(define (jolt-math-cbrt x)
  ;; sign-aware so negative inputs stay real (expt of a negative flonum to a
  ;; fractional power goes complex).
  (if (< x 0.0)
      (- (expt (- x) (/ 1.0 3.0)))
      (expt x (/ 1.0 3.0))))

;; java.lang.Math.round(double) -> long: NaN->0, +Inf->Long/MAX_VALUE, -Inf->
;; Long/MIN_VALUE, out-of-long-range saturates, and the greatest double below 0.5
;; (0.49999999999999994) rounds to 0 — its x+0.5 sums to exactly 1.0. Else (long)
;; floor(x + 0.5). clojure.math/round and Math/round both route here.
(define jolt-math-long-max 9223372036854775807)
(define jolt-math-long-min -9223372036854775808)
(define (jolt-math-round x)
  (let ((d (if (and (number? x) (real? x)) (exact->inexact x) x)))
    (cond
      ((nan? d) 0)
      ((infinite? d) (if (fl> d 0.0) jolt-math-long-max jolt-math-long-min))
      ;; 0.49999999999999994: largest double < 0.5, whose +0.5 rounds up to 1.0
      ((and (fl< d 0.5) (fl>= (fl+ d 0.5) 1.0)) 0)
      (else
       (let ((r (floor (+ d 0.5))))
         (cond ((> r jolt-math-long-max) jolt-math-long-max)
               ((< r jolt-math-long-min) jolt-math-long-min)
               (else (exact r))))))))
(define (jolt-math-to-degrees r) (/ (* r 180.0) jolt-math-pi))
(define (jolt-math-to-radians d) (/ (* d jolt-math-pi) 180.0))
;; java.lang.Math.hypot — scale by a power of 2 (exact) so a^2+b^2 can't overflow
;; before the sqrt; the only rounding is the correctly-rounded sqrt. NaN->NaN,
;; either Inf -> +Inf. (Naive sqrt(a^2+b^2) returns Inf for 3e200,4e200.)
(define (jolt-math-hypot a b)
  ;; Java Math.hypot: Inf if either is Inf (even if the other is NaN), else NaN if
  ;; either is NaN. Otherwise la * sqrt(1 + (sm/la)^2), factoring out the larger
  ;; magnitude so the squares never overflow (sm/la <= 1). This is exact for the
  ;; scaled Pythagorean cases (e.g. 3e200,4e200 -> 5e200) and within 1 ULP
  ;; elsewhere, matching Java's correctly-rounded result to ~15-16 digits.
  (cond
    ((or (infinite? a) (infinite? b)) +inf.0)
    ((or (nan? a) (nan? b)) +nan.0)
    (else
     (let* ((ax (abs a)) (bx (abs b))
            (la (max ax bx)) (sm (min ax bx)))
       (if (= la 0.0)
           0.0
           (let ((r (/ sm la)))
             (* la (sqrt (+ 1.0 (* r r))))))))))
;; java.lang.Math.expm1 — Taylor series for |x|<0.5 (where exp(x)-1 cancels badly),
;; else exp(x)-1. +Inf->+Inf, -Inf->-1.0, NaN->NaN.
(define (jolt-math-expm1 x)
  (let ((ax (abs x)))
    (cond
      ((nan? x) x)
      ((infinite? x) (if (> x 0.0) x -1.0))
      ((= x 0.0) x)                     ; expm1(0) = 0 (also ±0.0 passthrough)
      ((< ax 0.5)
       (let loop ((term x) (n 2) (acc x))
         (let* ((nt (* term (/ x n))) (acc2 (+ acc nt)))
           ;; terminate on a term that adds nothing, or is negligible relative to
           ;; the accumulator. Guard the threshold with (max 1.0 …) so an acc that
           ;; rounds toward 0 can't make the bound 0 and spin forever (expm1 0).
           (if (or (= nt 0.0) (< (abs nt) (* 1e-18 (max 1.0 (abs acc2))))) acc2
               (loop nt (+ n 1) acc2)))))
      (else (- (exp x) 1.0)))))
;; java.lang.Math.log1p — alternating series for |x|<0.3 (where 1+x rounds to 1),
;; else log(1+x). log1p(-1)->-Inf, log1p(<-1)->NaN.
(define (jolt-math-log1p x)
  (cond
    ((nan? x) x)
    ((= x -1.0) -inf.0)
    ((< x -1.0) +nan.0)
    ((< (abs x) 0.3)
     (let loop ((n 1) (xp x) (acc 0.0) (sign 1))
       (let* ((term (* sign (/ xp n))) (acc2 (+ acc term)))
         (if (< (abs term) (* 1e-18 (max 1.0 (abs acc2)))) acc2
             (loop (+ n 1) (* xp x) acc2 (- sign))))))
    (else (real-or-nan (log (+ 1.0 x))))))
;; floor-div/floor-mod take ^long args and return a long. Coerce each operand
;; toward zero (Java's ^long cast) so a double like 7.0 becomes 7, then compute
;; on exact integers so the result is a long, not a double.
(define (jolt-math-floor-div a b)
  (let ((a (exact (truncate a))) (b (exact (truncate b)))) (floor (/ a b))))
(define (jolt-math-floor-mod a b)
  (let ((a (exact (truncate a))) (b (exact (truncate b)))) (- a (* b (floor (/ a b))))))

;; --- IEEE 754 bit-level ops ---------------------------------------------------
;; The JDK defines copySign/nextUp/nextDown/nextAfter/ulp/getExponent on the raw
;; bit pattern, so -0.0 keeps its sign and a step is exactly one representable
;; double. The pattern is computed here in exact arithmetic, R7RS only, so this
;; file is the same on every host: an unsigned 64-bit integer, sign bit on top,
;; 11 exponent bits, 52 mantissa bits. For a negative double a larger pattern is
;; a larger magnitude. A NaN reads as the JVM's canonical one (sign clear): the
;; sign of a NaN is not observable without a host bit cast.
(define dbl-sign-bit (expt 2 63))
(define dbl-mant-unit (expt 2 52))
(define dbl-min-value 4.9406564584124654e-324)
(define (dbl-negative? x) (or (< x 0.0) (eqv? x -0.0)))
;; e with 2^e <= m < 2^(e+1), for an exact positive rational m
(define (dbl-binary-exponent m)
  (let loop ((e (exact (floor (log (inexact m) 2)))))
    (cond ((> (expt 2 e) m) (loop (- e 1)))
          ((<= (expt 2 (+ e 1)) m) (loop (+ e 1)))
          (else e))))
(define (dbl->bits x)
  (let ((x (exact->inexact x)))
    (+ (if (dbl-negative? x) dbl-sign-bit 0)
       (cond ((nan? x) (+ (* 2047 dbl-mant-unit) (expt 2 51)))
             ((infinite? x) (* 2047 dbl-mant-unit))
             ((= x 0.0) 0)
             (else
              (let* ((m (exact (abs x))) (e (dbl-binary-exponent m)))
                (if (>= e -1022)
                    (+ (* (+ e 1023) dbl-mant-unit) (- (* m (expt 2 (- 52 e))) dbl-mant-unit))
                    (* m (expt 2 1074)))))))))          ; subnormal
(define (bits->dbl b)
  (let* ((r (bitwise-and b #x7fffffffffffffff))
         (field (bitwise-arithmetic-shift-right r 52))
         (mant (bitwise-and r #xfffffffffffff))
         (mag (cond ((= field 2047) (if (= mant 0) +inf.0 +nan.0))
                    ((= field 0) (exact->inexact (* mant (expt 2 -1074))))
                    (else (exact->inexact (* (+ dbl-mant-unit mant) (expt 2 (- field 1075))))))))
    (if (>= b dbl-sign-bit) (- mag) mag)))

(define (jolt-math-copy-sign m s)
  (let* ((m (exact->inexact (jolt-need-num m)))
         (a (if (dbl-negative? m) (- m) m)))
    (if (dbl-negative? (exact->inexact (jolt-need-num s))) (- a) a)))

;; Math.signum: NaN and both zeros come back as themselves
(define (jolt-math-signum x)
  (let ((x (exact->inexact (jolt-need-num x))))
    (cond ((nan? x) x) ((> x 0.0) 1.0) ((< x 0.0) -1.0) (else x))))

;; one representable double up / down; d+0.0 folds -0.0 into 0.0 first, as the
;; JDK does, so both zeros step to the same neighbour
(define (jolt-math-next-up x)
  (let ((d (+ (exact->inexact (jolt-need-num x)) 0.0)))
    (cond ((or (nan? d) (= d +inf.0)) d)
          ((= d 0.0) dbl-min-value)
          (else (bits->dbl (if (> d 0.0) (+ (dbl->bits d) 1) (- (dbl->bits d) 1)))))))
(define (jolt-math-next-down x)
  (let ((d (+ (exact->inexact (jolt-need-num x)) 0.0)))
    (cond ((or (nan? d) (= d -inf.0)) d)
          ((= d 0.0) (- dbl-min-value))
          (else (bits->dbl (if (> d 0.0) (- (dbl->bits d) 1) (+ (dbl->bits d) 1)))))))
(define (jolt-math-next-after start direction)
  (let ((s (exact->inexact (jolt-need-num start)))
        (d (exact->inexact (jolt-need-num direction))))
    (cond ((> s d) (jolt-math-next-down s))
          ((< s d) (jolt-math-next-up s))
          ((= s d) d)
          (else (+ s d)))))                        ; a NaN

;; Math.getExponent: the unbiased exponent field; 1024 for Inf/NaN, -1023 for
;; zero and subnormals
(define (jolt-math-get-exponent x)
  (- (quotient (modulo (dbl->bits (jolt-need-num x)) dbl-sign-bit) dbl-mant-unit) 1023))

;; Math.ulp: the gap to the next double away from zero
(define (jolt-math-ulp x)
  (let* ((d (exact->inexact (jolt-need-num x))) (e (jolt-math-get-exponent d)))
    (cond ((= e 1024) (abs d))                     ; Inf -> Inf, NaN -> NaN
          ((= e -1023) dbl-min-value)              ; zero, subnormal
          (else (exact->inexact (expt 2 (- e 52)))))))

;; Math.scalb: d * 2^n rounded once, in exact arithmetic so a result that lands
;; among the subnormals rounds as the JDK's does. n is clamped first: past
;; +/-2200 every finite non-zero d has already overflowed or underflowed.
(define (jolt-math-scalb x n)
  (let ((d (exact->inexact (jolt-need-num x)))
        (n (max -2200 (min 2200 (exact (truncate (jolt-need-num n)))))))
    (if (or (nan? d) (infinite? d) (= d 0.0))
        d
        (let ((r (exact->inexact (* (exact d) (expt 2 n)))))
          (if (= r 0.0) (jolt-math-copy-sign 0.0 d) r)))))

;; Math.IEEEremainder: x - y*n with n = x/y rounded half-even, exactly. A zero
;; result takes x's sign.
(define (jolt-math-ieee-remainder x y)
  (let ((x (exact->inexact (jolt-need-num x))) (y (exact->inexact (jolt-need-num y))))
    (cond ((or (nan? x) (nan? y) (infinite? x) (= y 0.0)) +nan.0)
          ((infinite? y) x)
          (else
           (let* ((ex (exact x)) (ey (exact y))
                  (r (exact->inexact (- ex (* ey (round (/ ex ey)))))))
             (if (= r 0.0) (jolt-math-copy-sign 0.0 x) r))))))

;; Math.max / Math.min: a double argument makes it the double overload, where NaN
;; wins and -0.0 is below 0.0; two integers compare as longs. Two distinct
;; ordered doubles take one compare; the zero and NaN rules only run on a tie or
;; an unordered pair.
(define (jolt-math-max a b)
  (if (and (flonum? a) (flonum? b))
      (cond ((fl> a b) a)
            ((fl< a b) b)
            ((fl= a b) (if (dbl-negative? a) b a))        ; equal: only ±0.0 differ
            ((nan? a) a)
            (else b))
      (if (or (flonum? a) (flonum? b))
          (jolt-math-max (exact->inexact a) (exact->inexact b))
          (if (> a b) a b))))
(define (jolt-math-min a b)
  (if (and (flonum? a) (flonum? b))
      (cond ((fl< a b) a)
            ((fl> a b) b)
            ((fl= a b) (if (dbl-negative? a) a b))
            ((nan? a) a)
            (else b))
      (if (or (flonum? a) (flonum? b))
          (jolt-math-min (exact->inexact a) (exact->inexact b))
          (if (< a b) a b))))

;; Math.addExact and kin over longs: the exact result, or ArithmeticException
;; "long overflow" when it leaves the long range
(define (jolt-math-long-exact r)
  (if (and (>= r -9223372036854775808) (<= r 9223372036854775807))
      r
      (throw-jvm 'ArithmeticException "long overflow")))
(define (exact-long x) (exact (truncate (jolt-need-num x))))
(define (jolt-math-add-exact a b) (jolt-math-long-exact (+ (exact-long a) (exact-long b))))
(define (jolt-math-subtract-exact a b) (jolt-math-long-exact (- (exact-long a) (exact-long b))))
(define (jolt-math-multiply-exact a b) (jolt-math-long-exact (* (exact-long a) (exact-long b))))
(define (jolt-math-increment-exact a) (jolt-math-long-exact (+ (exact-long a) 1)))
(define (jolt-math-decrement-exact a) (jolt-math-long-exact (- (exact-long a) 1)))
(define (jolt-math-negate-exact a) (jolt-math-long-exact (- (exact-long a))))

;; clojure.math fns always return a DOUBLE; Chez's sqrt/expt/sin/floor/... return
;; EXACT for exact args ((sqrt 9) -> 3, (sin 0) -> 0), so coerce.
(define (m1 f) (lambda (x) (exact->inexact (f (jolt-need-num x)))))
(define (m2 f) (lambda (a b) (exact->inexact (f (jolt-need-num a) (jolt-need-num b)))))
;; a real result stays a flonum; a complex result becomes +nan.0. Chez extends
;; several real-domain ops (sqrt/expt/log/asin/acos, and log's kin log10/log1p)
;; onto the complex plane for out-of-domain real inputs, but Java/clojure.math
;; returns NaN there. real? is #t for a flonum and #f for a Chez complex, so this
;; guards exactly the complex leak; NaN/Inf are real and pass through unchanged.
(define (real-or-nan x) (if (and (number? x) (real? x)) (exact->inexact x) +nan.0))
(define (m1c f) (lambda (x) (real-or-nan (f (jolt-need-num x)))))
(define (m2c f) (lambda (a b) (real-or-nan (f (jolt-need-num a) (jolt-need-num b)))))
(def-var! "clojure.math" "sqrt" (m1c sqrt))
(def-var! "clojure.math" "cbrt" jolt-math-cbrt)
(def-var! "clojure.math" "pow" (m2c expt))
(def-var! "clojure.math" "exp" (m1 exp))
(def-var! "clojure.math" "expm1" jolt-math-expm1)
(def-var! "clojure.math" "log" (m1c log))
;; base-10 log via Chez's base-arg log — also backs java.lang.Math/log10 so the
;; two never disagree.
(define (jolt-math-log10 x) (real-or-nan (log x 10.0)))
(def-var! "clojure.math" "log10" jolt-math-log10)
(def-var! "clojure.math" "log1p" jolt-math-log1p)
(def-var! "clojure.math" "sin" (m1 sin))
(def-var! "clojure.math" "cos" (m1 cos))
(def-var! "clojure.math" "tan" (m1 tan))
(def-var! "clojure.math" "asin" (m1c asin))
(def-var! "clojure.math" "acos" (m1c acos))
(def-var! "clojure.math" "atan" (m1 atan))
;; clojure.math/atan2 is atan2(y, x); Chez's 2-arg atan is (atan y x).
(def-var! "clojure.math" "atan2" (lambda (y x) (exact->inexact (atan y x))))
(def-var! "clojure.math" "sinh" (m1 sinh))
(def-var! "clojure.math" "cosh" (m1 cosh))
(def-var! "clojure.math" "tanh" (m1 tanh))
(def-var! "clojure.math" "floor" (m1 floor))
(def-var! "clojure.math" "ceil" (m1 ceiling))
(def-var! "clojure.math" "rint" (m1 round))
(def-var! "clojure.math" "round" jolt-math-round)
(def-var! "clojure.math" "signum" jolt-math-signum)
(def-var! "clojure.math" "to-degrees" jolt-math-to-degrees)
(def-var! "clojure.math" "to-radians" jolt-math-to-radians)
(def-var! "clojure.math" "hypot" jolt-math-hypot)
(def-var! "clojure.math" "floor-div" jolt-math-floor-div)
(def-var! "clojure.math" "floor-mod" jolt-math-floor-mod)
(def-var! "clojure.math" "E" jolt-math-e)
(def-var! "clojure.math" "PI" jolt-math-pi)
(def-var! "clojure.math" "IEEE-remainder" jolt-math-ieee-remainder)
(def-var! "clojure.math" "copy-sign" jolt-math-copy-sign)
(def-var! "clojure.math" "get-exponent" jolt-math-get-exponent)
(def-var! "clojure.math" "next-after" jolt-math-next-after)
(def-var! "clojure.math" "next-up" jolt-math-next-up)
(def-var! "clojure.math" "next-down" jolt-math-next-down)
(def-var! "clojure.math" "ulp" jolt-math-ulp)
(def-var! "clojure.math" "scalb" jolt-math-scalb)
(def-var! "clojure.math" "random" (lambda () (jolt-random 1.0)))
(def-var! "clojure.math" "add-exact" jolt-math-add-exact)
(def-var! "clojure.math" "subtract-exact" jolt-math-subtract-exact)
(def-var! "clojure.math" "multiply-exact" jolt-math-multiply-exact)
(def-var! "clojure.math" "increment-exact" jolt-math-increment-exact)
(def-var! "clojure.math" "decrement-exact" jolt-math-decrement-exact)
(def-var! "clojure.math" "negate-exact" jolt-math-negate-exact)

;; ---- java.lang.Math -------------------------------------------------------
;; java.lang.Math: sqrt/pow/floor/ceil/trig/log/exp always return a DOUBLE on the
;; JVM (Chez's sqrt/expt return EXACT for exact args, e.g. (sqrt 9) -> 3), so coerce
;; to flonum. round -> long (exact); abs/max/min preserve the argument's type.
(define (->dbl x) (exact->inexact (jolt-need-num x)))
;; Every Math method takes numbers (PI/E are values, not methods), and each one
;; hands its argument to a host numeric primitive. Check at the boundary: the
;; condition Chez raises for a wrong-typed operand carries no class, so it would
;; escape as #object[:object] with no catch clause able to select it. The hot path
;; does not come through here — a Math call over proven flonums lowers to a native
;; Chez flonum op (jolt.passes.numeric).
(define (math-checked entry)
  (let ((f (cdr entry)))
    (if (procedure? f)
        (cons (car entry)
              (host-arity-like f (lambda args (apply f (map jolt-need-num args)))))
        entry)))
(register-class-statics! "Math"
  (map math-checked
  (list (cons "sqrt" (lambda (x) (real-or-nan (sqrt x))))
        ;; cbrt/log10 (and hypot/expm1/log1p below) share the clojure.math impls
        ;; above so Math/x and clojure.math/x never diverge.
        (cons "cbrt" (lambda (x) (jolt-math-cbrt (->dbl x))))
        (cons "pow" (lambda (a b) (real-or-nan (expt a b))))
        ;; hypot/expm1/log1p route to the numerically-stable clojure.math impls
        ;; so Math/hypot doesn't overflow and expm1/log1p keep
        ;; full precision near zero.
        (cons "hypot" (lambda (a b) (jolt-math-hypot (->dbl a) (->dbl b))))
        (cons "floor" (lambda (x) (->dbl (floor x))))
        (cons "ceil" (lambda (x) (->dbl (ceiling x))))
        (cons "round" (lambda (x) (jolt-math-round x)))     ; JVM Math.round -> long (NaN/Inf/saturate/half-up)
        (cons "rint" (lambda (x) (->dbl (round x))))            ; round-half-even -> double
        ;; Math.floorDiv/floorMod: integer floor division / modulus (long -> long).
        (cons "floorDiv" (lambda (a b) (exact (floor (/ a b)))))
        (cons "floorMod" (lambda (a b) (exact (- a (* b (floor (/ a b)))))))
        (cons "abs" (lambda (x) (abs x)))
        (cons "sin" (lambda (x) (->dbl (sin x)))) (cons "cos" (lambda (x) (->dbl (cos x))))
        (cons "tan" (lambda (x) (->dbl (tan x)))) (cons "asin" (lambda (x) (real-or-nan (asin x))))
        (cons "acos" (lambda (x) (real-or-nan (acos x)))) (cons "atan" (lambda (x) (->dbl (atan x))))
        ;; Math.atan2(y, x) — Chez's 2-arg atan is (atan y x).
        (cons "atan2" (lambda (y x) (->dbl (atan y x))))
        (cons "sinh" (lambda (x) (->dbl (sinh x)))) (cons "cosh" (lambda (x) (->dbl (cosh x))))
        (cons "tanh" (lambda (x) (->dbl (tanh x))))
        (cons "log" (lambda (x) (real-or-nan (log x)))) (cons "log10" (lambda (x) (jolt-math-log10 (->dbl x))))
        (cons "log1p" (lambda (x) (jolt-math-log1p (->dbl x))))
        (cons "exp" (lambda (x) (->dbl (exp x))))
        (cons "expm1" (lambda (x) (jolt-math-expm1 (->dbl x))))
        (cons "toRadians" (lambda (d) (->dbl (/ (* d jolt-math-pi) 180.0))))
        (cons "toDegrees" (lambda (r) (->dbl (/ (* r 180.0) jolt-math-pi))))
        (cons "copySign" (lambda (m s) (jolt-math-copy-sign m s)))
        ;; the IEEE 754 bit-level ops and the exact long arithmetic, shared with
        ;; clojure.math; test.check's double generator uses
        ;; getExponent and scalb
        (cons "getExponent" (lambda (x) (jolt-math-get-exponent x)))
        (cons "scalb" (lambda (x n) (jolt-math-scalb x n)))
        (cons "nextUp" (lambda (x) (jolt-math-next-up x)))
        (cons "nextDown" (lambda (x) (jolt-math-next-down x)))
        (cons "nextAfter" (lambda (s d) (jolt-math-next-after s d)))
        (cons "ulp" (lambda (x) (jolt-math-ulp x)))
        (cons "IEEEremainder" (lambda (x y) (jolt-math-ieee-remainder x y)))
        (cons "addExact" (lambda (a b) (jolt-math-add-exact a b)))
        (cons "subtractExact" (lambda (a b) (jolt-math-subtract-exact a b)))
        (cons "multiplyExact" (lambda (a b) (jolt-math-multiply-exact a b)))
        (cons "incrementExact" (lambda (a) (jolt-math-increment-exact a)))
        (cons "decrementExact" (lambda (a) (jolt-math-decrement-exact a)))
        (cons "negateExact" (lambda (a) (jolt-math-negate-exact a)))
        (cons "max" (lambda (a b) (jolt-math-max a b))) (cons "min" (lambda (a b) (jolt-math-min a b)))
        (cons "signum" (lambda (x) (jolt-math-signum x)))
        (cons "PI" jolt-math-pi) (cons "E" jolt-math-e)
        (cons "random" (lambda args (jolt-random 1.0))))))

;; ---- Double / Float bit casts -----------------------------------------------
;; Over the bit patterns above, as the JVM's signed long/int. doubleToLongBits
;; folds every NaN into the canonical 0x7ff8000000000000; the raw form would keep
;; a NaN's payload, which no host here exposes, so the two agree.
(define (unsigned->signed u width)
  (if (>= u (expt 2 (- width 1))) (- u (expt 2 width)) u))
(define (jolt-double->long-bits x)
  (unsigned->signed (dbl->bits (jolt-need-num x)) 64))
(define (jolt-long-bits->double n)
  (bits->dbl (modulo (exact (jolt-need-num n)) (expt 2 64))))

;; Float: the argument is cast like (float x) (RT.floatCast: past Float/MAX_VALUE,
;; an infinity included, is IllegalArgumentException), rounded once to single
;; precision (8 exponent bits, 23 mantissa bits, half-even), then encoded.
(define (flt->bits x)
  (let ((x (jolt-double x)))
    (+ (if (dbl-negative? x) (expt 2 31) 0)
       (cond ((nan? x) #x7fc00000)
             ((infinite? x) #x7f800000)
             ((= x 0.0) 0)
             (else (flt-mag->bits (exact (abs x))))))))
;; The pattern, sign clear, of an exact positive rational M rounded once to
;; single precision. Taking M exact rather than a double is what lets a caller
;; ask about a decimal without rounding it to a double first (byte-buffer.ss
;; finding the shortest digits of a float).
(define (flt-mag->bits m)
  (let ((e (dbl-binary-exponent m)))
    (if (>= e -126)
        (let* ((q (round (* m (expt 2 (- 23 e)))))   ; 2^23..2^24
               (e (if (= q (expt 2 24)) (+ e 1) e))
               (q (if (= q (expt 2 24)) (expt 2 23) q)))
          (if (> e 127)
              #x7f800000
              (+ (* (+ e 127) (expt 2 23)) (- q (expt 2 23)))))
        ;; subnormal; a round up to 2^23 is the smallest normal's
        ;; pattern, which the sum already spells
        (round (* m (expt 2 149))))))
(define (bits->flt b)
  (let* ((r (bitwise-and b #x7fffffff))
         (field (bitwise-arithmetic-shift-right r 23))
         (mant (bitwise-and r #x7fffff))
         (mag (cond ((= field 255) (if (= mant 0) +inf.0 +nan.0))
                    ((= field 0) (exact->inexact (* mant (expt 2 -149))))
                    (else (exact->inexact (* (+ (expt 2 23) mant) (expt 2 (- field 150))))))))
    (if (>= b (expt 2 31)) (- mag) mag)))
(define (jolt-float->int-bits x) (unsigned->signed (flt->bits (jolt-float->flonum x)) 32))
(define (jolt-int-bits->float n)
  (make-jfloat (bits->flt (modulo (exact (jolt-need-num n)) (expt 2 32)))))

(register-class-statics! "Double"
  (list (cons "doubleToLongBits" (lambda (x) (jolt-double->long-bits x)))
        (cons "doubleToRawLongBits" (lambda (x) (jolt-double->long-bits x)))
        (cons "longBitsToDouble" (lambda (n) (jolt-long-bits->double n)))))
;; Float.toString: the shortest decimal that reads back as the float, which is
;; not a double's shortest digits now that (float 0.1) holds the float's exact
;; value 0.10000000149011612. Float.toString writes at least one digit after
;; the point, so in its scientific range (below 10^-3, from 10^7) the shortest
;; form has two significant digits: Float.MIN_VALUE is 1.4E-45, never 1.0E-45.
;; Answers the decimal as a double, whose own printing then spells it.
(define (flt-shortest x)
  (let ((x (jolt-unchecked-float->flonum x)))
    (if (or (nan? x) (infinite? x) (= x 0.0))
        x
        (let* ((m (exact (abs x)))
               (bits (flt-mag->bits m))
               (e10 (let loop ((e (exact (floor (/ (log (inexact m)) (log 10))))))
                      (cond ((> (expt 10 e) m) (loop (- e 1)))
                            ((<= (expt 10 (+ e 1)) m) (loop (+ e 1)))
                            (else e))))
               (d (let loop ((n (if (or (< m 1/1000) (>= m 10000000)) 2 1)))
                    (if (> n 9)
                        (inexact m)
                        (let* ((s (expt 10 (- e10 (- n 1))))
                               (cand (* (round (/ m s)) s)))
                          (if (and (> cand 0) (= (flt-mag->bits cand) bits))
                              (inexact cand)
                              (loop (+ n 1))))))))
          (if (< x 0.0) (- d) d)))))
;; Float.parseFloat/valueOf: the parsed double rounded to single precision, past
;; the float range an infinity (a parse does not range-check like the cast).
(define (jolt-parse-float s)
  (if (or (number? s) (jfloat? s))
      (make-jfloat (jolt-unchecked-float->flonum s))
      (make-jfloat (flsingle (parse-double-or-throw s)))))
;; Float.compare: numeric order, then -0.0 below 0.0 and NaN above everything,
;; which is the order of the signed bit patterns.
(define (jolt-float-compare a b)
  (let ((x (jolt-float->flonum a)) (y (jolt-float->flonum b)))
    (cond ((< x y) -1)
          ((> x y) 1)
          (else (let ((bx (unsigned->signed (flt->bits x) 32))
                      (by (unsigned->signed (flt->bits y) 32)))
                  (cond ((= bx by) 0) ((< bx by) -1) (else 1)))))))

(register-class-statics! "Float"
  (list (cons "parseFloat" jolt-parse-float) (cons "valueOf" jolt-parse-float)
        (cons "toString" (lambda (x) (jolt-str-render-one (flt-shortest x))))
        (cons "compare" jolt-float-compare)
        (cons "isNaN" (lambda (x) (nan? (jolt-double x))))
        (cons "isInfinite" (lambda (x) (infinite? (jolt-double x))))
        ;; Floats, as on the JVM: (str Float/MAX_VALUE) is 3.4028235E38
        (cons "MAX_VALUE" (make-jfloat 3.4028234663852886e38))
        (cons "MIN_VALUE" (make-jfloat 1.401298464324817e-45))
        (cons "MIN_NORMAL" (make-jfloat 1.1754943508222875e-38))
        (cons "POSITIVE_INFINITY" (make-jfloat +inf.0))
        (cons "NEGATIVE_INFINITY" (make-jfloat -inf.0))
        (cons "NaN" (make-jfloat +nan.0))
        (cons "floatToIntBits" (lambda (x) (jolt-float->int-bits x)))
        (cons "floatToRawIntBits" (lambda (x) (jolt-float->int-bits x)))
        (cons "intBitsToFloat" (lambda (n) (jolt-int-bits->float n)))))
