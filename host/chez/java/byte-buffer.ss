;; byte-buffer.ss — java.nio.ByteBuffer. A buffer is a jhost tagged "byte-buffer"
;; with mutable #(backing position limit). Covers the slice of the API portable
;; code reaches for — wrap / get(byte[]) / array / remaining / position / limit /
;; duplicate / flip / rewind / getInt and the sibling widths — e.g. cognitect
;; aws-api wrapping blob bytes, or a binary codec framing a length prefix.
;;
;; TWO BACKINGS, which is java.nio's own heap/direct split:
;;
;;   - a jolt byte-array (signed bytes, -128..127) — ByteBuffer/wrap and
;;     ByteBuffer/allocate, the buffer that owns its bytes on jolt's heap;
;;   - FOREIGN MEMORY the buffer does not own, an address and a capacity —
;;     jolt.ffi/byte-buffer, which hands back a view of a pointer.
;;
;; The second is a real DIRECT buffer: the bytes are shared with C rather than
;; copied, so a put through the buffer is a write to the pointer and a C write
;; is visible to the next get. hasArray answers false and array raises there,
;; exactly as they do on the JVM, and slice shares the bytes instead of copying
;; them because there is a real address to offset. The buffer does not keep the
;; memory alive: using one after the pointer is released reads freed memory.

;; slot 3 is the ARRAY OFFSET of a heap buffer: index 0 of the buffer is that
;; element of the backing array. A slice is a fresh buffer over the SAME array
;; with its offset advanced -- which is what makes a write through either side
;; visible to the other, as java.nio's heap slice shares the array. A direct
;; buffer offsets its address instead and keeps 0 here.
(define (make-byte-buffer backing pos limit) (make-jhost "byte-buffer" (vector backing pos limit 0)))
(define (make-byte-buffer/off backing pos limit off) (make-jhost "byte-buffer" (vector backing pos limit off)))
(define (bb? x) (and (jhost? x) (string=? (jhost-tag x) "byte-buffer")))
(define (bb-backing b) (vector-ref (jhost-state b) 0))
(define (bb-pos b) (vector-ref (jhost-state b) 1))
(define (bb-limit b) (vector-ref (jhost-state b) 2))
(define (bb-off b) (vector-ref (jhost-state b) 3))
(define (bb-pos! b n) (vector-set! (jhost-state b) 1 n))
(define (bb-limit! b n) (vector-set! (jhost-state b) 2 n))

;; --- the direct backing ------------------------------------------------------
(define (bb-direct-backing addr cap) (vector 'jolt-direct-buffer addr cap))
(define (bb-direct-backing? x)
  (and (vector? x) (fx=? (vector-length x) 3) (eq? (vector-ref x 0) 'jolt-direct-buffer)))
(define (bb-direct? b) (bb-direct-backing? (bb-backing b)))
(define (bb-addr b) (vector-ref (bb-backing b) 1))
;; What jolt.ffi/byte-buffer answers: a direct buffer over `cap` bytes at `addr`.
(define (make-direct-byte-buffer addr cap)
  (make-byte-buffer (bb-direct-backing addr cap) 0 cap))

(define (bb-capacity b)
  (let ((bk (bb-backing b)))
    (if (bb-direct-backing? bk) (vector-ref bk 2) (- (ja-len bk) (bb-off b)))))

;; --- one byte, whichever backing --------------------------------------------
;; SIGNED, as a JVM byte[] element is: the heap backing already stores it that
;; way, and the foreign one narrows on the way in and widens on the way out, so
;; every accessor above this line reads the same values from either.
(define (bb-byte-ref b i)
  (let ((bk (bb-backing b)))
    (if (bb-direct-backing? bk)
        (na-u8->byte (sa-foreign-ref 'unsigned-8 (vector-ref bk 1) i))
        (ja-ref bk (+ (bb-off b) i)))))

(define (bb-byte-set! b i v)
  (let ((bk (bb-backing b)))
    (if (bb-direct-backing? bk)
        (sa-foreign-set! 'unsigned-8 (vector-ref bk 1) i (bitwise-and v #xff))
        (ja-set! bk (+ (bb-off b) i) v))))

;; --- bulk moves --------------------------------------------------------------
;; A byte at a time across the foreign boundary costs ~30ns; through a bytevector
;; and one memcpy it is ~4ns (see the block-move note in
;; host/chez/scheme-adapter-runtime.ss). A jolt byte-array is itself a bytevector
;; now, so the HEAP side is a block move too — ja-bytes->bv! / ja-bv->bytes!
;; (natives-array.ss) own that seam, including the element loop an array promoted
;; off its bytevector still needs.
(define (bb-bulk-ref! b idx dst doff n)          ; buffer -> jolt byte-array
  (let ((bk (bb-backing b)))
    (if (bb-direct-backing? bk)
        (let ((bv (make-bytevector n)))
          (sa-foreign-bytes-ref! (+ (vector-ref bk 1) idx) bv n)
          (ja-bv->bytes! bv 0 dst doff n))
        (ja-copy-range! bk (+ (bb-off b) idx) dst doff n))))

(define (bb-bulk-set! b idx src soff n)          ; jolt byte-array -> buffer
  (let ((bk (bb-backing b)))
    (if (bb-direct-backing? bk)
        (let ((bv (make-bytevector n)))
          (ja-bytes->bv! src soff bv 0 n)
          (sa-foreign-bytes-set! (+ (vector-ref bk 1) idx) bv n))
        (ja-copy-range! src soff bk (+ (bb-off b) idx) n))))

;; Buffer to buffer. Two heap buffers move backing to backing; anything touching
;; foreign memory goes through the block move above.
(define (bb-copy-between! src sidx dst didx n)
  (if (or (bb-direct? src) (bb-direct? dst))
      (let ((tmp (na-byte-array n)))
        (bb-bulk-ref! src sidx tmp 0 n)
        (bb-bulk-set! dst didx tmp 0 n))
      (ja-copy-range! (bb-backing src) (+ (bb-off src) sidx) (bb-backing dst) (+ (bb-off dst) didx) n)))

;; (ByteBuffer/wrap ba) | (ByteBuffer/wrap ba off len) | (ByteBuffer/allocate n)
(register-class-statics! "ByteBuffer"
  (list
    (cons "wrap" (lambda (ba . rest)
                   (let ((cap (ja-len ba)))
                     (if (pair? rest)
                         (let ((off (jnum->exact (car rest))) (len (jnum->exact (cadr rest))))
                           (make-byte-buffer ba off (+ off len)))
                         (make-byte-buffer ba 0 cap)))))
    (cons "allocate" (lambda (n)
                       (let ((cap (jnum->exact n)))
                         (make-byte-buffer (na-byte-array cap) 0 cap))))
    ;; jolt has one heap; a direct buffer is just a buffer here.
    (cons "allocateDirect" (lambda (n)
                             (let ((cap (jnum->exact n)))
                               (make-byte-buffer (na-byte-array cap) 0 cap))))))

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
    ;; A direct buffer has no backing array, and says so the way the JVM does.
    (cons "hasArray" (lambda (self) (not (bb-direct? self))))
    (cons "array" (lambda (self)
                    (if (bb-direct? self)
                        (throw-jvm 'UnsupportedOperationException
                                   "java.nio.ByteBuffer/array: a direct buffer has no backing array")
                        (bb-backing self))))
    (cons "arrayOffset" (lambda (self)
                          (if (bb-direct? self)
                              (throw-jvm 'UnsupportedOperationException
                                         "java.nio.ByteBuffer/arrayOffset: a direct buffer has no backing array")
                              (->num (bb-off self)))))
    (cons "duplicate" (lambda (self) (make-byte-buffer/off (bb-backing self) (bb-pos self) (bb-limit self) (bb-off self))))
    (cons "asReadOnlyBuffer" (lambda (self) (make-byte-buffer/off (bb-backing self) (bb-pos self) (bb-limit self) (bb-off self))))
    ;; slice(): a 0-based buffer over the remaining bytes [position, limit) that
    ;; SHARES them with this buffer, as the JVM's does: a direct slice offsets
    ;; the address, a heap slice offsets into the same backing array.
    (cons "slice" (lambda (self)
                    (let* ((p (bb-pos self)) (n (- (bb-limit self) p)))
                      (if (bb-direct? self)
                          (make-direct-byte-buffer (+ (bb-addr self) p) n)
                          (make-byte-buffer/off (bb-backing self) 0 n (+ (bb-off self) p))))))
    (cons "rewind" (lambda (self) (bb-pos! self 0) self))
    (cons "flip" (lambda (self) (bb-limit! self (bb-pos self)) (bb-pos! self 0) self))
    (cons "clear" (lambda (self) (bb-pos! self 0) (bb-limit! self (bb-capacity self)) self))
    ;; (.get dst) | (.get dst off len): bulk copy from position into a byte-array,
    ;; advancing position. Returns the buffer like the JVM.
    ;; (.put src): copy bytes into the buffer at position, advancing it. src is
    ;; another ByteBuffer (its remaining bytes), a byte-array, or a single byte.
    ;; put(byte): relative, advancing. put(int index, byte): absolute, position
    ;; unchanged. put(ByteBuffer): the source's remaining bytes. put(byte[] src
    ;; [off len]): bulk from the array, advancing.
    (cons "put" (lambda (self src . rest)
                  (let ((dp (bb-pos self)))
                    (cond
                      ((bb? src)
                       (let* ((sp (bb-pos src)) (n (- (bb-limit src) sp)))
                         (bb-copy-between! src sp self dp n)
                         (bb-pos! src (bb-limit src)) (bb-pos! self (+ dp n))))
                      ((jolt-array? src)
                       (let* ((off (if (pair? rest) (jnum->exact (car rest)) 0))
                              (n (if (and (pair? rest) (pair? (cdr rest))) (jnum->exact (cadr rest)) (ja-len src))))
                         (bb-bulk-set! self dp src off n)
                         (bb-pos! self (+ dp n))))
                      ((pair? rest)
                       (bb-byte-set! self (jnum->exact src) (na-byte-of (car rest))))
                      ;; a lone byte: narrowed like any byte-array store, so the
                      ;; backing stays in -128..127 whichever form the caller used.
                      (else (bb-byte-set! self dp (na-byte-of src)) (bb-pos! self (+ dp 1))))
                    self)))
    ;; get(): relative single byte at position, advancing it.
    ;; get(int i): absolute single byte at index i (position unchanged).
    ;; get(byte[] dst [off len]): bulk copy from position, advancing it.
    (cons "get" (lambda (self . args)
                  (cond
                    ((null? args)
                     (let ((p (bb-pos self))) (bb-pos! self (+ p 1)) (->num (bb-byte-ref self p))))
                    ((number? (car args))
                     (->num (bb-byte-ref self (jnum->exact (car args)))))
                    (else
                     (let* ((dst (car args)) (rest (cdr args))
                            (off (if (pair? rest) (jnum->exact (car rest)) 0))
                            (len (if (and (pair? rest) (pair? (cdr rest))) (jnum->exact (cadr rest)) (ja-len dst)))
                            (p (bb-pos self)))
                       (bb-bulk-ref! self p dst off len)
                       (bb-pos! self (+ p len))
                       self)))))))

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
  (do ((i 0 (fx+ i 1))
       (acc 0 (+ (* acc 256) (bitwise-and (bb-byte-ref self (+ idx i)) #xff))))
      ((fx=? i width) acc)))

(define (bb-set-unsigned! self idx width val)
  (let ((u (bitwise-and val (- (bitwise-arithmetic-shift-left 1 (* 8 width)) 1))))
    (do ((i 0 (fx+ i 1))) ((fx=? i width))
      (bb-byte-set! self (+ idx i)
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
