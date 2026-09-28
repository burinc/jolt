;; natives-queue.ss — clojure.lang.PersistentQueue for the Chez host.
;;
;; A functional queue: a `front` Scheme list (the dequeue end, head = front of the
;; queue) + a reversed `rear` Scheme list (the enqueue end, head = most recent).
;; conj adds to rear; peek/first read front; pop drops the front, rebalancing
;; rear->front when front empties — amortized O(1). A queue is jolt-sequential?, so
;; seq=?/seq-hash give cross-type equality (= [1 2 3] (queue 1 2 3)) for free, like
;; the JVM. Loaded after seq/collections/lazy-bridge/records/host-table so every
;; dispatcher it chains is at its latest binding.

(define-record-type jolt-queue (fields front rear cnt) (nongenerative jolt-queue-v1))
(define jolt-queue-empty (make-jolt-queue '() '() 0))

(define (queue-conj q x)
  (if (null? (jolt-queue-front q))
      (make-jolt-queue (list x) '() (fx+ (jolt-queue-cnt q) 1))
      (make-jolt-queue (jolt-queue-front q) (cons x (jolt-queue-rear q)) (fx+ (jolt-queue-cnt q) 1))))
(define (queue-peek q) (if (null? (jolt-queue-front q)) jolt-nil (car (jolt-queue-front q))))
(define (queue-pop q)
  (let ((f (jolt-queue-front q)))
    ;; popping an empty PersistentQueue returns it (Clojure's pop: if f==null
    ;; return this) — unlike a vector, which throws.
    (cond ((null? f) q)
          ((null? (cdr f)) (make-jolt-queue (reverse (jolt-queue-rear q)) '() (fx- (jolt-queue-cnt q) 1)))
          (else (make-jolt-queue (cdr f) (jolt-queue-rear q) (fx- (jolt-queue-cnt q) 1))))))

;; --- extend the collection dispatchers to see a jolt-queue ------------------
;; The seq realizes the front in blocks of queue-seq-block cells, each block
;; ending in a lazy tail, and moves to the reversed rear once the front runs
;; out: (seq q) and (first q) are O(1) as on the JVM, and a full walk forces one
;; tail per block rather than per element. The tail is a lazy-src so a seq over a
;; queue still travels in a state image.
(define queue-seq-block 32)
(define lz-queue-walk
  (register-lazy-src! 'queue-walk (lambda (f r) (queue-walk f r))))
(define (queue-walk f r)
  (cond ((pair? f) (queue-block f r queue-seq-block))
        ((null? r) jolt-nil)
        (else (queue-walk (reverse r) '()))))
(define (queue-block f r k)
  (let ((more (cdr f)))
    (cond ((pair? more)
           (if (fx=? k 1)
               (cseq-lazy (car f) (make-lazy-src lz-queue-walk more r))
               (cseq-realized (car f) (queue-block more r (fx- k 1)))))
          ((null? r) (cseq-realized (car f) jolt-nil))
          (else (cseq-lazy (car f) (make-lazy-src lz-queue-walk '() r))))))
(define (queue->seq x) (queue-walk (jolt-queue-front x) (jolt-queue-rear x)))
(register-seq-arm! jolt-queue? queue->seq)
(register-count-arm! jolt-queue? (lambda (x) (jolt-queue-cnt x)))
(register-empty-arm! jolt-queue? (lambda (x) (fx=? 0 (jolt-queue-cnt x))))
(define %q-peek jolt-peek)
(set! jolt-peek (lambda (x) (if (jolt-queue? x) (queue-peek x) (%q-peek x))))
(define %q-pop jolt-pop)
(set! jolt-pop (lambda (x) (if (jolt-queue? x) (queue-pop x) (%q-pop x))))
(register-conj-arm! jolt-queue? queue-conj)
;; sequential => seq=?/seq-hash handle queue equality + hashing.
(define %q-sequential? jolt-sequential?)
(set! jolt-sequential? (lambda (x) (or (jolt-queue? x) (%q-sequential? x))))

;; printing: render the elements as a parenthesized list (delegate to the seq path).
(define (jolt-seq-or-empty x) (let ((s (jolt-seq x))) (if (jolt-nil? s) jolt-empty-list s)))
(register-pr-readable-arm! jolt-queue? (lambda (x) (jolt-pr-readable (jolt-seq-or-empty x))))
(register-str-render! jolt-queue? (lambda (x) (jolt-str-render-one (jolt-seq-or-empty x))))

;; class / type / instance? recognize a queue.
(register-class-arm! jolt-queue? (lambda (x) "clojure.lang.PersistentQueue"))
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (jolt-queue? val)
        (let ((tn (cond ((string? type-sym) type-sym)
                        ((symbol-t? type-sym) (symbol-t-name type-sym)) (else ""))))
          (and (member (last-dot tn)
                       '("PersistentQueue" "IPersistentCollection" "Sequential" "Collection" "Object"))
               #t))
        'pass)))

;; clojure.lang.PersistentQueue/EMPTY + a queue? predicate.
(register-class-statics! "PersistentQueue" (list (cons "EMPTY" jolt-queue-empty)))
(register-class-statics! "clojure.lang.PersistentQueue" (list (cons "EMPTY" jolt-queue-empty)))
(def-var! "clojure.core" "queue?" (lambda (x) (jolt-queue? x)))
;; the FQ class token self-evaluates to the interned Class object (for
;; (instance? clojure.lang.PersistentQueue …) and (= clojure.lang.PersistentQueue (type q))).
(def-var! "clojure.core" "clojure.lang.PersistentQueue" (jolt-class-for "clojure.lang.PersistentQueue"))

;; PersistentQueue's JVM taxonomy: an IPersistentStack (peek/pop), an ordinary
;; persistent collection, and a meta carrier.
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (and (jolt-queue? val) (symbol-t? type-sym))
        (let* ((tn (symbol-t-name type-sym))
               (short (let loop ((i (- (string-length tn) 1)))
                        (cond ((< i 0) tn)
                              ((char=? (string-ref tn i) #\.) (substring tn (+ i 1) (string-length tn)))
                              (else (loop (- i 1)))))))
          (if (member short '("IPersistentStack" "IPersistentCollection" "IPersistentList"
                              "Collection" "Seqable" "Sequential" "Counted" "IObj" "IMeta"
                              "Iterable"))
              #t 'pass))
        'pass)))
