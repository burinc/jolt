;; streams.ss — java.util.stream for the Chez host.
;;
;; Clojure 1.12 reads a Stream through stream-seq! / stream-reduce! /
;; stream-transduce! / stream-into! (all over its .iterator), and Java APIs hand
;; streams back, so a Stream here is a real value: a one-shot pipeline over a
;; lazy jolt seq. An intermediate op (map, filter, limit, …) consumes its stream
;; and answers a new one over the transformed seq; a terminal op (forEach,
;; collect, reduce, iterator, …) consumes it and answers a value. A second use of
;; a consumed stream raises the JVM's IllegalStateException.
;;
;; The function argument of every op is a java.util.function interface, so it
;; goes through jolt-fi-call (records-dispatch.ss): a Clojure fn is invoked, and a
;; reify of the interface has its method called by name. The method name depends
;; on the stream's element kind — an IntStream's map takes an IntUnaryOperator,
;; whose method is applyAsInt — which is why the kind rides on the tag.
;;
;; Loaded after host-static-classes.ss (Optional, the ArrayList/HashSet shims,
;; jcoll-*), natives-array.ss (arrays) and lazy-bridge.ss (jolt-make-lazy-seq).

;; tag -> element kind. The tag is also the class model's handle (class-hierarchy.ss
;; jhost-tag->fqn): a Stream is a ReferencePipeline, an IntStream an IntPipeline.
(define stream-tags '(("stream" . ref) ("int-stream" . int) ("long-stream" . long)
                      ("double-stream" . double)))
(define (stream? x) (and (jhost? x) (assoc (jhost-tag x) stream-tags) #t))
(define (stream-kind s) (cdr (assoc (jhost-tag s) stream-tags)))
(define (kind-tag k) (car (find (lambda (p) (eq? (cdr p) k)) stream-tags)))
;; state: #(seq consumed? close-handlers)
(define (make-stream kind seq) (make-jhost (kind-tag kind) (vector seq #f '())))

;; Take a stream's elements, marking it used: every op, intermediate or
;; terminal, links or consumes the stream it is called on exactly once.
(define (stream-take! s)
  (let ((st (jhost-state s)))
    (when (vector-ref st 1)
      (throw-jvm 'IllegalStateException "stream has already been operated upon or closed"))
    (vector-set! st 1 #t)
    (vector-ref st 0)))
(define (stream-list! s) (seq->list (jolt-seq (stream-take! s))))
;; An intermediate op: a new stream of KIND over (f seq), carrying the close
;; handlers along so closing the end of a pipeline runs them all.
(define (stream-derive s kind f)
  (let* ((handlers (vector-ref (jhost-state s) 2))
         (n (make-stream kind (f (stream-take! s)))))
    (vector-set! (jhost-state n) 2 handlers)
    n))

;; The functional-interface method names per kind, for the ops whose argument
;; type follows the stream's element type.
(define (kind-unary-method k)
  (case k ((int) "applyAsInt") ((long) "applyAsLong") ((double) "applyAsDouble") (else "apply")))
(define (kind-binary-method k) (kind-unary-method k))
;; A primitive stream's element as the JVM holds it: an int/long stream's are
;; integers, a double stream's doubles.
(define (kind-coerce k v)
  (case k
    ((int long) (if (and (number? v) (not (exact? v))) (exact (truncate v)) v))
    ((double) (if (number? v) (inexact v) v))
    (else v)))
(define (clj f) (var-deref "clojure.core" f))

(define (stream-map s method kind)
  (lambda (f)
    (stream-derive s kind
      (lambda (xs) (jolt-map (lambda (x) (kind-coerce kind (jolt-fi-call f method x))) xs)))))

(define (stream-sum k xs)
  (let ((t (fold-left + 0 xs)))
    (if (eq? k 'double) (inexact t) t)))

(define (stream-reduce s args)
  (let ((k (stream-kind s)) (xs (stream-list! s)))
    (cond
      ;; reduce(BinaryOperator) -> Optional
      ((null? (cdr args))
       (if (null? xs)
           jt-optional-empty
           (jt-optional #t (fold-left (lambda (a x) (jolt-fi-call (car args) (kind-binary-method k) a x))
                                      (car xs) (cdr xs)))))
      ;; reduce(identity, accumulator [, combiner]) — sequential, so the
      ;; combiner never runs
      (else
       (fold-left (lambda (a x) (jolt-fi-call (cadr args) (kind-binary-method k) a x))
                  (car args) xs)))))

;; ---- Collectors ---------------------------------------------------------------
;; A Collector is a finisher over the element list; collect(Collector) applies it.
(define (make-collector f) (make-jhost "stream-collector" f))
(define (collector? x) (and (jhost? x) (string=? (jhost-tag x) "stream-collector")))
(define (joining . args)
  (let ((sep (if (pair? args) (jolt-str-render-one (car args)) ""))
        (pre (if (and (pair? args) (pair? (cdr args))) (jolt-str-render-one (cadr args)) ""))
        (suf (if (and (pair? args) (pair? (cdr args))) (jolt-str-render-one (caddr args)) "")))
    (make-collector
     (lambda (xs)
       (string-append
        pre
        (if (null? xs) ""
            (fold-left (lambda (a x) (string-append a sep (jolt-str-render-one x)))
                       (jolt-str-render-one (car xs)) (cdr xs)))
        suf)))))
(let ((statics
       (list (cons "toList" (lambda () (make-collector (lambda (xs) (make-arraylist xs)))))
             (cons "toUnmodifiableList" (lambda () (make-collector (lambda (xs) (apply jolt-vector xs)))))
             (cons "toSet" (lambda () (make-collector (lambda (xs) (host-new "java.util.HashSet" (list->cseq xs))))))
             (cons "toUnmodifiableSet" (lambda () (make-collector (lambda (xs) (apply jolt-hash-set xs)))))
             (cons "counting" (lambda () (make-collector (lambda (xs) (length xs)))))
             (cons "joining" joining))))
  (register-class-statics! "Collectors" statics)
  (register-class-statics! "java.util.stream.Collectors" statics))

;; collect(Collector) or collect(supplier, accumulator, combiner)
(define (stream-collect s args)
  (cond
    ((and (pair? args) (null? (cdr args)) (collector? (car args)))
     ((jhost-state (car args)) (stream-list! s)))
    ((fx=? (length args) 3)
     (let ((acc (jolt-fi-call (car args) "get")))
       (for-each (lambda (x) (jolt-fi-call (cadr args) "accept" acc x)) (stream-list! s))
       acc))
    (else (throw-jvm 'IllegalArgumentException "collect expects a Collector or (supplier accumulator combiner)"))))

(define (stream-to-array s args)
  (let ((xs (stream-list! s)) (k (stream-kind s)))
    (if (pair? args)
        ;; toArray(IntFunction<A[]> generator): the generator sizes the array
        (let ((arr (jolt-fi-call (car args) "apply" (length xs))))
          (let loop ((i 0) (xs xs))
            (unless (null? xs) (ja-set! arr i (car xs)) (loop (fx+ i 1) (cdr xs))))
          arr)
        (make-jolt-array (list->vector xs) (case k ((int) 'int) ((long) 'long) ((double) 'double) (else 'object))))))

(define (stream-min-max s args pick)
  (let* ((k (stream-kind s)) (xs (stream-list! s))
         (less? (cmp->less (if (pair? args) (car args) jolt-compare))))
    (if (null? xs)
        jt-optional-empty
        (jt-optional #t (fold-left (lambda (best x) (pick less? best x)) (car xs) (cdr xs))))))

(define (stream-close! s)
  (let ((hs (vector-ref (jhost-state s) 2)))
    (vector-set! (jhost-state s) 2 '())
    (vector-set! (jhost-state s) 1 #t)
    (for-each (lambda (h) (jolt-fi-call h "run")) (reverse hs))
    jolt-nil))

(define (stream-methods)
  (list
   ;; --- intermediate ------------------------------------------------------
   (cons "map" (lambda (s f) ((stream-map s (kind-unary-method (stream-kind s)) (stream-kind s)) f)))
   (cons "mapToObj" (lambda (s f) ((stream-map s "apply" 'ref) f)))
   (cons "mapToInt" (lambda (s f) ((stream-map s "applyAsInt" 'int) f)))
   (cons "mapToLong" (lambda (s f) ((stream-map s "applyAsLong" 'long) f)))
   (cons "mapToDouble" (lambda (s f) ((stream-map s "applyAsDouble" 'double) f)))
   (cons "boxed" (lambda (s) (stream-derive s 'ref (lambda (xs) xs))))
   (cons "asLongStream" (lambda (s) (stream-derive s 'long (lambda (xs) xs))))
   (cons "asDoubleStream" (lambda (s) (stream-derive s 'double (lambda (xs) (jolt-map inexact xs)))))
   (cons "filter" (lambda (s p)
                    (stream-derive s (stream-kind s)
                      (lambda (xs) (jolt-filter (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) xs)))))
   (cons "flatMap" (lambda (s f)
                     (stream-derive s (stream-kind s)
                       (lambda (xs)
                         (jolt-invoke2 (clj "mapcat")
                                       (lambda (x)
                                         (let ((r (jolt-fi-call f "apply" x)))
                                           (if (stream? r) (stream-take! r) r)))
                                       xs)))))
   (cons "peek" (lambda (s f)
                  (stream-derive s (stream-kind s)
                    (lambda (xs) (jolt-map (lambda (x) (jolt-fi-call f "accept" x) x) xs)))))
   (cons "limit" (lambda (s n) (stream-derive s (stream-kind s) (lambda (xs) (jolt-take (jnum->exact n) xs)))))
   (cons "skip" (lambda (s n) (stream-derive s (stream-kind s) (lambda (xs) (jolt-drop (jnum->exact n) xs)))))
   (cons "distinct" (lambda (s) (stream-derive s (stream-kind s) (lambda (xs) (jolt-invoke1 (clj "distinct") xs)))))
   (cons "sorted" (lambda (s . cmp)
                    (stream-derive s (stream-kind s)
                      (lambda (xs) (list->cseq (jcoll-sorted (seq->list (jolt-seq xs))
                                                             (if (pair? cmp) (car cmp) jolt-nil)))))))
   (cons "takeWhile" (lambda (s p)
                       (stream-derive s (stream-kind s)
                         (lambda (xs) (jolt-invoke2 (clj "take-while")
                                                    (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) xs)))))
   (cons "dropWhile" (lambda (s p)
                       (stream-derive s (stream-kind s)
                         (lambda (xs) (jolt-invoke2 (clj "drop-while")
                                                    (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) xs)))))
   ;; sequential execution is all there is, so these are the stream itself
   (cons "sequential" (lambda (s) s)) (cons "parallel" (lambda (s) s))
   (cons "unordered" (lambda (s) s)) (cons "isParallel" (lambda (s) #f))
   (cons "onClose" (lambda (s h)
                     (vector-set! (jhost-state s) 2 (cons h (vector-ref (jhost-state s) 2)))
                     s))
   (cons "close" stream-close!)
   ;; --- terminal ------------------------------------------------------------
   (cons "iterator" (lambda (s) (make-jiterator (jolt-seq (stream-take! s)))))
   (cons "forEach" (lambda (s f) (for-each (lambda (x) (jolt-fi-call f "accept" x)) (stream-list! s)) jolt-nil))
   (cons "forEachOrdered" (lambda (s f) (for-each (lambda (x) (jolt-fi-call f "accept" x)) (stream-list! s)) jolt-nil))
   ;; Stream.toList is an unmodifiable List — a persistent vector is one
   (cons "toList" (lambda (s) (apply jolt-vector (stream-list! s))))
   (cons "toArray" (lambda (s . gen) (stream-to-array s gen)))
   (cons "collect" (lambda (s . args) (stream-collect s args)))
   (cons "reduce" (lambda (s . args) (stream-reduce s args)))
   (cons "count" (lambda (s) (length (stream-list! s))))
   (cons "sum" (lambda (s) (stream-sum (stream-kind s) (stream-list! s))))
   (cons "average" (lambda (s)
                     (let ((xs (stream-list! s)))
                       (if (null? xs) jt-optional-empty
                           (jt-optional #t (inexact (/ (fold-left + 0 xs) (length xs))))))))
   (cons "min" (lambda (s . c) (stream-min-max s c (lambda (less? b x) (if (less? x b) x b)))))
   (cons "max" (lambda (s . c) (stream-min-max s c (lambda (less? b x) (if (less? b x) x b)))))
   (cons "anyMatch" (lambda (s p) (and (exists (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) (stream-list! s)) #t)))
   (cons "allMatch" (lambda (s p) (and (for-all (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) (stream-list! s)) #t)))
   (cons "noneMatch" (lambda (s p) (not (exists (lambda (x) (jolt-truthy? (jolt-fi-call p "test" x))) (stream-list! s)))))
   (cons "findFirst" (lambda (s)
                       (let ((q (jolt-seq (stream-take! s))))
                         (if (jolt-nil? q) jt-optional-empty (jt-optional #t (jolt-first q))))))
   (cons "findAny" (lambda (s)
                     (let ((q (jolt-seq (stream-take! s))))
                       (if (jolt-nil? q) jt-optional-empty (jt-optional #t (jolt-first q))))))))
(for-each (lambda (p) (register-host-methods! (car p) (stream-methods))) stream-tags)
;; a stream seqs and reduces like the iterator it is, so (seq s) / (into [] s)
;; and a reify over it see its elements (consuming it, as any iteration does)
(register-seq-arm! stream? (lambda (s) (jolt-seq (stream-take! s))))

;; The primitive streams' optionals read through getAsInt / getAsLong /
;; getAsDouble (OptionalInt and its siblings), which is what an IntStream's
;; min / max / findFirst / average hand back here.
(let ((get (lambda (o) (if (opt-present? o) (opt-value o) (throw-jvm 'NoSuchElementException "No value present")))))
  (register-host-methods! "optional"
    (list (cons "getAsInt" get) (cons "getAsLong" get) (cons "getAsDouble" get))))

;; ---- sources -----------------------------------------------------------------
;; Stream.of(T... values): one array argument IS the values, as the varargs
;; arrive from Clojure; anything else is the elements spelled out.
(define (stream-of kind)
  (lambda args
    (make-stream kind
      (if (and (pair? args) (null? (cdr args)) (jolt-array? (car args)))
          (list->cseq (ja->list (car args)))
          (list->cseq args)))))
(define (stream-iterate kind)
  (case-lambda
    ((seed f) (make-stream kind (jolt-iterate (lambda (x) (jolt-fi-call f (kind-unary-method kind) x)) seed)))
    ;; iterate(seed, hasNext, next) — the for-loop form (JDK 9)
    ((seed has-next f)
     (make-stream kind
       (jolt-invoke2 (clj "take-while")
                     (lambda (x) (jolt-truthy? (jolt-fi-call has-next "test" x)))
                     (jolt-iterate (lambda (x) (jolt-fi-call f (kind-unary-method kind) x)) seed))))))
(define (stream-concat kind)
  (lambda (a b) (make-stream kind (jolt-concat (stream-take! a) (stream-take! b)))))
(define (stream-range closed?)
  (lambda (kind)
    (lambda (from to)
      (let ((from (jnum->exact from)) (to (jnum->exact to)))
        (make-stream kind (jolt-invoke2 (clj "range") from (if closed? (+ to 1) to)))))))
(define (stream-statics kind)
  (append
   (list (cons "of" (stream-of kind))
         (cons "empty" (lambda () (make-stream kind jolt-nil)))
         (cons "iterate" (stream-iterate kind))
         (cons "generate" (lambda (f)
                            (make-stream kind (jolt-invoke1 (clj "repeatedly")
                                                            (lambda () (jolt-fi-call f "get"))))))
         (cons "concat" (stream-concat kind)))
   (if (eq? kind 'ref)
       (list (cons "ofNullable" (lambda (x) (make-stream 'ref (if (jolt-nil? x) jolt-nil (list->cseq (list x)))))))
       (list (cons "range" ((stream-range #f) kind))
             (cons "rangeClosed" ((stream-range #t) kind))))))
;; One member list per class, registered under both spellings: a fresh closure
;; per spelling re-registers each member with a different value, which the
;; boot's registry-drift check reports.
(for-each
 (lambda (p)
   (let ((members (stream-statics (cdr p))))
     (register-class-statics! (car p) members)
     (register-class-statics! (string-append "java.util.stream." (car p)) members)))
 '(("Stream" . ref) ("IntStream" . int) ("LongStream" . long) ("DoubleStream" . double)))

;; Arrays.stream(array [from to]): an int[]/long[]/double[] is a primitive
;; stream, any other array a Stream.
(register-class-statics! "java.util.Arrays"
  (list (cons "stream"
              (lambda (arr . range)
                (let* ((xs (ja->list arr))
                       (xs (if (pair? range)
                               (let ((from (jnum->exact (car range))) (to (jnum->exact (cadr range))))
                                 (list-head (list-tail xs from) (- to from)))
                               xs)))
                  (make-stream (case (jolt-array-kind arr)
                                 ((int) 'int) ((long) 'long) ((double) 'double) (else 'ref))
                               (list->cseq xs)))))))

;; Collection.stream() on every collection that is a java.util.Collection — the
;; persistent vector, set and list and every seq, and the ArrayList / HashSet
;; family. A map is not a Collection (it has no stream method on the JVM), and a
;; string is not either. Lazy: a seq source is streamed without realizing it.
(define (stream-source? x)
  (or (pvec? x) (pset? x) (jolt-seq? x) (jolt-lazyseq? x) (al-family? x) (hs-hashset? x)))
(define arm-priority-stream 29)
(register-method-arm! arm-priority-stream
  (lambda (obj name rest)
    (if (and (or (string=? name "stream") (string=? name "parallelStream"))
             (stream-source? obj))
        (if (null? (method-rest-args->list rest))
            (make-stream 'ref (if (or (al-family? obj) (hs-hashset? obj))
                                  ;; a mutable source is snapshotted, as the JDK's
                                  ;; late-binding spliterator is by the time it runs
                                  (list->cseq (seq->list (jolt-seq obj)))
                                  obj))
            (dispatch-miss obj name (method-rest-args->list rest)))
        'pass)))
