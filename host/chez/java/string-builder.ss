;; string-builder.ss — java.lang.StringBuilder and StringBuffer over the jhost
;; record: the builder every (StringBuilder.) in core and the stdlib constructs
;; (pprint's column writer, cl-format, with-out-str's sink), its method table,
;; and the count / seq / str / class / instance? arms that make a builder a
;; CharSequence. Shared by every target; the emitter's proven-StringBuilder
;; fast path (backend_scheme.clj sb-direct-emit) calls sb-append! / sb-str /
;; sb-length / render-piece directly, so their bodies and the method table's
;; are one definition.
;;
;; Needs the jhost record, register-class-ctor! / register-host-methods!, the
;; value-model arm registries (records / records-interop / host-class) and
;; throw-jvm; loads after those and before anything that constructs a builder.

;; ---- StringBuilder ----------------------------------------------------------
;; state: #(materialised-string pending-chunks-reversed pending-length).
;;
;; Appends accumulate as a list of chunks and are joined only when something
;; reads the buffer. The obvious representation — one string, appended to with
;; string-append — copies the whole buffer on every append, which makes building
;; an n-char string O(n^2). That is not theoretical: clojure.data.json reads a
;; quoted string a character at a time into a StringBuilder, so one 88KB JSON
;; string value cost 623ms to parse against 30ms for the same bytes spread over
;; many short values. See test/chez/string-builder-perf.ss.
;;
;; Every other method still reads through sb-str, so it flushes first and
;; behaves exactly as before; only append and the two size reads skip the join.
(define (sb-str self)
  (let* ((st (jhost-state self))
         (pending (vector-ref st 1)))
    (if (null? pending)
        (vector-ref st 0)
        (let* ((base (vector-ref st 0))
               (blen (string-length base))
               (out (make-string (+ blen (vector-ref st 2)))))
          (sa-string-copy-range! out 0 base 0 blen)
          (let loop ((cs (reverse pending)) (i blen))
            (if (null? cs)
                (begin (vector-set! st 0 out)
                       (vector-set! st 1 '())
                       (vector-set! st 2 0)
                       out)
                (let* ((c (car cs)) (n (string-length c)))
                  (sa-string-copy-range! out i c 0 n)
                  (loop (cdr cs) (+ i n)))))))))
(define (sb-set! self s)
  (let ((st (jhost-state self)))
    (vector-set! st 0 s)
    (vector-set! st 1 '())
    (vector-set! st 2 0)))
;; O(1): the chunk is retained as-is and nothing is copied until a read.
(define (sb-append! self piece)
  (let ((st (jhost-state self)))
    (vector-set! st 1 (cons piece (vector-ref st 1)))
    (vector-set! st 2 (+ (vector-ref st 2) (string-length piece)))))
;; Size without flushing, so the common `while (.length sb) < n: append` shape
;; does not force a join per iteration and put the O(n^2) straight back.
(define (sb-length self)
  (let ((st (jhost-state self)))
    (+ (string-length (vector-ref st 0)) (vector-ref st 2))))
(define (render-piece x)
  (cond ((jolt-nil? x) "null") ((char? x) (string x)) ((string? x) x)
        (else (jolt-str-render-one x))))

;; Appendable.append text: append(x) renders x; append(csq,start,end) appends the
;; subsequence csq[start,end) (data.json's writer appends string runs this way).
(define (append-text x rest)
  (if (null? rest)
      (render-piece x)
      (substring (render-piece x) (jnum->exact (car rest)) (jnum->exact (cadr rest)))))

;; The bounds every (offset, len) region shares, reported the way the JVM reports
;; them: the half-open range that was asked for, against the length there was.
;; WHO is the exception class, which the JDK picks per call site and jolt follows
;; — StringBuilder.append(char[],off,len) raises the plain IndexOutOfBounds,
;; .insert and String.valueOf the StringIndexOutOfBounds that extends it.
(define (jvm-range-check who len off end)
  ;; generic comparisons, not fx: an offset a caller got wrong can be any integer,
  ;; and a bignum must report as the out-of-range index it is rather than fault
  ;; inside a fixnum primitive
  (when (or (< off 0) (> off end) (> end len))
    (throw-jvm who
               (string-append "Range [" (number->string off) ", " (number->string end)
                              ") out of bounds for length " (number->string len)))))
;; What StringBuilder.append / .insert put in the buffer. The char[] overloads are
;; the ones append-text cannot serve: their 3-arg form is (offset, len) over the
;; ARRAY, where the CharSequence one is (start, end) over the rendering.
;; char-array->string / char-array-chunk are natives-array.ss's (the char[]
;; backing lives there); the predicate is here because every target answers it —
;; one with no arrays answers #f from its jolt-array? and never enters the other
;; two.
(define (char-array-arg? x) (and (jolt-array? x) (eq? (jolt-array-kind x) 'char)))
(define (sb-piece x)
  ;; string first: this runs on the open-coded .append path (sb-direct-emit), where
  ;; a string is nearly every argument, and render-piece would reach its own string
  ;; arm only after two failed tests.
  (cond ((string? x) x)
        ((char-array-arg? x) (char-array->string x))
        (else (render-piece x))))
(define (sb-piece-range x a b who)
  (if (char-array-arg? x)
      (char-array-chunk x (jnum->exact a) (jnum->exact b) who)
      (append-text x (list a b))))

;; Every index-taking StringBuilder method reports the same way the JVM does.
(define (sb-range-check s start end)
  (let ((n (string-length s)))
    (when (or (< start 0) (> end n) (> start end))
      (throw-jvm (quote StringIndexOutOfBoundsException)
                 (string-append "start " (number->string start) ", end " (number->string end)
                                ", length " (number->string n))))))

(define (string-builder-state args)
  ;; a numeric first arg is a CAPACITY hint, not content; nil is the
  ;; NullPointerException the JVM's String ctor raises.
  (vector (cond ((null? args) "")
                ((jolt-nil? (car args)) (throw-jvm 'NullPointerException "str"))
                ((number? (car args)) "")
                (else (render-piece (car args))))
          '() 0))
(register-class-ctor! "StringBuilder"
  (lambda args (make-jhost "string-builder" (string-builder-state args))))
(define string-builder-methods
  ;; The overloaded members are case-lambdas, not one rest-taking arm: the arities
  ;; are the overload set the JVM resolves against, and host-arity-ok? reads them
  ;; off the procedure (host-static.ss). One arm that picked its extra arguments
  ;; out of a list is how (.append sb "x" 1) reached `cadr` on a one-element list
  ;; and reported Chez's "incorrect list structure" for what is an arity error.
  (list (cons "append"
              (case-lambda
                ((self x) (sb-append! self (sb-piece x)) self)
                ((self x a b)
                 (sb-append! self (sb-piece-range x a b (quote IndexOutOfBoundsException)))
                 self)))
        (cons "toString" (lambda (self) (sb-str self)))
        (cons "length" (lambda (self) (->num (sb-length self))))
        (cons "charAt" (lambda (self i) (string-ref (sb-str self) (jnum->exact i))))
        (cons "setLength" (lambda (self n)
                            (let ((cur (sb-str self)) (n (jnum->exact n)))
                              (sb-set! self (if (< n (string-length cur))
                                                (substring cur 0 n)
                                                (string-append cur (make-string (- n (string-length cur)) #\nul)))))
                            jolt-nil))
        (cons "isEmpty" (lambda (self) (= 0 (sb-length self))))
        (cons "substring"
              (case-lambda
                ((self start) (let* ((cur (sb-str self)) (s (jnum->exact start)))
                                (sb-range-check cur s (string-length cur))
                                (substring cur s (string-length cur))))
                ((self start end) (let* ((cur (sb-str self)) (s (jnum->exact start))
                                         (e (jnum->exact end)))
                                    (sb-range-check cur s e)
                                    (substring cur s e)))))
        ;; CharSequence.subSequence — AbstractStringBuilder returns substring(a, b),
        ;; i.e. a String, which is itself a CharSequence.
        (cons "subSequence" (lambda (self a b)
                              (let* ((cur (sb-str self)) (s (jnum->exact a)) (e (jnum->exact b)))
                                (sb-range-check cur s e)
                                (substring cur s e))))
        (cons "indexOf"
              (case-lambda
                ((self needle) (->num (str-index-of (sb-str self) (render-piece needle) 0)))
                ((self needle from)
                 (->num (str-index-of (sb-str self) (render-piece needle) (jnum->exact from))))))
        (cons "lastIndexOf" (lambda (self needle)
                              (->num (str-last-index-of (sb-str self) (render-piece needle)))))
        (cons "setCharAt" (lambda (self i ch)
                            (let* ((cur (sb-str self)) (i (jnum->exact i)))
                              (sb-range-check cur i (+ i 1))
                              (sb-set! self (string-append (substring cur 0 i) (render-piece ch)
                                                           (substring cur (+ i 1) (string-length cur)))))
                            jolt-nil))
        (cons "deleteCharAt" (lambda (self i)
                               (let* ((cur (sb-str self)) (i (jnum->exact i)))
                                 (sb-range-check cur i (+ i 1))
                                 (sb-set! self (string-append (substring cur 0 i)
                                                              (substring cur (+ i 1) (string-length cur)))))
                               self))
        ;; delete clamps its end to the length, the way the JVM does.
        (cons "delete" (lambda (self start end)
                         (let* ((cur (sb-str self)) (n (string-length cur))
                                (s (jnum->exact start)) (e (min n (jnum->exact end))))
                           (sb-range-check cur s (max s e))
                           (sb-set! self (string-append (substring cur 0 s) (substring cur (max s e) n))))
                         self))
        (cons "replace" (lambda (self start end txt)
                          (let* ((cur (sb-str self)) (n (string-length cur))
                                 (s (jnum->exact start)) (e (min n (jnum->exact end))))
                            (sb-range-check cur s (max s e))
                            (sb-set! self (string-append (substring cur 0 s) (render-piece txt)
                                                         (substring cur (max s e) n))))
                          self))
        (cons "insert"
              (let ((ins (lambda (self offset piece)
                           (let* ((cur (sb-str self)) (n (string-length cur))
                                  (i (jnum->exact offset)))
                             (sb-range-check cur i i)
                             (sb-set! self (string-append (substring cur 0 i) piece
                                                          (substring cur i n))))
                           self)))
                (case-lambda
                  ((self offset x) (ins self offset (sb-piece x)))
                  ((self offset x a b)
                   (ins self offset
                        (sb-piece-range x a b (quote StringIndexOutOfBoundsException)))))))
        ;; .getChars srcBegin srcEnd dst dstBegin — the CharSequence copy-out the
        ;; String method already had (natives-str.ss). Both ends are checked before
        ;; anything is written, so a bad request does not leave the destination half
        ;; filled; the destination's own error is the plain IndexOutOfBounds.
        (cons "getChars"
              (lambda (self src-begin src-end dst dst-begin)
                (let* ((cur (sb-str self))
                       (s (jnum->exact src-begin)) (e (jnum->exact src-end))
                       (d (jnum->exact dst-begin)))
                  (jvm-range-check (quote StringIndexOutOfBoundsException) (string-length cur) s e)
                  (jvm-range-check (quote IndexOutOfBoundsException) (ja-len dst) d (+ d (- e s)))
                  (let ((v (jolt-array-vec dst)))
                    (if (string? v)
                        (sa-string-copy-range! v d cur s e)
                        (let loop ((i s) (j d))
                          (when (fx<? i e)
                            (ja-set! dst j (string-ref cur i))
                            (loop (fx+ i 1) (fx+ j 1)))))))
                jolt-nil))
        (cons "reverse" (lambda (self)
                          (sb-set! self (list->string (reverse (string->list (sb-str self)))))
                          self))))
(register-host-methods! "string-builder" string-builder-methods)

;; StringBuffer — the legacy synchronized builder, over the SAME store and the
;; same method set. Nothing in jolt runs two threads into one builder, so the
;; synchronization is not observable and the only thing that must differ is the
;; class a value reports: a second tag, not a second ctor onto "string-builder",
;; because (class (StringBuffer.)) and (instance? StringBuffer x) have to answer
;; with the class the caller wrote. rewrite-clj's reader (cljfmt's parser) builds
;; one per token, which is what made the gap load-bearing.
(register-class-ctor! "StringBuffer"
  (lambda args (make-jhost "string-buffer" (string-builder-state args))))
(register-host-methods! "string-buffer" string-builder-methods)

;; (str sb) / print a StringBuilder -> its accumulated content, like the JVM
;; (str calls toString). Without this str renders the opaque host object.
;; Both tags answer here: every arm below is about the shared store, so asking
;; the tag literally at any one of them is how a StringBuffer silently stops
;; being countable, seqable or printable while a StringBuilder still is.
(define (sb-builder-jhost? x) (and (jhost? x) (string=? (jhost-tag x) "string-builder")))
(define (sb-buffer-jhost? x) (and (jhost? x) (string=? (jhost-tag x) "string-buffer")))
(define (sb-jhost? x) (or (sb-builder-jhost? x) (sb-buffer-jhost? x)))
(define (sb-class-name x)
  (if (sb-buffer-jhost? x) "java.lang.StringBuffer" "java.lang.StringBuilder"))
(register-str-render! sb-jhost? sb-str)
;; A StringBuilder IS a java.lang.CharSequence, so it answers (class …),
;; instance? through the class graph, and the three RT entry points that name a
;; CharSequence — count is its length, seq walks its characters, nth reads one.
;; Without the class arm (class sb) leaked the :object placeholder.
(register-class-arm! sb-jhost? sb-class-name)
;; An array class reaches instance-check as a raw string ("[C"), not a symbol, and
;; this arm is newer than the base taxonomy so it is asked first — hence the
;; symbol-t? guard before reading the name.
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (and (sb-jhost? val) (symbol-t? type-sym))
        (jch-isa? (sb-class-name val) (symbol-t-name type-sym))
        'pass)))
(register-count-arm! sb-jhost? (lambda (x) (sb-length x)))
(register-seq-arm! sb-jhost? (lambda (x) (jolt-seq (sb-str x))))
