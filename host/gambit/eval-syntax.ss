;; eval-syntax.ss — GENERATED from host/chez/seq.ss by
;; host/gambit/gen-eval-syntax.ss (make gambitseed). Do not edit.
;; Registers seq.ss's emit-referenced macros into the interaction
;; environment so runtime-eval'd compiled code expands them (Gambit
;; eval does not see the boot unit's syntax definitions).

(eval '(define-syntax jolt-n+
  (syntax-rules ()
    ((_) 0)
    ((_ a) (jolt-add a))
    ((_ ea eb)
     (let ((a ea) (b eb))
       (if (and (number? a) (number? b)) (+ a b) (jolt-add a b))))
    ((_ a b c ...) (jolt-n+ (jolt-n+ a b) c ...))))
 (interaction-environment))

(eval '(define-syntax jolt-n-
  (syntax-rules ()
    ((_) (jolt-sub))
    ((_ a) (jolt-sub a))
    ((_ ea eb)
     (let ((a ea) (b eb))
       (if (and (number? a) (number? b)) (- a b) (jolt-sub a b))))
    ((_ a b c ...) (jolt-n- (jolt-n- a b) c ...))))
 (interaction-environment))

(eval '(define-syntax jolt-n*
  (syntax-rules ()
    ((_) 1)
    ((_ a) (jolt-mul a))
    ((_ ea eb)
     (let ((a ea) (b eb))
       (if (and (number? a) (number? b))
           (if (or (flonum? a) (flonum? b))
               (fl* (real->flonum a) (real->flonum b))
               (* a b))
           (jolt-mul a b))))
    ((_ a b c ...) (jolt-n* (jolt-n* a b) c ...))))
 (interaction-environment))

(eval '(define-syntax jolt-n-div
  (syntax-rules ()
    ((_) (jolt-div))
    ((_ a) (jolt-div a))
    ((_ a b) (jolt-div2 a b))
    ((_ a b c ...) (jolt-n-div (jolt-div2 a b) c ...))))
 (interaction-environment))

(eval '(define-syntax define-n-cmp
  (syntax-rules ()
    ((_ name op op2)
     (define-syntax name
       (syntax-rules ()
         ((_) (op2))
         ((_ a) (begin a #t))
         ((_ ea eb)
          (let ((a ea) (b eb))
            (if (and (number? a) (number? b)) (op a b) (op2 a b))))
         ((_ ea eb c (... ...))
          (let ((a ea) (b eb))
            (and (name a b) (name b c (... ...))))))))))
 (interaction-environment))

(eval '(define-n-cmp jolt-n< < jolt-lt2)
 (interaction-environment))

(eval '(define-n-cmp jolt-n> > jolt-gt2)
 (interaction-environment))

(eval '(define-n-cmp jolt-n<= <= jolt-le2)
 (interaction-environment))

(eval '(define-n-cmp jolt-n>= >= jolt-ge2)
 (interaction-environment))

(eval '(define-syntax jolt-n-min
  (syntax-rules ()
    ((_) (jolt-min))
    ((_ a) (jolt-min a))
    ((_ a b) (jolt-min2 a b))
    ((_ a b c ...) (jolt-n-min (jolt-min2 a b) c ...))))
 (interaction-environment))

(eval '(define-syntax jolt-n-max
  (syntax-rules ()
    ((_) (jolt-max))
    ((_ a) (jolt-max a))
    ((_ a b) (jolt-max2 a b))
    ((_ a b c ...) (jolt-n-max (jolt-max2 a b) c ...))))
 (interaction-environment))

(eval '(define-syntax jolt-n-inc
  (syntax-rules ()
    ((_ ea)
     (let ((a ea)) (if (number? a) (+ a 1) (jolt-inc a))))))
 (interaction-environment))

(eval '(define-syntax jolt-n-dec
  (syntax-rules ()
    ((_ ea)
     (let ((a ea)) (if (number? a) (- a 1) (jolt-dec a))))))
 (interaction-environment))

(eval '(define-syntax jolt-l-checked
  (syntax-rules ()
    ((_ e)
     (let ((r e))
       (if (fixnum? r)
           r
           (if (and (>= r l-long-min) (<= r l-long-max))
               r
               (jolt-l-overflow)))))))
 (interaction-environment))

(eval '(define-syntax define-l-binop
  (syntax-rules ()
    ((_ name fxop genop)
     (define-syntax name
       (syntax-rules ()
         ((_ a b)
          (let ((x a) (y b))
            (if (and (fixnum? x) (fixnum? y))
                (fxop x y)
                (genop x y)))))))))
 (interaction-environment))

(eval '(define-l-binop jolt-l< fx<? <)
 (interaction-environment))

(eval '(define-l-binop jolt-l<= fx<=? <=)
 (interaction-environment))

(eval '(define-l-binop jolt-l> fx>? >)
 (interaction-environment))

(eval '(define-l-binop jolt-l>= fx>=? >=)
 (interaction-environment))

(eval '(define-l-binop jolt-l= fx=? =)
 (interaction-environment))

(eval '(define-l-binop jolt-l-min fxmin min)
 (interaction-environment))

(eval '(define-l-binop jolt-l-max fxmax max)
 (interaction-environment))

(eval '(define-l-binop jolt-l-quot fxquotient quotient)
 (interaction-environment))

(eval '(define-l-binop jolt-l-rem fxremainder remainder)
 (interaction-environment))

(eval '(define-l-binop jolt-l-mod fxmodulo modulo)
 (interaction-environment))

(eval '(define-syntax jolt-l-inc
  (syntax-rules () ((_ a) (jolt-l-checked (+ a 1)))))
 (interaction-environment))

(eval '(define-syntax jolt-l-dec
  (syntax-rules () ((_ a) (jolt-l-checked (- a 1)))))
 (interaction-environment))

(eval '(define-syntax jolt-l+
  (syntax-rules () ((_ a b) (jolt-l-checked (+ a b)))))
 (interaction-environment))

(eval '(define-syntax jolt-l-
  (syntax-rules ()
    ((_ a b) (jolt-l-checked (- a b)))
    ((_ a) (jolt-l-checked (- a)))))
 (interaction-environment))

(eval '(define-syntax jolt-l*
  (syntax-rules () ((_ a b) (jolt-l-checked (* a b)))))
 (interaction-environment))

