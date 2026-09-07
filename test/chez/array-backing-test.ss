;; Array backings: the Chez vector type each element kind holds its elements in.
;;   chez --script test/chez/array-backing-test.ss
;; Semantics are certified by the corpus; this pins the REPRESENTATION — an
;; fxvector for int/long/short, a bytevector for byte, an flvector for
;; double/float, a boxed vector for the rest — so a regression back to one boxed
;; vector for everything fails here even where every value test still passes.
;;
;; It also pins the two ways a kind's array is legitimately BOXED: a value past
;; Chez's fixnum range widens the backing (jolt's integers promote to bignums —
;; that is the numeric model, not an array rule), and an array restored from an
;; image written before the typed backings arrives boxed. Every accessor
;; dispatches on the backing rather than the kind so that both keep working, and
;; the rows below are what says so.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (evv s) (jolt-compile-eval (string-append "(do " s ")") "user"))
(define (ev s) (jolt-final-str (evv s)))
(define (is name s expect) (ok (string-append name " => " expect) (string=? (ev s) expect)))

(define (backing-of x)
  (let ((v (jolt-array-vec x)))
    (cond ((fxvector? v) 'fxvector)
          ((bytevector? v) 'bytevector)
          ((flvector? v) 'flvector)
          ((vector? v) 'vector)
          (else 'unknown))))
(define (backing name src want)
  (ok (string-append name " is " (symbol->string want) "-backed")
      (eq? want (backing-of (evv src)))))

;; --- one backing per element kind --------------------------------------------
(backing "int-array"     "(int-array 3)"                'fxvector)
(backing "long-array"    "(long-array [1 2 3])"         'fxvector)
(backing "short-array"   "(short-array 2)"              'fxvector)
(backing "byte-array"    "(byte-array [1 -2 3])"        'bytevector)
(backing "byte-array n"  "(byte-array 4)"               'bytevector)
(backing "double-array"  "(double-array [1.5])"         'flvector)
(backing "float-array"   "(float-array 2)"              'flvector)
(backing "char-array"    "(char-array 2)"               'vector)
(backing "boolean-array" "(boolean-array 2)"            'vector)
(backing "object-array"  "(object-array 2)"             'vector)
;; every other way in reaches the same table
(backing "make-array"    "(make-array Long/TYPE 3)"     'fxvector)
(backing "into-array"    "(into-array Integer/TYPE [1 2])" 'fxvector)
(backing "aclone"        "(aclone (byte-array 2))"      'bytevector)
(backing "Arrays/copyOf" "(java.util.Arrays/copyOf (long-array [1]) 4)" 'fxvector)
(backing ".getBytes"     "(.getBytes \"hi\")"           'bytevector)
(backing "readAllBytes"  "(.readAllBytes (java.io.ByteArrayInputStream. (byte-array 4)))" 'bytevector)
;; a reference array is boxed whatever it came from
(backing "into-array untyped" "(into-array [1 2])"      'vector)
(backing "to-array"      "(to-array [1 2])"             'vector)

;; --- widening past the fixnum range ------------------------------------------
(ok "a bignum store widens the backing"
    (let ((a (evv "(doto (long-array 3) (aset 0 Long/MAX_VALUE))")))
      (and (eq? 'vector (backing-of a)) (eq? 'long (jolt-array-kind a)))))
(ok "a bignum INIT is born widened"
    (eq? 'vector (backing-of (evv "(long-array 2 (*' Long/MAX_VALUE 2))"))))
(ok "a bignum in the seq is born widened"
    (eq? 'vector (backing-of (evv "(long-array [1 (*' Long/MAX_VALUE 2)])"))))
(ok "a non-integer store widens too"
    (eq? 'vector (backing-of (evv "(doto (int-array 2) (aset 0 1.5))"))))
(ok "a fixnum store does NOT widen"
    (eq? 'fxvector (backing-of (evv "(doto (long-array 2) (aset 0 -1) (aset 1 1152921504606846975))"))))
(ok "the hinted aset widens as the generic one does"
    (eq? 'vector (backing-of (evv "(let [a (long-array 2)] ((fn [^longs x ^long i v] (aset x i v)) a 0 (*' Long/MAX_VALUE 2)) a)"))))

;; a widened array is an ordinary array afterwards — every op reads it
(is "widened: read back" "(let [a (long-array 3)] (aset a 0 Long/MAX_VALUE) [(aget a 0) (vec a) (count a) (alength a)])"
    "[9223372036854775807 [9223372036854775807 0 0] 3 3]")
(is "widened: write past it" "(let [a (long-array 3)] (aset a 0 Long/MAX_VALUE) (aset a 1 7) (vec a))"
    "[9223372036854775807 7 0]")
(is "widened: copy / clone / sort / equals"
    "(let [a (long-array [1 2 3]) b (long-array 3)] (aset a 1 Long/MAX_VALUE) (System/arraycopy a 0 b 0 3) [(vec b) (java.util.Arrays/equals a b) (vec (aclone a)) (vec (doto (aclone a) java.util.Arrays/sort))])"
    "[[1 9223372036854775807 3] true [1 9223372036854775807 3] [1 3 9223372036854775807]]")
(is "widened: hinted aget reads it"
    "(let [a (long-array 2)] (aset a 1 Long/MAX_VALUE) ((fn [^longs x ^long i] (aget x i)) a 1))"
    "9223372036854775807")

;; --- a BOXED array of a typed kind (what a pre-backings image restores) -------
;; Built here the way the fasl reader would hand one back: the record with a
;; plain vector in it. Nothing may notice.
(define legacy-bytes (make-jolt-array (vector 1 -2 3) 'byte))
(define legacy-longs (make-jolt-array (vector 1 2) 'long))
(ok "a boxed byte array reads" (equal? '(1 -2 3) (ja->list legacy-bytes)))
(ok "a boxed byte array counts" (fx=? 3 (ja-len legacy-bytes)))
(ok "a boxed byte array writes, narrowing" (begin (na-array-set! legacy-bytes 0 200) (eqv? -56 (ja-ref legacy-bytes 0))))
(ok "a boxed byte array still answers [B" (string=? "[B" (na-array-class-name legacy-bytes)))
(ok "a boxed byte array crosses the raw-byte seam"
    (equal? '(200 254 3) (bytevector->u8-list (na-bytearray->bv legacy-bytes))))
(ok "a bytevector array copies INTO a boxed one"
    (let ((dst (make-jolt-array (vector 0 0) 'byte)))
      (ja-copy-range! (na-byte-array (jolt-vector 7 8)) 0 dst 0 2)
      (equal? '(7 8) (ja->list dst))))
(ok "equals across the two representations"
    (ja-equal? legacy-longs (na-long-array (jolt-vector 1 2))))
(ok "a boxed long array takes the hinted read" (eqv? 2 (jolt-vaget legacy-longs 1)))

;; --- byte elements stay signed, whichever door they came in -------------------
(is "byte narrowing at every entry point"
    "[(vec (byte-array [200 -1 127])) (let [a (byte-array 2)] (aset a 0 200) (aset-byte a 1 300) (vec a)) (vec (into-array Byte/TYPE [200])) (let [a (byte-array 1)] (java.util.Arrays/fill a 200) (vec a))]"
    "[[-56 -1 127] [-56 44] [-56] [-56]]")
(is "and round-trip through a String and back"
    "(let [bs (byte-array [-1 0 127 -128 65])] (vec (.getBytes (String. bs \"ISO-8859-1\") \"ISO-8859-1\")))"
    "[-1 0 127 -128 65]")

;; --- the HINTED byte store narrows exactly as the generic one does -------------
;; (aset ^bytes a i v) has its own store target (jolt-baset): an in-range fixnum
;; goes straight into the bytevector, and everything else falls back to the
;; generic seam that narrows it. These rows are the contract that fast path has
;; to keep — a hint may not change a value, only how fast it is stored.
(is "the hinted store narrows and ANSWERS what it stored"
    "(let [a (byte-array 2) f (fn [^bytes x ^long i v] (aset x i v))] [(f a 0 200) (f a 1 -5) (vec a)])"
    "[-56 -5 [-56 -5]]")
(is "...for every value shape the generic seam accepts"
    "(let [f (fn [^bytes x ^long i v] (aset x i v)) g (fn [v] (let [a (byte-array 1)] [(f a 0 v) (aget ^bytes a 0)]))] [(g 300) (g -1.9) (g 129.7) (g (*' Long/MAX_VALUE 2))])"
    "[[44 44] [-1 -1] [-127 -127] [-2 -2]]")
(is "...and agrees with the UNHINTED store on each of them"
    "(let [h (fn [^bytes x ^long i v] (aset x i v)) g (fn [f v] (let [a (byte-array 1)] (f a 0 v) (aget ^bytes a 0)))] (mapv (fn [v] [(g h v) (g (fn [a i x] (aset a i x)) v)]) [200 300 -5 -1.9 129.7 -128 127]))"
    "[[-56 -56] [44 44] [-5 -5] [-1 -1] [-127 -127] [-128 -128] [127 127]]")
(is "a flonum INDEX still floors on the hinted store"
    "(let [a (byte-array 3)] ((fn [^bytes x i] (aset x i 9)) a 2.7) (vec a))"
    "[0 0 9]")
(is "a LYING ^bytes hint stores through the kind the array really has"
    "(let [l (long-array 2) o (object-array 2) f (fn [^bytes x ^long i v] (aset x i v))] [(f l 0 1000) (vec l) (f o 0 :k) (vec o)])"
    "[1000 [1000 0] :k [:k nil]]")
(is "an out-of-range hinted store is the ARRAY exception, either direction"
    "[(try ((fn [^bytes x ^long i] (aset x i 1)) (byte-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try ((fn [^bytes x ^long i] (aset x i 1)) (byte-array 2) -1) (catch ArrayIndexOutOfBoundsException e :aioobe))]"
    "[:aioobe :aioobe]")
;; a byte array whose backing is BOXED — an older image's shape — cannot take the
;; bytevector store, and must still narrow through the seam it falls back to.
(let ((boxed (make-jolt-array (vector 0 0 0) 'byte)))
  (ok "a boxed byte backing narrows through the store helper"
      (and (eqv? -56 (jolt-baset boxed 0 200))
           (eqv? 7 (jolt-baset boxed 1 7))
           (equal? '(-56 7 0) (ja->list boxed)))))

;; --- the block moves ----------------------------------------------------------
(is "an overlapping arraycopy reads pre-copy values, both directions and both backings"
    "(let [f (fn [a] (System/arraycopy a 0 a 1 4) (vec a)) b (fn [a] (System/arraycopy a 1 a 0 4) (vec a))] [(f (byte-array [1 2 3 4 5])) (b (byte-array [1 2 3 4 5])) (f (long-array [1 2 3 4 5])) (b (long-array [1 2 3 4 5]))])"
    "[[1 1 2 3 4] [2 3 4 5 5] [1 1 2 3 4] [2 3 4 5 5]]")
(is "a stream read fills a byte-array region"
    "(let [in (java.io.ByteArrayInputStream. (byte-array [10 20 30 40 50])) buf (byte-array 8)] [(.read in buf 2 4) (vec buf)])"
    "[4 [0 0 10 20 30 40 0 0]]")
(is "a ByteBuffer bulk get/put moves bytes"
    "(let [src (java.nio.ByteBuffer/wrap (byte-array [1 2 3 4])) dst (java.nio.ByteBuffer/allocate 4) out (byte-array 4)] (.put dst src) (.rewind dst) (.get dst out) (vec out))"
    "[1 2 3 4]")

;; --- an out-of-range hinted read is the ARRAY exception ----------------------
(is "the hinted reads classify their own range error"
    "[(try ((fn [^longs a ^long i] (aget a i)) (long-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try ((fn [^bytes a ^long i] (aget a i)) (byte-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try ((fn [^doubles a ^long i] (aget a i)) (double-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe))]"
    "[:aioobe :aioobe :aioobe]")
;; ...including the BOXED ones, which pre-check because vector-ref's condition
;; cannot be told from any other vector in the runtime. The hint must not decide
;; which exception class a program catches: the same reads without it, and a
;; widened long array, answer the same way.
(is "a boxed hinted read/write classifies too"
    "[(try ((fn [^objects a ^long i] (aget a i)) (object-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try ((fn [^objects a ^long i] (aset a i 1)) (object-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try (aget (object-array 2) 9) (catch ArrayIndexOutOfBoundsException e :aioobe)) (try (let [a (long-array 2)] (aset a 0 Long/MAX_VALUE) ((fn [^longs x ^long i] (aget x i)) a 9)) (catch ArrayIndexOutOfBoundsException e :aioobe))]"
    "[:aioobe :aioobe :aioobe :aioobe]")

(printf "array-backing-test: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
