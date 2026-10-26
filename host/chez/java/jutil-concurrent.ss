;; jutil-concurrent.ss — java.util's legacy synchronized collections and the
;; java.util.concurrent ones (jolt-urj36): Vector, Stack, Hashtable, BitSet,
;; PriorityQueue, ConcurrentLinkedQueue, ConcurrentLinkedDeque,
;; CopyOnWriteArrayList, CopyOnWriteArraySet, ConcurrentSkipListMap and
;; ConcurrentSkipListSet. Each has its JDK 21 public API and class, the
;; iterator its JDK class answers (removing where the JDK's does), printing,
;; equality and hashing through the java.util registry, Clojure's seq / count /
;; get / contains? / nth where the JVM gives them, and a jolt.image codec
;; (image-codecs.ss).
;;
;; Thread safety, by class:
;;   - Vector, Stack and Hashtable hold one mutex for every method, as their
;;     synchronized methods do; their iterators take it per step.
;;   - ConcurrentLinkedQueue / Deque hold a mutex for every change and every
;;     step of an iterator; an iterator is weakly consistent: it walks the live
;;     node chain, skipping what was removed, and a node it stands on keeps its
;;     link onward after removal.
;;   - CopyOnWriteArrayList / Set and ConcurrentSkipListMap / Set are copy on
;;     write: a reader takes the published (immutable) array or tree with no
;;     lock; a writer, under the mutex, builds the new one and publishes it with
;;     one store after a release fence. tools/cow-publish-model.pl checks that
;;     protocol (make cowpublishmodel).
;;   - PriorityQueue and BitSet are not thread-safe on the JVM either.
;;
;; Tags start "jx-", so they register through jutil-views.ss's jx table.
;; Loaded after jutil-views.ss and tree-map.ss.

(define (jxc-npe-if-nil! . xs) (for-each (lambda (x) (when (jolt-nil? x) (jx-npe))) xs))
(define (jxc-index! i n)
  (unless (and (fx>=? i 0) (fx<? i n))
    (throw-jvm 'ArrayIndexOutOfBoundsException
               (string-append "Index " (number->string i) " out of bounds for length " (number->string n)))))
(define (jxc-elems c) (seq->list (jolt-seq c)))
(define (jxc-to-array elems)
  (case-lambda ((self) (cd-to-array (elems self) '())) ((self a) (cd-to-array (elems self) (list a)))))

;; ======================================================================================
;; Vector and Stack
;; ======================================================================================
;; State #(arraylist mutex capacity increment). The elements live in an ArrayList
;; of their own (host-static-classes.ss), which every method reaches under the
;; mutex, so Vector is ArrayList's representation and behavior with Vector's
;; lock, legacy methods and capacity accounting on top. capacity() follows the
;; JDK's growth rule (double, or grow by capacityIncrement), since programs
;; print it.
(define (vec-al v) (vector-ref (jhost-state v) 0))
(define (vec-mu v) (vector-ref (jhost-state v) 1))
(define (vec-cap v) (vector-ref (jhost-state v) 2))
(define (vec-cap! v c) (vector-set! (jhost-state v) 2 c))
(define (vec-incr v) (vector-ref (jhost-state v) 3))
(define (vec-size v) (al-cnt (vec-al v)))
(define (vec-list v) (jolt-with-mutex (vec-mu v) (al->list (vec-al v))))
(define (make-jx-vector tag xs cap incr) (make-jhost tag (vector (make-arraylist xs) (make-mutex) cap incr)))
(define (vec-grow! v min)
  (let ((old (vec-cap v)))
    (when (> min old)
      (vec-cap! v (+ old (max (- min old) (if (> (vec-incr v) 0) (vec-incr v) old)))))))
(define (vec-call v m . args) (jx-call (vec-al v) m args))
(define-syntax with-vec
  (syntax-rules () ((_ v e ...) (jolt-with-mutex (vec-mu v) e ...))))
;; the ArrayList members a Vector answers as they are, under its lock
(define vec-plain
  '(("size" 0) ("isEmpty" 0) ("contains" 1) ("indexOf" 1) ("lastIndexOf" 1) ("toArray" 0 1) ("get" 1)
    ("set" 2) ("remove" 1) ("clear" 0) ("containsAll" 1) ("removeAll" 1) ("retainAll" 1) ("removeIf" 1)
    ("forEach" 1) ("replaceAll" 1) ("sort" 1) ("getFirst" 0) ("getLast" 0) ("removeFirst" 0) ("removeLast" 0)))
(define (vec-index-from xs x from step)
  ;; indexOf(o, index) / lastIndexOf(o, index): from INDEX in direction STEP
  (let ((v (list->vector xs)))
    (let loop ((i from))
      (cond ((or (fx<? i 0) (fx>=? i (vector-length v))) -1)
            ((objects-equals? x (vector-ref v i)) i)
            (else (loop (fx+ i step)))))))
(define (vec-enumeration v) (make-jhost "jx-vector-enum" (vector v 0)))
(define vector-methods
  (append
    (map (lambda (m)
           (cons (car m)
                 (host-arity-of (cdr m) #t
                   (lambda (self . args) (with-vec self (jx-call (vec-al self) (car m) args))))))
         vec-plain)
    (list
      (cons "add" (case-lambda
                    ((self x) (with-vec self (vec-grow! self (fx+ 1 (vec-size self))) (vec-call self "add" x)))
                    ((self i x) (with-vec self
                                  (let ((i (jnum->exact i)))
                                    (unless (and (fx>=? i 0) (fx<=? i (vec-size self)))
                                      (throw-jvm 'ArrayIndexOutOfBoundsException
                                                 (string-append (number->string i) " > " (number->string (vec-size self)))))
                                    (vec-grow! self (fx+ 1 (vec-size self)))
                                    (vec-call self "add" (->num i) x))))))
      (cons "addAll" (case-lambda
                       ((self c) (let ((xs (jxc-elems c)))
                                   (with-vec self (vec-grow! self (+ (vec-size self) (length xs)))
                                     (vec-call self "addAll" xs))))
                       ((self i c) (let ((xs (jxc-elems c)))
                                     (with-vec self (vec-grow! self (+ (vec-size self) (length xs)))
                                       (vec-call self "addAll" i xs))))))
      (cons "addFirst" (lambda (self x) (with-vec self (vec-grow! self (fx+ 1 (vec-size self))) (vec-call self "add" (->num 0) x)) jolt-nil))
      (cons "addLast" (lambda (self x) (with-vec self (vec-grow! self (fx+ 1 (vec-size self))) (vec-call self "add" x)) jolt-nil))
      (cons "addElement" (lambda (self x) (with-vec self (vec-grow! self (fx+ 1 (vec-size self))) (vec-call self "add" x)) jolt-nil))
      (cons "insertElementAt" (lambda (self x i)
                                (with-vec self
                                  (let ((i (jnum->exact i)))
                                    (unless (and (fx>=? i 0) (fx<=? i (vec-size self)))
                                      (throw-jvm 'ArrayIndexOutOfBoundsException
                                                 (string-append (number->string i) " > " (number->string (vec-size self)))))
                                    (vec-grow! self (fx+ 1 (vec-size self)))
                                    (vec-call self "add" (->num i) x)
                                    jolt-nil))))
      (cons "elementAt" (lambda (self i)
                          (with-vec self
                            (let ((i (jnum->exact i)))
                              (unless (fx<? i (vec-size self))
                                (throw-jvm 'ArrayIndexOutOfBoundsException
                                           (string-append (number->string i) " >= " (number->string (vec-size self)))))
                              (al-ref (vec-al self) i)))))
      (cons "firstElement" (lambda (self) (with-vec self (if (fx=? 0 (vec-size self)) (throw-jvm 'NoSuchElementException jolt-nil)
                                                             (al-ref (vec-al self) 0)))))
      (cons "lastElement" (lambda (self) (with-vec self (if (fx=? 0 (vec-size self)) (throw-jvm 'NoSuchElementException jolt-nil)
                                                            (al-ref (vec-al self) (fx- (vec-size self) 1))))))
      (cons "setElementAt" (lambda (self x i)
                             (with-vec self
                               (let ((i (jnum->exact i)))
                                 (unless (fx<? i (vec-size self))
                                   (throw-jvm 'ArrayIndexOutOfBoundsException
                                              (string-append (number->string i) " >= " (number->string (vec-size self)))))
                                 (al-set! (vec-al self) i x) jolt-nil))))
      (cons "removeElementAt" (lambda (self i)
                                (with-vec self
                                  (let ((i (jnum->exact i)))
                                    (cond ((fx>=? i (vec-size self))
                                           (throw-jvm 'ArrayIndexOutOfBoundsException
                                                      (string-append (number->string i) " >= " (number->string (vec-size self)))))
                                          ((fx<? i 0) (throw-jvm 'ArrayIndexOutOfBoundsException (number->string i))))
                                    (al-remove-at! (vec-al self) i) jolt-nil))))
      (cons "removeElement" (lambda (self x)
                              (with-vec self
                                (let ((i (vec-index-from (al->list (vec-al self)) x 0 1)))
                                  (if (fx<? i 0) #f (begin (al-remove-at! (vec-al self) i) #t))))))
      (cons "removeAllElements" (lambda (self) (with-vec self (vec-call self "clear")) jolt-nil))
      (cons "indexOf" (case-lambda
                        ((self x) (with-vec self (->num (vec-index-from (al->list (vec-al self)) x 0 1))))
                        ((self x i) (with-vec self
                                      (let ((i (jnum->exact i)))
                                        (when (fx<? i 0) (throw-jvm 'IndexOutOfBoundsException
                                                                    (string-append "Index " (number->string i) " out of bounds for length " (number->string (vec-size self)))))
                                        (->num (vec-index-from (al->list (vec-al self)) x i 1)))))))
      (cons "lastIndexOf" (case-lambda
                            ((self x) (with-vec self (->num (vec-index-from (al->list (vec-al self)) x (fx- (vec-size self) 1) -1))))
                            ((self x i) (with-vec self
                                          (let ((i (jnum->exact i)))
                                            (when (fx>=? i (vec-size self))
                                              (throw-jvm 'IndexOutOfBoundsException
                                                         (string-append (number->string i) " >= " (number->string (vec-size self)))))
                                            (->num (vec-index-from (al->list (vec-al self)) x i -1)))))))
      (cons "setSize" (lambda (self n)
                        (with-vec self
                          (let ((n (jnum->exact n)))
                            (when (fx<? n 0) (throw-jvm 'ArrayIndexOutOfBoundsException (number->string n)))
                            (vec-grow! self n)
                            (let loop () (when (fx>? (vec-size self) n) (al-remove-at! (vec-al self) (fx- (vec-size self) 1)) (loop)))
                            (let loop () (when (fx<? (vec-size self) n) (al-push! (vec-al self) jolt-nil) (loop)))
                            jolt-nil))))
      (cons "capacity" (lambda (self) (with-vec self (->num (vec-cap self)))))
      (cons "ensureCapacity" (lambda (self n) (with-vec self (when (> (jnum->exact n) 0) (vec-grow! self (jnum->exact n)))) jolt-nil))
      (cons "trimToSize" (lambda (self) (with-vec self (vec-cap! self (vec-size self))) jolt-nil))
      (cons "copyInto" (lambda (self arr)
                         (with-vec self
                           (let loop ((xs (al->list (vec-al self))) (i 0))
                             (unless (null? xs)
                               (when (fx>=? i (ja-len arr)) (throw-jvm 'ArrayIndexOutOfBoundsException
                                                                       (string-append "Index " (number->string i) " out of bounds for length " (number->string (ja-len arr)))))
                               (ja-set! arr i (car xs)) (loop (cdr xs) (fx+ i 1))))
                           jolt-nil)))
      (cons "elements" (lambda (self) (vec-enumeration self)))
      (cons "iterator" (lambda (self) (with-vec self (make-jhost "jx-vector-itr" (vector self (vec-call self "iterator"))))))
      (cons "listIterator" (case-lambda
                             ((self) (make-cd-list-iterator self 0))
                             ((self i) (let ((i (jnum->exact i)))
                                         (unless (and (fx>=? i 0) (fx<=? i (vec-size self)))
                                           (throw-jvm 'IndexOutOfBoundsException (string-append "Index: " (number->string i))))
                                         (make-cd-list-iterator self i)))))
      (cons "subList" (lambda (self from to)
                        (with-vec self (jx-wrap-sync 'ralist (make-cd-sublist self (jnum->exact from) (jnum->exact to)) (vec-mu self)))))
      (cons "reversed" (lambda (self) (make-jhost "jx-reverse-list" (vector self))))
      (cons "clone" (lambda (self)
                      (with-vec self (make-jx-vector (jhost-tag self) (al->list (vec-al self)) (vec-cap self) (vec-incr self))))))))
(define stack-methods
  (list
    (cons "push" (lambda (self x) (with-vec self (vec-grow! self (fx+ 1 (vec-size self))) (vec-call self "add" x)) x))
    (cons "pop" (lambda (self)
                  (with-vec self
                    (when (fx=? 0 (vec-size self)) (throw-jvm 'EmptyStackException jolt-nil))
                    (let ((x (al-ref (vec-al self) (fx- (vec-size self) 1))))
                      (al-remove-at! (vec-al self) (fx- (vec-size self) 1)) x))))
    (cons "peek" (lambda (self)
                   (with-vec self
                     (when (fx=? 0 (vec-size self)) (throw-jvm 'EmptyStackException jolt-nil))
                     (al-ref (vec-al self) (fx- (vec-size self) 1)))))
    (cons "empty" (lambda (self) (with-vec self (fx=? 0 (vec-size self)))))
    (cons "search" (lambda (self x)
                     (with-vec self
                       (let ((i (vec-index-from (al->list (vec-al self)) x (fx- (vec-size self) 1) -1)))
                         (->num (if (fx<? i 0) -1 (fx- (vec-size self) i)))))))))
(jx-class! "jx-vector" "java.util.Vector" '("java.util.AbstractList" "java.util.List" "java.util.RandomAccess" "java.lang.Cloneable" "java.io.Serializable"))
(jx-class! "jx-stack" "java.util.Stack" '("java.util.Vector"))
(register-host-methods! "jx-vector" vector-methods)
(register-host-methods! "jx-stack" (append vector-methods stack-methods))
(for-each (lambda (t) (jx-register! t 'ralist vec-list (lambda (v) (with-vec v (vec-size v))) #f #f))
          '("jx-vector" "jx-stack"))
(jch-register-supers! "java.util.EmptyStackException" '("java.lang.RuntimeException"))
(define (vec-ctor tag)
  (case-lambda
    (() (make-jx-vector tag '() 10 0))
    ((x) (cond ((and (number? x) (< (jnum->exact x) 0))
                (throw-jvm 'IllegalArgumentException (string-append "Illegal Capacity: " (number->string (jnum->exact x)))))
               ((number? x) (make-jx-vector tag '() (jnum->exact x) 0))
               (else (let ((xs (jxc-elems x))) (make-jx-vector tag xs (length xs) 0)))))
    ((c i) (when (< (jnum->exact c) 0)
             (throw-jvm 'IllegalArgumentException (string-append "Illegal Capacity: " (number->string (jnum->exact c)))))
           (make-jx-vector tag '() (jnum->exact c) (jnum->exact i)))))
(register-class-ctor! "java.util.Vector" (vec-ctor "jx-vector"))
(register-class-ctor! "Vector" (lookup-class class-ctors-tbl "java.util.Vector"))
(register-class-ctor! "java.util.Stack" (lambda () (make-jx-vector "jx-stack" '() 10 0)))
(register-class-ctor! "Stack" (lookup-class class-ctors-tbl "java.util.Stack"))
;; Vector$Itr: the ArrayList iterator over the same elements, each step under
;; the vector's lock; remove takes the last element it returned.
(define (vit-vec it) (vector-ref (jhost-state it) 0))
(define (vit-inner it) (vector-ref (jhost-state it) 1))
(jx-class! "jx-vector-itr" "java.util.Vector$Itr" '("java.util.Iterator"))
(register-host-methods! "jx-vector-itr"
  (map (lambda (m)
         (cons (car m) (host-arity-of (list (cdr m)) #t
                         (lambda (self . args) (with-vec (vit-vec self) (jx-call (vit-inner self) (car m) args))))))
       '(("hasNext" . 0) ("next" . 0) ("remove" . 0) ("forEachRemaining" . 1))))
(register-seq-arm! (lambda (x) (and (jhost? x) (string=? (jhost-tag x) "jx-vector-itr")))
  (lambda (it) (jolt-seq (vit-inner it))))
;; elements(): Vector$1, an Enumeration over the live vector
(jx-class! "jx-vector-enum" "java.util.Vector$1" '("java.util.Enumeration"))
(register-host-methods! "jx-vector-enum"
  (list (cons "hasMoreElements" (lambda (self) (let ((v (vit-vec self))) (with-vec v (fx<? (vector-ref (jhost-state self) 1) (vec-size v))))))
        (cons "nextElement" (lambda (self)
                              (let ((v (vit-vec self)) (i (vector-ref (jhost-state self) 1)))
                                (with-vec v
                                  (unless (fx<? i (vec-size v)) (throw-jvm 'NoSuchElementException "Vector Enumeration"))
                                  (vector-set! (jhost-state self) 1 (fx+ i 1))
                                  (al-ref (vec-al v) i)))))
        (cons "asIterator" (lambda (self) (make-jhost "jx-enum-iterator" (vector self))))))
(jch-register-supers! "java.util.Enumeration" '())
;; Enumeration.asIterator(): an Iterator that asks the enumeration
(jx-class! "jx-enum-iterator" "java.util.Enumeration$1" '("java.util.Iterator"))
(register-host-methods! "jx-enum-iterator"
  (list (cons "hasNext" (lambda (self) (jx-call (vit-vec self) "hasMoreElements" '())))
        (cons "next" (lambda (self) (jx-call (vit-vec self) "nextElement" '())))))
;; List.reversed() for a Vector or a CopyOnWriteArrayList: ReverseOrderListView,
;; a live view through the list's own get / set / add / remove at mirrored
;; indexes. State #(list).
(define (rev-list r) (vector-ref (jhost-state r) 0))
(define (rev-n r) (cd-size (rev-list r)))
(define (rev-elems r) (reverse (jxc-elems (rev-list r))))
(jx-class! "jx-reverse-list" "java.util.ReverseOrderListView$Rand" '("java.util.ReverseOrderListView" "java.util.RandomAccess"))
(jch-register-supers! "java.util.ReverseOrderListView" '("java.util.List"))
(register-host-methods! "jx-reverse-list"
  (list (cons "size" (lambda (self) (->num (rev-n self))))
        (cons "get" (lambda (self i) (let ((i (jnum->exact i))) (cd-index-check! i (rev-n self))
                                       (cd-get (rev-list self) (fx- (fx- (rev-n self) 1) i)))))
        (cons "set" (lambda (self i x) (let ((i (jnum->exact i))) (cd-index-check! i (rev-n self))
                                         (cd-call (rev-list self) "set" (->num (fx- (fx- (rev-n self) 1) i)) x))))
        (cons "add" (case-lambda
                      ((self x) (cd-call (rev-list self) "add" (->num 0) x) #t)
                      ((self i x) (cd-call (rev-list self) "add" (->num (fx- (rev-n self) (jnum->exact i))) x) jolt-nil)))
        (cons "remove" (lambda (self i)
                         (if (and (fixnum? i))
                             (begin (cd-index-check! i (rev-n self))
                                    (cd-call (rev-list self) "remove" (->num (fx- (fx- (rev-n self) 1) i))))
                             (let ((k (cd-last-index-of (rev-list self) i)))
                               (if (fx<? k 0) #f (begin (cd-call (rev-list self) "remove" (->num k)) #t))))))
        (cons "iterator" (lambda (self) (make-jutil-iterator "jx-reverse-list-itr" (rev-elems self) (lambda (x) (jx-uoe)))))
        (cons "reversed" (lambda (self) (rev-list self)))))
(jx-class! "jx-reverse-list-itr" "java.util.ReverseOrderListView$DescendingIterator" '("java.util.Iterator"))
(register-jutil-iterator! "jx-reverse-list-itr")
(jx-register! "jx-reverse-list" 'ralist rev-elems rev-n #f #f)

;; ======================================================================================
;; Hashtable
;; ======================================================================================
;; The JDK's own table, ported: an array of buckets, each a chain with the
;; newest entry first, index (hash & 0x7FFFFFFF) mod capacity, a rehash to
;; 2n+1 buckets at the load factor's threshold, iteration from the last bucket
;; to the first. That is what makes (str ht) print in the JVM's order, which
;; programs show. Keys and values are never null. Every method holds the
;; table's mutex; keySet / values / entrySet are Collections.synchronized*
;; views over it on the same lock, as the JDK's are.
;; State #(buckets count threshold load-factor mutex modcount); an entry is a
;; mutable #(hash key value next).
(define (ht-buckets h) (vector-ref (jhost-state h) 0))
(define (ht-count h) (vector-ref (jhost-state h) 1))
(define (ht-count! h n) (vector-set! (jhost-state h) 1 n))
(define (ht-threshold h) (vector-ref (jhost-state h) 2))
(define (ht-lf h) (vector-ref (jhost-state h) 3))
(define (ht-mu h) (vector-ref (jhost-state h) 4))
(define (ht-mod! h) (vector-set! (jhost-state h) 5 (fx+ 1 (vector-ref (jhost-state h) 5))))
(define-syntax with-ht
  (syntax-rules () ((_ h e ...) (jolt-with-mutex (ht-mu h) e ...))))
(define ht-max-array 2147483639)   ; Integer.MAX_VALUE - 8
(define (ht-threshold-for cap lf) (exact (floor (min (* cap lf) (+ ht-max-array 1)))))
(define (make-jx-hashtable cap lf)
  (let ((cap (if (eqv? cap 0) 1 cap)))
    (make-jhost "jx-hashtable" (vector (make-vector cap #f) 0 (ht-threshold-for cap lf) lf (make-mutex) 0))))
(define (ht-hash k) (jolt-java-hashcode k))
(define (ht-index hash n) (modulo (bitwise-and hash #x7FFFFFFF) n))
(define (he-hash e) (vector-ref e 0))
(define (he-key e) (vector-ref e 1))
(define (he-val e) (vector-ref e 2))
(define (he-next e) (vector-ref e 3))
(define (ht-find h k)
  (let* ((hash (ht-hash k)) (b (ht-buckets h)))
    (let loop ((e (vector-ref b (ht-index hash (vector-length b)))))
      (cond ((not e) #f)
            ((and (= (he-hash e) hash) (objects-equals? (he-key e) k)) e)
            (else (loop (he-next e)))))))
(define (ht-rehash! h)
  (let* ((old (ht-buckets h)) (oldn (vector-length old))
         (newn (+ (* 2 oldn) 1)) (new (make-vector newn #f)))
    (vector-set! (jhost-state h) 2 (ht-threshold-for newn (ht-lf h)))
    (vector-set! (jhost-state h) 0 new)
    (ht-mod! h)
    (do ((i (fx- oldn 1) (fx- i 1))) ((fx<? i 0))
      (let loop ((e (vector-ref old i)))
        (when e
          (let ((next (he-next e)) (idx (ht-index (he-hash e) newn)))
            (vector-set! e 3 (vector-ref new idx))
            (vector-set! new idx e)
            (loop next)))))))
(define (ht-put! h k v)
  (jxc-npe-if-nil! k v)
  (let ((e (ht-find h k)))
    (if e
        (let ((old (he-val e))) (vector-set! e 2 v) old)
        (begin
          (when (>= (ht-count h) (ht-threshold h)) (ht-rehash! h))
          (let* ((hash (ht-hash k)) (b (ht-buckets h)) (idx (ht-index hash (vector-length b))))
            (vector-set! b idx (vector hash k v (vector-ref b idx)))
            (ht-count! h (fx+ 1 (ht-count h)))
            (ht-mod! h)
            jolt-nil)))))
(define (ht-remove! h k)
  (jxc-npe-if-nil! k)
  (let* ((hash (ht-hash k)) (b (ht-buckets h)) (idx (ht-index hash (vector-length b))))
    (let loop ((e (vector-ref b idx)) (prev #f))
      (cond ((not e) cd-absent)
            ((and (= (he-hash e) hash) (objects-equals? (he-key e) k))
             (if prev (vector-set! prev 3 (he-next e)) (vector-set! b idx (he-next e)))
             (ht-count! h (fx- (ht-count h) 1))
             (ht-mod! h)
             (he-val e))
            (else (loop (he-next e) e))))))
;; every entry, in the Enumerator's order: the last bucket first
(define (ht-entry-list h)
  (let ((b (ht-buckets h)))
    (let outer ((i (fx- (vector-length b) 1)) (acc '()))
      (if (fx<? i 0)
          (reverse acc)
          (outer (fx- i 1) (let chain ((e (vector-ref b i)) (acc acc)) (if e (chain (he-next e) (cons e acc)) acc)))))))
(define (ht-ref h k) (jxc-npe-if-nil! k) (let ((e (ht-find h k))) (if e (he-val e) cd-absent)))
(define (ht-live-entry h e) (make-jhost "jx-hashtable-entry" (vector h e)))
(define (ht-pairs h) (with-ht h (map (lambda (e) (ht-live-entry h e)) (ht-entry-list h))))
(define (ht-clear! h)
  (vector-fill! (ht-buckets h) #f) (ht-count! h 0) (ht-mod! h))
(define hashtable-methods
  (list
    (cons "size" (lambda (self) (with-ht self (->num (ht-count self)))))
    (cons "isEmpty" (lambda (self) (with-ht self (fx=? 0 (ht-count self)))))
    (cons "get" (lambda (self k) (with-ht self (let ((v (ht-ref self k))) (if (eq? v cd-absent) jolt-nil v)))))
    (cons "containsKey" (lambda (self k) (with-ht self (not (eq? (ht-ref self k) cd-absent)))))
    (cons "contains" (lambda (self v) (jxc-npe-if-nil! v)
                       (with-ht self (and (exists (lambda (e) (objects-equals? v (he-val e))) (ht-entry-list self)) #t))))
    (cons "containsValue" (lambda (self v) (jxc-npe-if-nil! v)
                            (with-ht self (and (exists (lambda (e) (objects-equals? v (he-val e))) (ht-entry-list self)) #t))))
    (cons "put" (lambda (self k v) (with-ht self (ht-put! self k v))))
    (cons "remove" (case-lambda
                     ((self k) (with-ht self (let ((v (ht-remove! self k))) (if (eq? v cd-absent) jolt-nil v))))
                     ((self k v) (with-ht self
                                   (let ((cur (ht-ref self k)))
                                     (if (and (not (eq? cur cd-absent)) (objects-equals? cur v))
                                         (begin (ht-remove! self k) #t) #f))))))
    (cons "putAll" (lambda (self m)
                     (let ((es (jxc-elems m)))
                       (with-ht self (for-each (lambda (e) (ht-put! self (jolt-nth e 0) (jolt-nth e 1))) es)))
                     jolt-nil))
    (cons "clear" (lambda (self) (with-ht self (ht-clear! self)) jolt-nil))
    (cons "clone" (lambda (self)
                    (with-ht self
                      (let ((c (make-jx-hashtable (vector-length (ht-buckets self)) (ht-lf self))))
                        ;; the same chains, copied bucket by bucket
                        (let ((b (ht-buckets self)) (nb (ht-buckets c)))
                          (do ((i 0 (fx+ i 1))) ((fx=? i (vector-length b)))
                            (vector-set! nb i (let copy ((e (vector-ref b i)))
                                                (and e (vector (he-hash e) (he-key e) (he-val e) (copy (he-next e))))))))
                        (ht-count! c (ht-count self))
                        (vector-set! (jhost-state c) 2 (ht-threshold self))
                        c))))
    (cons "keys" (lambda (self) (make-ht-enumerator self 'key)))
    (cons "elements" (lambda (self) (make-ht-enumerator self 'value)))
    (cons "keySet" (lambda (self) (jx-wrap-sync 'set (make-jhost "jx-hashtable-keyset" (vector self)) (ht-mu self))))
    (cons "values" (lambda (self) (jx-wrap-sync 'coll (make-jhost "jx-hashtable-values" (vector self)) (ht-mu self))))
    (cons "entrySet" (lambda (self) (jx-wrap-sync 'set (make-jhost "jx-hashtable-entryset" (vector self)) (ht-mu self))))
    (cons "getOrDefault" (lambda (self k d) (with-ht self (let ((v (ht-ref self k))) (if (eq? v cd-absent) d v)))))
    (cons "putIfAbsent" (lambda (self k v)
                          (jxc-npe-if-nil! v)
                          (with-ht self (let ((cur (ht-ref self k))) (if (eq? cur cd-absent) (ht-put! self k v) cur)))))
    (cons "replace" (case-lambda
                      ((self k v) (jxc-npe-if-nil! v)
                                  (with-ht self (let ((e (ht-find self k)))
                                                  (if e (let ((old (he-val e))) (vector-set! e 2 v) old) jolt-nil))))
                      ((self k old v) (jxc-npe-if-nil! old v)
                                      (with-ht self (let ((e (ht-find self k)))
                                                      (if (and e (objects-equals? (he-val e) old))
                                                          (begin (vector-set! e 2 v) #t) #f))))))
    (cons "computeIfAbsent" (lambda (self k f)
                              (with-ht self
                                (let ((cur (ht-ref self k)))
                                  (if (eq? cur cd-absent)
                                      (let ((nv (jolt-fi-call f "apply" k)))
                                        (unless (jolt-nil? nv) (ht-put! self k nv))
                                        nv)
                                      cur)))))
    (cons "computeIfPresent" (lambda (self k f)
                               (with-ht self
                                 (let ((cur (ht-ref self k)))
                                   (if (eq? cur cd-absent)
                                       jolt-nil
                                       (let ((nv (jolt-fi-call f "apply" k cur)))
                                         (if (jolt-nil? nv) (ht-remove! self k) (ht-put! self k nv))
                                         nv))))))
    (cons "compute" (lambda (self k f)
                      (with-ht self
                        (let* ((cur (ht-ref self k))
                               (nv (jolt-fi-call f "apply" k (if (eq? cur cd-absent) jolt-nil cur))))
                          (cond ((not (jolt-nil? nv)) (ht-put! self k nv) nv)
                                ((not (eq? cur cd-absent)) (ht-remove! self k) jolt-nil)
                                (else jolt-nil))))))
    (cons "merge" (lambda (self k v f)
                    (jxc-npe-if-nil! v)
                    (with-ht self
                      (let* ((cur (ht-ref self k))
                             (nv (if (eq? cur cd-absent) v (jolt-fi-call f "apply" cur v))))
                        (if (jolt-nil? nv)
                            (begin (ht-remove! self k) jolt-nil)
                            (begin (ht-put! self k nv) nv))))))
    (cons "forEach" (lambda (self f)
                      (for-each (lambda (e) (jolt-fi-call f "accept" (he-key e) (he-val e)))
                                (with-ht self (ht-entry-list self)))
                      jolt-nil))
    (cons "replaceAll" (lambda (self f)
                         (with-ht self
                           (for-each (lambda (e)
                                       (let ((nv (jolt-fi-call f "apply" (he-key e) (he-val e))))
                                         (jxc-npe-if-nil! nv)
                                         (vector-set! e 2 nv)))
                                     (ht-entry-list self)))
                         jolt-nil))))
(jx-class! "jx-hashtable" "java.util.Hashtable" '("java.util.Dictionary" "java.util.Map" "java.lang.Cloneable" "java.io.Serializable"))
(jch-register-supers! "java.util.Dictionary" '())
(register-host-methods! "jx-hashtable" hashtable-methods)
(jx-register! "jx-hashtable" 'map ht-pairs (lambda (h) (with-ht h (ht-count h)))
              (lambda (h k) (and (not (jolt-nil? k)) (with-ht h (not (eq? (ht-ref h k) cd-absent)))))
              (lambda (h k d) (if (jolt-nil? k) d (with-ht h (let ((v (ht-ref h k))) (if (eq? v cd-absent) d v))))))
(define (ht-ctor . args)
  (cond ((null? args) (make-jx-hashtable 11 0.75))
        ((and (number? (car args)) (null? (cdr args)))
         (let ((c (jnum->exact (car args))))
           (when (< c 0) (throw-jvm 'IllegalArgumentException (string-append "Illegal Capacity: " (number->string c))))
           (make-jx-hashtable c 0.75)))
        ((number? (car args))
         (let ((c (jnum->exact (car args))) (lf (inexact (cadr args))))
           (when (< c 0) (throw-jvm 'IllegalArgumentException (string-append "Illegal Capacity: " (number->string c))))
           (when (or (<= lf 0) (nan? lf)) (throw-jvm 'IllegalArgumentException (string-append "Illegal Load: " (jolt-str-render-one (cadr args)))))
           (make-jx-hashtable c lf)))
        (else
         (let* ((es (jxc-elems (car args)))
                (h (make-jx-hashtable (max (* 2 (length es)) 11) 0.75)))
           (for-each (lambda (e) (ht-put! h (jolt-nth e 0) (jolt-nth e 1))) es)
           h))))
(register-class-ctor! "java.util.Hashtable" (case-lambda (() (ht-ctor)) ((a) (ht-ctor a)) ((a b) (ht-ctor a b))))
(register-class-ctor! "Hashtable" (lookup-class class-ctors-tbl "java.util.Hashtable"))
;; Hashtable$Entry: the chain node itself, so setValue writes into the table
(jx-class! "jx-hashtable-entry" "java.util.Hashtable$Entry" '("java.util.Map$Entry"))
(define (hte-e x) (vector-ref (jhost-state x) 1))
(define (hte-h x) (vector-ref (jhost-state x) 0))
(register-jutil-entry! "jx-hashtable-entry" (lambda (x) (cons (he-key (hte-e x)) (with-ht (hte-h x) (he-val (hte-e x))))))
(register-host-methods! "jx-hashtable-entry"
  (list (cons "setValue" (lambda (self v)
                           (jxc-npe-if-nil! v)
                           (with-ht (hte-h self) (let ((old (he-val (hte-e self)))) (vector-set! (hte-e self) 2 v) old))))))
;; Hashtable$Enumerator: both the Enumeration keys() / elements() answer and the
;; Iterator of the three views. It walks a snapshot of the chain nodes; remove
;; takes the last one it returned out of the table, by key. State
;; #(table remaining last kind iterator?) with kind key / value / entry.
(define (make-ht-enumerator h kind . iter?)
  (make-jhost "jx-hashtable-enumerator"
              (vector h (with-ht h (ht-entry-list h)) #f kind (and (pair? iter?) (car iter?)))))
(define (hten-project it e)
  (case (vector-ref (jhost-state it) 3)
    ((key) (he-key e)) ((value) (he-val e)) (else (ht-live-entry (vector-ref (jhost-state it) 0) e))))
(define (hten-next! it)
  (let* ((st (jhost-state it)) (es (vector-ref st 1)))
    (when (null? es) (throw-jvm 'NoSuchElementException "Hashtable Enumerator"))
    (vector-set! st 1 (cdr es))
    (vector-set! st 2 (car es))
    (hten-project it (car es))))
(jx-class! "jx-hashtable-enumerator" "java.util.Hashtable$Enumerator" '("java.util.Enumeration" "java.util.Iterator"))
(register-host-methods! "jx-hashtable-enumerator"
  (list (cons "hasMoreElements" (lambda (self) (pair? (vector-ref (jhost-state self) 1))))
        (cons "nextElement" (lambda (self) (hten-next! self)))
        (cons "hasNext" (lambda (self) (pair? (vector-ref (jhost-state self) 1))))
        (cons "next" (lambda (self) (hten-next! self)))
        (cons "asIterator" (lambda (self) self))
        (cons "remove" (lambda (self)
                         (let* ((st (jhost-state self)) (e (vector-ref st 2)))
                           (unless (vector-ref st 4) (throw-jvm 'UnsupportedOperationException jolt-nil))
                           (unless e (throw-jvm 'IllegalStateException "Hashtable Enumerator"))
                           (with-ht (vector-ref st 0) (ht-remove! (vector-ref st 0) (he-key e)))
                           (vector-set! st 2 #f)
                           jolt-nil)))
        (cons "forEachRemaining" (lambda (self f)
                                   (let loop ()
                                     (when (pair? (vector-ref (jhost-state self) 1))
                                       (jolt-fi-call f "accept" (hten-next! self))
                                       (loop)))
                                   jolt-nil))))
(register-seq-arm! (lambda (x) (and (jhost? x) (string=? (jhost-tag x) "jx-hashtable-enumerator")))
  (lambda (it) (let ((es (vector-ref (jhost-state it) 1)))
                 (if (null? es) jolt-nil (list->cseq (map (lambda (e) (hten-project it e)) es))))))
;; the three views, which the synchronized wrappers above hold the table's lock
;; around. State #(table).
(define (htv-table v) (vector-ref (jhost-state v) 0))
(define (htv-methods kind has? remove!)
  (list (cons "size" (lambda (self) (->num (ht-count (htv-table self)))))
        (cons "isEmpty" (lambda (self) (fx=? 0 (ht-count (htv-table self)))))
        (cons "contains" (lambda (self x) (has? (htv-table self) x)))
        (cons "remove" (lambda (self x) (remove! (htv-table self) x)))
        (cons "clear" (lambda (self) (ht-clear! (htv-table self)) jolt-nil))
        (cons "iterator" (lambda (self) (make-ht-enumerator (htv-table self) kind #t)))
        (cons "toArray" (case-lambda ((self) (cd-to-array (htv-elems kind self) '()))
                                     ((self a) (cd-to-array (htv-elems kind self) (list a)))))))
(define (htv-elems kind v)
  (let ((h (htv-table v)))
    (map (lambda (e) (case kind ((key) (he-key e)) ((value) (he-val e)) (else (ht-live-entry h e))))
         (with-ht h (ht-entry-list h)))))
(define (ht-has-entry? h x)
  (let ((kv (or (jolt-host-entry x) (and (jolt-map-entry? x) (cons (jolt-nth x 0) (jolt-nth x 1))))))
    (and kv (not (jolt-nil? (car kv)))
         (let ((e (ht-find h (car kv)))) (and e (objects-equals? (he-val e) (cdr kv)))))))
(jx-class! "jx-hashtable-keyset" "java.util.Hashtable$KeySet" '("java.util.AbstractSet"))
(register-host-methods! "jx-hashtable-keyset"
  (htv-methods 'key (lambda (h k) (and (not (jolt-nil? k)) (ht-find h k) #t))
               (lambda (h k) (if (jolt-nil? k) #f (not (eq? (ht-remove! h k) cd-absent))))))
(jx-register! "jx-hashtable-keyset" 'set (lambda (v) (htv-elems 'key v)) (lambda (v) (ht-count (htv-table v)))
              (lambda (v k) (and (not (jolt-nil? k)) (ht-find (htv-table v) k) #t)) #f)
(jx-class! "jx-hashtable-values" "java.util.Hashtable$ValueCollection" '("java.util.AbstractCollection"))
(register-host-methods! "jx-hashtable-values"
  (htv-methods 'value (lambda (h x) (and (exists (lambda (e) (objects-equals? x (he-val e))) (ht-entry-list h)) #t))
               (lambda (h x) (let ((e (find (lambda (e) (objects-equals? x (he-val e))) (ht-entry-list h))))
                               (if e (begin (ht-remove! h (he-key e)) #t) #f)))))
(jx-register! "jx-hashtable-values" 'coll (lambda (v) (htv-elems 'value v)) (lambda (v) (ht-count (htv-table v))) #f #f)
(jx-class! "jx-hashtable-entryset" "java.util.Hashtable$EntrySet" '("java.util.AbstractSet"))
(register-host-methods! "jx-hashtable-entryset"
  (htv-methods 'entry ht-has-entry?
               (lambda (h x) (if (ht-has-entry? h x) (begin (ht-remove! h (car (or (jolt-host-entry x) (cons (jolt-nth x 0) #f)))) #t) #f))))
(jx-register! "jx-hashtable-entryset" 'entries (lambda (v) (htv-elems 'entry v)) (lambda (v) (ht-count (htv-table v)))
              (lambda (v x) (ht-has-entry? (htv-table v) x)) #f)
