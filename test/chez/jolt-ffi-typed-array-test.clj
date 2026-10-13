;; jolt.ffi typed array moves — read-array / write-array with a type wider
;; than a byte. The host block-copies the memory and decodes it into
;; (or encodes it out of) the array's flvector or fxvector backing; the property
;; under test is that this answers exactly what the element loop it replaced
;; answers — the same values, the same array class, a backing aset and aget
;; still work on — for every width, at an offset, at 0, 1 and past the 8192
;; elements where a large backing is pinned.
;; Run: bin/jolt run test/chez/jolt-ffi-typed-array-test.clj, or `make ffi`;
;; exits nonzero on a failure, and smoke.sh greps for
;; "JOLT-FFI-TYPED-ARRAY-TEST OK".
(ns jolt-ffi-typed-array-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(let [g# ~got w# ~want]
     (when-not (= g# w#)
       (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#))))))

;; Two NaNs are not =, so compare elements with NaN spelled as a keyword
(defn- elems [arr] (mapv #(if (and (float? %) (Double/isNaN (double %))) :nan %) arr))

;; The element loop read-array ran before the block decode, kept here as the
;; reference the native path is held to.
(def carriers
  {:double [double-array :double 8]
   :float  [float-array :float 4]
   :int64  [long-array :int64 8]
   :int32  [int-array :int32 4]
   :uint32 [int-array :int32 4]
   :int16  [short-array :int16 2]
   :uint16 [short-array :int16 2]})

(defn- loop-read [p t n off]
  (let [[ctor element width] (carriers t)
        arr (ctor n)]
    (dotimes [i n] (aset arr i (ffi/read p element (+ off (* i width)))))
    arr))

(def samples
  {:double [0.0 -0.0 1.5 -2.5 1e300 -1e300 Double/MAX_VALUE Double/MIN_VALUE
            Double/POSITIVE_INFINITY Double/NEGATIVE_INFINITY Double/NaN]
   :float  [0.0 -0.0 1.5 -2.5 0.1 3.4e38 -3.4e38 1.4e-45
            Double/POSITIVE_INFINITY Double/NEGATIVE_INFINITY Double/NaN]
   :int64  [0 1 -1 Long/MAX_VALUE Long/MIN_VALUE 1152921504606846975 -1152921504606846976]
   :int32  [0 1 -1 2147483647 -2147483648 123456]
   :uint32 [0 1 4294967295 2147483648]
   :int16  [0 1 -1 32767 -32768 1234]
   :uint16 [0 1 65535 32768]})

(def buf (ffi/alloc (* 8 10000)))

(defn- fill! [t vs off]
  (let [[_ element width] (carriers t)
        wtype ({:uint32 :uint32 :uint16 :uint16} t element)]
    (doseq [[i v] (map-indexed vector vs)]
      (ffi/write buf wtype v (+ off (* i width))))))

;; --- read-array: the native decode answers what the loop answers ----------
(doseq [t (keys samples)
        off [0 8 12]]
  (let [vs (samples t) n (count vs)]
    (fill! t vs off)
    (let [got (ffi/read-array buf t n off)
          want (loop-read buf t n off)]
      (check-eq (str "read-array " t " at offset " off " matches the element loop")
                (elems got) (elems want))
      (check-eq (str "read-array " t " answers the loop's array class")
                (class got) (class want))
      (check-eq (str "read-array " t " has n elements") (alength got) n))))

(check-eq "read-array :double reads the values written"
          (elems (do (fill! :double [1.5 -2.5 Double/NaN] 0)
                     (ffi/read-array buf :double 3)))
          [1.5 -2.5 :nan])
(check-eq "read-array :float reads single precision"
          (do (fill! :float [0.1] 0) (aget (ffi/read-array buf :float 1) 0))
          (float 0.1))
(check-eq "read-array :float elements are Floats"
          (class (aget (ffi/read-array buf :float 1) 0)) Float)
(check-eq "read-array :uint32 above Integer/MAX_VALUE reads back negative"
          (do (fill! :uint32 [4294967295] 0) (vec (ffi/read-array buf :uint32 1)))
          [-1])
(check-eq "read-array :int64 keeps a value past the fixnum range"
          (do (fill! :int64 [5 Long/MAX_VALUE Long/MIN_VALUE 7] 0)
              (vec (ffi/read-array buf :int64 4)))
          [5 Long/MAX_VALUE Long/MIN_VALUE 7])

;; --- sizes: 0, 1, and past the pinning threshold --------------------------
(doseq [t [:double :float :int64 :int32 :int16]
        n [0 1 9000]]
  (let [[_ element width] (carriers t)]
    (dotimes [i n] (ffi/write buf element (if (#{:double :float} t) (* 0.5 i) (- i 4500)) (* i width)))
    (let [got (ffi/read-array buf t n)]
      (check-eq (str "read-array " t " of " n " matches the element loop")
                (vec got) (vec (loop-read buf t n 0)))
      (check-eq (str "read-array " t " of " n " has alength " n) (alength got) n))))

;; --- a negative count -----------------------------------------------------
;; The JVM's NegativeArraySizeException, as (double-array -1) raises, and not a
;; Scheme constructor's message.
(defn- thrown [f]
  (try (f) :no-throw
       (catch Throwable e [(.getName (class e)) (ex-message e)])))
(doseq [t [:double :float :int64 :int32 :int16 :uint8]]
  (check-eq (str "read-array " t " of -1 throws NegativeArraySizeException")
            (thrown #(ffi/read-array buf t -1))
            ["java.lang.NegativeArraySizeException" "-1"]))
(check-eq "read-array of -3 raw octets throws NegativeArraySizeException"
          (thrown #(ffi/read-array buf -3))
          ["java.lang.NegativeArraySizeException" "-3"])

;; --- the answer is an ordinary array afterwards ---------------------------
(doseq [t [:double :float :int64 :int32 :int16]
        n [4 9000]]
  (let [arr (ffi/read-array buf t n)
        v (if (#{:double :float} t) 2.5 -7)]
    (aset arr (dec n) v)
    (check-eq (str "aset / aget work on a read-array " t " of " n)
              (aget arr (dec n)) (aget (doto ((first (carriers t)) 1) (aset 0 v)) 0))))
(let [arr (do (fill! :int64 [1 2 3] 0) (ffi/read-array buf :int64 3))]
  (aset arr 1 Long/MAX_VALUE)
  (check-eq "a read-array :int64 widens on a later aset like any long-array"
            (vec arr) [1 Long/MAX_VALUE 3]))

;; --- write-array: the block encode lands the bits the loop landed ---------
(doseq [t (keys samples)
        off [0 4 8]]
  (let [vs (samples t)
        [ctor element width] (carriers t)
        arr (ctor (count vs))]
    (doseq [[i v] (map-indexed vector vs)]
      (aset arr i (if (#{:uint32 :uint16} t) (ffi/read (doto buf (ffi/write t v)) element) v)))
    (check-eq (str "write-array " t " answers the element count")
              (ffi/write-array buf t arr off) (count vs))
    (check-eq (str "write-array " t " at offset " off " round-trips through read")
              (elems (map #(ffi/read buf element (+ off (* % width))) (range (count vs))))
              (elems arr))))

(check-eq "write-array :int16 of an int-array keeps the low 16 bits"
          (do (ffi/write-array buf :int16 (int-array [65537 -65537 98304]))
              (vec (ffi/read-array buf :int16 3)))
          [1 -1 -32768])
(check-eq "write-array :int32 of a long-array keeps the low 32 bits"
          (do (ffi/write-array buf :int32 (long-array [4294967297 -4294967297]))
              (vec (ffi/read-array buf :int32 2)))
          [1 -1])
(check-eq "write-array :int64 of fixnums round-trips"
          (do (ffi/write-array buf :int64 (long-array [1152921504606846975 -1152921504606846976 -1]))
              (vec (ffi/read-array buf :int64 3)))
          [1152921504606846975 -1152921504606846976 -1])
(check-eq "write-array :float of a double-array rounds to single"
          (do (ffi/write-array buf :float (double-array [0.1]))
              (aget (ffi/read-array buf :float 1) 0))
          (float 0.1))
(check-eq "write-array :double of a float-array widens"
          (do (ffi/write-array buf :double (float-array [0.5]))
              (vec (ffi/read-array buf :double 1)))
          [0.5])
(check-eq "write-array of an empty typed array writes nothing"
          (ffi/write-array buf :double (double-array 0)) 0)
(check-eq "write-array of 9000 doubles round-trips"
          (let [arr (double-array (map #(* 0.25 %) (range 9000)))]
            (ffi/write-array buf :double arr)
            (= (vec arr) (vec (ffi/read-array buf :double 9000))))
          true)
;; what the block encode does not take still goes through the element loop
(check-eq "write-array of a vector still writes"
          (do (ffi/write-array buf :int32 [7 8 9]) (vec (ffi/read-array buf :int32 3)))
          [7 8 9])
(check-eq "write-array of a long-array holding a bignum still writes"
          (let [arr (long-array [1 2])]
            (aset arr 0 Long/MAX_VALUE)
            (ffi/write-array buf :int64 arr)
            (vec (ffi/read-array buf :int64 2)))
          [Long/MAX_VALUE 2])

(ffi/free buf)

;; --- chunk boundaries ------------------------------------------------------
;; The copy moves 64KB at a time — 8192 eight-byte, 16384 four-byte or 32768
;; two-byte elements — so these sizes end mid-chunk after crossing several.
(def big (ffi/alloc (* 8 50000)))
(doseq [[t n] [[:double 20001] [:int64 20001] [:float 40001] [:int32 40001] [:int16 70001]]
        off [0 6]]
  (let [[ctor element width] (carriers t)]
    (dotimes [i n]
      (ffi/write big element (if (#{:double :float} t) (- (* 0.5 i) 100.0) (- (rem (* 7 i) 30000) 15000))
                 (+ off (* i width))))
    (let [want (loop-read big t n off)]
      (check-eq (str "read-array " t " of " n " at offset " off " crosses chunks intact")
                (= (vec (ffi/read-array big t n off)) (vec want)) true)
      (let [src (ctor (map #(if (#{:double :float} t) (* -0.25 %) (- (rem % 20000) 10000)) (range n)))]
        (ffi/write-array big t src off)
        (check-eq (str "write-array " t " of " n " at offset " off " crosses chunks intact")
                  (= (vec (loop-read big t n off)) (vec src)) true)))))

;; A value past the fixnum range in a LATER chunk widens the array there, and
;; every element after it, in that chunk and the next, still lands.
(dotimes [i 20001] (ffi/write big :int64 i (* 8 i)))
(ffi/write big :int64 Long/MIN_VALUE (* 8 10000))
(let [a (ffi/read-array big :int64 20001)]
  (check-eq "read-array :int64 widens on a bignum in the second chunk"
            [(aget a 9999) (aget a 10000) (aget a 10001) (aget a 16384) (aget a 20000) (alength a)]
            [9999 Long/MIN_VALUE 10001 16384 20000 20001])
  (check-eq "and every other element is the one written"
            (= (vec (assoc (vec a) 10000 10000)) (vec (range 20001))) true))
(ffi/write big :int64 Long/MAX_VALUE (* 8 9000))
(let [a (ffi/read-array big :int64 9001)]
  (check-eq "read-array :int64 widens a pinned-size array on its last element"
            [(aget a 8999) (aget a 9000) (alength a)] [8999 Long/MAX_VALUE 9001]))
(ffi/free big)

;; --- memory: a large copy costs its array, not a second copy of it --------
;; Chez's own allocation counter, reached through jolt.scheme only to measure.
(require '[jolt.scheme :as scm])
(defn- allocated [f]
  (let [b0 (scm/eval-string "(bytes-allocated)")]
    (f)
    (- (scm/eval-string "(bytes-allocated)") b0)))
(def huge-n 1000000)
(def huge (ffi/alloc (* 8 huge-n)))
(ffi/read-array huge :double 16)   ; warm, so the measure sees only the copy
(check-eq "read-array of 8MB of doubles allocates under 9MB (the array and a chunk)"
          (< (allocated #(ffi/read-array huge :double huge-n)) (* 9 1024 1024)) true)
(let [src (double-array huge-n)]
  (check-eq "write-array of 8MB of doubles allocates under 1MB"
            (< (allocated #(ffi/write-array huge :double src)) (* 1024 1024)) true))
(ffi/free huge)

(if (empty? @failures)
  (do (println "JOLT-FFI-TYPED-ARRAY-TEST OK") (flush) (System/exit 0))
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-FFI-TYPED-ARRAY-TEST FAILED:" (count @failures))
      (flush)
      (System/exit 1)))
