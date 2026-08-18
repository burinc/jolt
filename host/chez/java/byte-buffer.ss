;; byte-buffer.ss — java.nio.ByteBuffer over a jolt byte-array. A buffer is a
;; jhost tagged "byte-buffer" with mutable #(backing-array position limit); the
;; backing is a jolt byte-array (signed bytes, -128..127). Covers the slice of the API
;; portable code reaches for — wrap / get(byte[]) / array / remaining / position /
;; limit / duplicate / flip / rewind / getInt and the sibling widths — e.g. cognitect
;; aws-api wrapping blob bytes, or a binary codec framing a length prefix.

(define (make-byte-buffer backing pos limit) (make-jhost "byte-buffer" (vector backing pos limit)))
(define (bb? x) (and (jhost? x) (string=? (jhost-tag x) "byte-buffer")))
(define (bb-backing b) (vector-ref (jhost-state b) 0))
(define (bb-pos b) (vector-ref (jhost-state b) 1))
(define (bb-limit b) (vector-ref (jhost-state b) 2))
(define (bb-pos! b n) (vector-set! (jhost-state b) 1 n))
(define (bb-limit! b n) (vector-set! (jhost-state b) 2 n))
(define (bb-capacity b) (vector-length (jolt-array-vec (bb-backing b))))

;; (ByteBuffer/wrap ba) | (ByteBuffer/wrap ba off len) | (ByteBuffer/allocate n)
(register-class-statics! "ByteBuffer"
  (list
    (cons "wrap" (lambda (ba . rest)
                   (let ((cap (vector-length (jolt-array-vec ba))))
                     (if (pair? rest)
                         (let ((off (jnum->exact (car rest))) (len (jnum->exact (cadr rest))))
                           (make-byte-buffer ba off (+ off len)))
                         (make-byte-buffer ba 0 cap)))))
    (cons "allocate" (lambda (n)
                       (let ((cap (jnum->exact n)))
                         (make-byte-buffer (make-jolt-array (make-vector cap 0) 'byte) 0 cap))))
    ;; jolt has one heap; a direct buffer is just a buffer here.
    (cons "allocateDirect" (lambda (n)
                             (let ((cap (jnum->exact n)))
                               (make-byte-buffer (make-jolt-array (make-vector cap 0) 'byte) 0 cap))))))

(register-host-methods! "byte-buffer"
  (list
    (cons "remaining" (lambda (self) (->num (- (bb-limit self) (bb-pos self)))))
    (cons "hasRemaining" (lambda (self) (> (bb-limit self) (bb-pos self))))
    ;; position / limit are getters with no arg, setters (returning the buffer) with one
    (cons "position" (lambda (self . a)
                       (if (pair? a) (begin (bb-pos! self (jnum->exact (car a))) self) (->num (bb-pos self)))))
    (cons "limit" (lambda (self . a)
                    (if (pair? a) (begin (bb-limit! self (jnum->exact (car a))) self) (->num (bb-limit self)))))
    (cons "capacity" (lambda (self) (->num (bb-capacity self))))
    (cons "hasArray" (lambda (self) #t))
    (cons "array" (lambda (self) (bb-backing self)))
    (cons "duplicate" (lambda (self) (make-byte-buffer (bb-backing self) (bb-pos self) (bb-limit self))))
    (cons "asReadOnlyBuffer" (lambda (self) (make-byte-buffer (bb-backing self) (bb-pos self) (bb-limit self))))
    ;; slice(): a 0-based buffer over the remaining bytes [position, limit). The
    ;; JVM shares the backing; here it is a copy, so writes don't propagate back
    ;; (read paths — hexdumps, decoders — are unaffected).
    (cons "slice" (lambda (self)
                    (let* ((src (jolt-array-vec (bb-backing self))) (p (bb-pos self))
                           (n (- (bb-limit self) p)) (nv (make-vector n 0)))
                      (do ((i 0 (fx+ i 1))) ((fx=? i n)) (vector-set! nv i (vector-ref src (+ p i))))
                      (make-byte-buffer (make-jolt-array nv 'byte) 0 n))))
    (cons "rewind" (lambda (self) (bb-pos! self 0) self))
    (cons "flip" (lambda (self) (bb-limit! self (bb-pos self)) (bb-pos! self 0) self))
    (cons "clear" (lambda (self) (bb-pos! self 0) (bb-limit! self (bb-capacity self)) self))
    ;; (.get dst) | (.get dst off len): bulk copy from position into a byte-array,
    ;; advancing position. Returns the buffer like the JVM.
    ;; (.put src): copy bytes into the buffer at position, advancing it. src is
    ;; another ByteBuffer (its remaining bytes), a byte-array, or a single byte.
    (cons "put" (lambda (self src . rest)
                  (let ((dv (jolt-array-vec (bb-backing self))) (dp (bb-pos self)))
                    (cond
                      ((bb? src)
                       (let* ((sv (jolt-array-vec (bb-backing src))) (sp (bb-pos src))
                              (n (- (bb-limit src) sp)))
                         (do ((i 0 (fx+ i 1))) ((fx=? i n))
                           (vector-set! dv (+ dp i) (vector-ref sv (+ sp i))))
                         (bb-pos! src (bb-limit src)) (bb-pos! self (+ dp n))))
                      ((jolt-array? src)
                       (let* ((sv (jolt-array-vec src)) (n (vector-length sv)))
                         (do ((i 0 (fx+ i 1))) ((fx=? i n))
                           (vector-set! dv (+ dp i) (vector-ref sv i)))
                         (bb-pos! self (+ dp n))))
                      ;; a lone byte: narrowed like any byte-array store, so the
                      ;; backing stays in -128..127 whichever form the caller used.
                      (else (vector-set! dv dp (na-byte-of src)) (bb-pos! self (+ dp 1))))
                    self)))
    ;; get(): relative single byte at position, advancing it.
    ;; get(int i): absolute single byte at index i (position unchanged).
    ;; get(byte[] dst [off len]): bulk copy from position, advancing it.
    (cons "get" (lambda (self . args)
                  (let ((src (jolt-array-vec (bb-backing self))))
                    (cond
                      ((null? args)
                       (let ((p (bb-pos self))) (bb-pos! self (+ p 1)) (->num (vector-ref src p))))
                      ((number? (car args))
                       (->num (vector-ref src (jnum->exact (car args)))))
                      (else
                       (let* ((dst (car args)) (rest (cdr args)) (dv (jolt-array-vec dst))
                              (off (if (pair? rest) (jnum->exact (car rest)) 0))
                              (len (if (and (pair? rest) (pair? (cdr rest))) (jnum->exact (cadr rest)) (vector-length dv)))
                              (p (bb-pos self)))
                         (do ((i 0 (+ i 1))) ((= i len))
                           (vector-set! dv (+ off i) (vector-ref src (+ p i))))
                         (bb-pos! self (+ p len))
                         self))))))))

;; --- multi-byte accessors ----------------------------------------------------
;; getInt / putInt and the sibling widths, big-endian: that is the JVM's default
;; byte order, and .order (little-endian) is deliberately not shimmed, so a caller
;; asking for it gets "no matching method" rather than silently big-endian bytes.
;; Each accessor has both JVM overloads — a relative form starting at position and
;; advancing it by the width, and an absolute form taking an index that leaves
;; position alone. getShort/getInt/getLong read back SIGNED, so (.getInt) over
;; 0xF0000000 is negative exactly as on the JVM; getChar is a UTF-16 code unit and
;; so reads unsigned, as a character.

;; The width bytes at idx, big-endian, as an unsigned integer. The backing holds
;; signed bytes, hence the mask on each one.
(define (bb-ref-unsigned self idx width)
  (let ((v (jolt-array-vec (bb-backing self))))
    (do ((i 0 (fx+ i 1))
         (acc 0 (+ (* acc 256) (bitwise-and (vector-ref v (+ idx i)) #xff))))
        ((fx=? i width) acc))))

(define (bb-set-unsigned! self idx width val)
  (let ((v (jolt-array-vec (bb-backing self)))
        (u (bitwise-and val (- (bitwise-arithmetic-shift-left 1 (* 8 width)) 1))))
    (do ((i 0 (fx+ i 1))) ((fx=? i width))
      (vector-set! v (+ idx i)
                   (na-u8->byte
                     (bitwise-and (bitwise-arithmetic-shift-right u (* 8 (fx- width (fx+ i 1)))) #xff))))))

;; Build both overloads of one width. `in` maps a stored unsigned integer to what
;; the getter hands back; `out` maps a setter argument to an integer to store.
(define (bb-num-accessors nm width in out)
  (list
    (cons (string-append "get" nm)
          (lambda (self . a)
            (if (pair? a)
                (in (bb-ref-unsigned self (jnum->exact (car a)) width))
                (let ((p (bb-pos self)))
                  (bb-pos! self (+ p width))
                  (in (bb-ref-unsigned self p width))))))
    (cons (string-append "put" nm)
          (lambda (self a . b)
            (if (pair? b)
                (bb-set-unsigned! self (jnum->exact a) width (out (car b)))
                (let ((p (bb-pos self)))
                  (bb-set-unsigned! self p width (out a))
                  (bb-pos! self (+ p width))))
            self))))

;; Reinterpret an unsigned width-byte integer as a two's-complement signed one.
(define (bb-signed width)
  (lambda (u)
    (->num (if (>= u (bitwise-arithmetic-shift-left 1 (- (* 8 width) 1)))
               (- u (bitwise-arithmetic-shift-left 1 (* 8 width)))
               u))))

(register-host-methods! "byte-buffer"
  (append
    (bb-num-accessors "Short" 2 (bb-signed 2) jnum->exact)
    (bb-num-accessors "Int"   4 (bb-signed 4) jnum->exact)
    (bb-num-accessors "Long"  8 (bb-signed 8) jnum->exact)
    ;; a char is a UTF-16 code unit: unsigned in, a character out. putChar takes
    ;; either a character or its code point, the way jolt's other char shims do.
    (bb-num-accessors "Char"  2 integer->char
                      (lambda (c) (if (char? c) (char->integer c) (jnum->exact c))))))

(register-class-arm! bb? (lambda (x) "java.nio.ByteBuffer"))
(register-instance-check-arm!
  (lambda (type-sym val)
    (if (and (symbol-t? type-sym) (bb? val)
             (member (last-dot (symbol-t-name type-sym)) '("ByteBuffer")))
        #t 'pass)))
