;; fi-defaults.ss — the java.util.function interfaces' default and static methods.
;;
;; On the JVM every Predicate has negate/and/or, every Function andThen/compose,
;; every Consumer andThen, whatever implements it: a lambda, a reify, or the
;; adapter Clojure 1.12 wraps a fn in for a ^Predicate-hinted local. Here an
;; interface's defaults are registered against its NAME and found through the
;; receiver's class graph (value-host-tags) at the end of the dispatch chain
;; (dispatch-miss, records-dispatch.ss), so a reify or deftype that declares the
;; interface answers them unless it defines the method itself.
;;
;; What a default answers is again an instance of a functional interface: a jhost
;; tagged "fi-lambda:<interface>" over a Scheme procedure (jolt-fi-call calls it
;; directly). Its class is <interface>$$Lambda, a subtype of the interface, so
;; instance? holds and its own defaults chain: (.negate (.and p q)).
;;
;; Loaded after host-static-classes.ss (register-class-statics!) and
;; class-hierarchy.ss (jhost-tag->fqn).

;; interface -> (abstract method name, its argument count)
(define fi-iface-methods
  '(("java.util.function.Function" "apply" 1)
    ("java.util.function.BiFunction" "apply" 2)
    ("java.util.function.UnaryOperator" "apply" 1)
    ("java.util.function.BinaryOperator" "apply" 2)
    ("java.util.function.Predicate" "test" 1)
    ("java.util.function.BiPredicate" "test" 2)
    ("java.util.function.IntPredicate" "test" 1)
    ("java.util.function.LongPredicate" "test" 1)
    ("java.util.function.DoublePredicate" "test" 1)
    ("java.util.function.Consumer" "accept" 1)
    ("java.util.function.BiConsumer" "accept" 2)
    ("java.util.function.IntConsumer" "accept" 1)
    ("java.util.function.LongConsumer" "accept" 1)
    ("java.util.function.DoubleConsumer" "accept" 1)
    ("java.util.function.Supplier" "get" 0)
    ("java.util.function.IntUnaryOperator" "applyAsInt" 1)
    ("java.util.function.LongUnaryOperator" "applyAsLong" 1)
    ("java.util.function.DoubleUnaryOperator" "applyAsDouble" 1)))

(define (fi-lambda-tag iface) (string-append "fi-lambda:" iface))
(define (make-fi-lambda iface proc) (make-jhost (fi-lambda-tag iface) (vector proc)))

;; Each interface's lambda class: the tag's class, a subtype of the interface,
;; answering the abstract method by calling its procedure. Fixed arities, so the
;; host-method arity check reads the method's real shape.
(for-each
 (lambda (e)
   (let* ((iface (car e)) (tag (fi-lambda-tag iface)) (fqn (string-append iface "$$Lambda")))
     (hashtable-set! jhost-tag->fqn tag fqn)
     (jch-register-supers! fqn (list iface))
     (register-host-methods! tag
       (list (cons (cadr e)
                   (case (caddr e)
                     ((0) (lambda (self) ((fi-lambda-proc self))))
                     ((1) (lambda (self a) ((fi-lambda-proc self) a)))
                     (else (lambda (self a b) ((fi-lambda-proc self) a b)))))))))
 fi-iface-methods)

;; ---- the defaults ------------------------------------------------------------
;; interface -> ((method-name argc proc) ...); proc takes the receiver first.
(define fi-default-tbl (make-hashtable string-hash string=?))
(define (fi-defaults! iface entries) (hashtable-set! fi-default-tbl iface entries))

(define (fi-test p args) (jolt-truthy? (apply jolt-fi-call p "test" args)))
;; negate / and / or of a predicate interface, over its test arity
(define (fi-predicate-defaults! iface)
  (fi-defaults! iface
    (list (list "negate" 0
                (lambda (self) (make-fi-lambda iface (lambda args (not (fi-test self args))))))
          (list "and" 1
                (lambda (self o)
                  (make-fi-lambda iface (lambda args (and (fi-test self args) (fi-test o args))))))
          (list "or" 1
                (lambda (self o)
                  (make-fi-lambda iface (lambda args (or (fi-test self args) (fi-test o args)))))))))
(for-each fi-predicate-defaults!
          '("java.util.function.Predicate" "java.util.function.BiPredicate"
            "java.util.function.IntPredicate" "java.util.function.LongPredicate"
            "java.util.function.DoublePredicate"))

;; andThen / compose of a one-argument function interface whose argument and
;; result interfaces share the method name (Function, IntUnaryOperator, …)
(define (fi-unary-defaults! iface m)
  (fi-defaults! iface
    (list (list "andThen" 1
                (lambda (self g)
                  (make-fi-lambda iface (lambda (x) (jolt-fi-call g m (jolt-fi-call self m x))))))
          (list "compose" 1
                (lambda (self g)
                  (make-fi-lambda iface (lambda (x) (jolt-fi-call self m (jolt-fi-call g m x)))))))))
(fi-unary-defaults! "java.util.function.Function" "apply")
(fi-unary-defaults! "java.util.function.IntUnaryOperator" "applyAsInt")
(fi-unary-defaults! "java.util.function.LongUnaryOperator" "applyAsLong")
(fi-unary-defaults! "java.util.function.DoubleUnaryOperator" "applyAsDouble")
;; BiFunction.andThen(Function): a BiFunction applying the Function to the result
(fi-defaults! "java.util.function.BiFunction"
  (list (list "andThen" 1
              (lambda (self g)
                (make-fi-lambda "java.util.function.BiFunction"
                  (lambda (a b) (jolt-fi-call g "apply" (jolt-fi-call self "apply" a b))))))))
;; Consumer.andThen(Consumer): both, in order
(define (fi-consumer-defaults! iface)
  (fi-defaults! iface
    (list (list "andThen" 1
                (lambda (self o)
                  (make-fi-lambda iface
                    (lambda args
                      (apply jolt-fi-call self "accept" args)
                      (apply jolt-fi-call o "accept" args)
                      jolt-nil)))))))
(for-each fi-consumer-defaults!
          '("java.util.function.Consumer" "java.util.function.BiConsumer"
            "java.util.function.IntConsumer" "java.util.function.LongConsumer"
            "java.util.function.DoubleConsumer"))

;; The default named METHOD-NAME taking ARGC arguments that OBJ's class
;; inherits, or #f. Only a value that can implement an interface is asked: a
;; reify, a deftype/record, or one of the lambdas above.
(define (fi-default-find obj method-name argc)
  (and (fx>? (hashtable-size fi-default-tbl) 0)
       (or (jreify? obj) (jrec? obj) (fi-lambda? obj))
       (let loop ((tags (value-host-tags obj)))
         (cond ((null? tags) #f)
               ((let ((ms (hashtable-ref fi-default-tbl (car tags) #f)))
                  (and ms (find (lambda (m) (and (string=? (car m) method-name)
                                                 (fx=? (cadr m) argc)))
                                ms)))
                => caddr)
               (else (loop (cdr tags)))))))
(set-iface-default-hook! fi-default-find)

;; ---- statics -------------------------------------------------------------------
(register-class-statics! "java.util.function.Function"
  (list (cons "identity" (lambda () (make-fi-lambda "java.util.function.Function" (lambda (x) x))))))
(register-class-statics! "java.util.function.UnaryOperator"
  (list (cons "identity" (lambda () (make-fi-lambda "java.util.function.UnaryOperator" (lambda (x) x))))))
(register-class-statics! "java.util.function.Predicate"
  (list (cons "not" (lambda (p)
                      (make-fi-lambda "java.util.function.Predicate"
                        (lambda (x) (not (fi-test p (list x)))))))
        ;; isEqual(target): Objects.equals against the target
        (cons "isEqual" (lambda (t)
                          (make-fi-lambda "java.util.function.Predicate"
                            (lambda (x) (objects-equals? t x)))))))
