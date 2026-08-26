(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (n source) (jnum->exact (ev source)))
(define (rejects? source) (guard (e (#t #t)) (ev source) #f))

(define helper (getenv "JOLT_FFI_LAYOUT_HELPER"))
(unless helper (error #f "JOLT_FFI_LAYOUT_HELPER is required"))
(sa-load-shared-object helper)
(define (c name) ((foreign-procedure name () size_t)))
(ev "(defn layout-offset [layout path] (loop [parts path compact [] delta 0] (if (empty? parts) (+ delta (get (:jolt.ffi/offsets layout) compact)) (let [part (first parts)] (if (integer? part) (recur (rest parts) (conj compact :jolt.ffi/index) (+ delta (* part (get (:jolt.ffi/array-strides layout) compact)))) (recur (rest parts) (conj compact part) delta))))))")

(ev "(def flat (jolt.ffi/__layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))")
(ev "(def padded (jolt.ffi/__layout [:struct [[:tag :uint8] [:value :double] [:tail :uint16]]]))")
(ev "(def nested (jolt.ffi/__layout [:struct [[:tag :uint8] [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]] [:tail :uint16]]]))")
(ev "(def arrays (jolt.ffi/__layout [:struct [[:tag :uint8] [:params [:array 4 :float]] [:name [:array 5 :char]] [:dates [:array 2 [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]] [:matrix [:array 2 [:array 3 :uint16]]] [:tail :uint16]]]))")

(for-each
 (lambda (row) (ok (car row) (= (c (cadr row)) (n (caddr row)))))
 '(("flat sizeof" "jolt_layout_flat_size" "(:size flat)")
   ("flat alignof" "jolt_layout_flat_align" "(:alignment flat)")
   ("flat year" "jolt_layout_flat_year" "(layout-offset flat [:year])")
   ("flat month" "jolt_layout_flat_month" "(layout-offset flat [:month])")
   ("flat day" "jolt_layout_flat_day" "(layout-offset flat [:day])")
   ("padded sizeof" "jolt_layout_padded_size" "(:size padded)")
   ("padded alignof" "jolt_layout_padded_align" "(:alignment padded)")
   ("padded value" "jolt_layout_padded_value" "(layout-offset padded [:value])")
   ("padded tail" "jolt_layout_padded_tail" "(layout-offset padded [:tail])")
   ("nested sizeof" "jolt_layout_nested_size" "(:size nested)")
   ("nested alignof" "jolt_layout_nested_align" "(:alignment nested)")
   ("nested struct" "jolt_layout_nested_date" "(layout-offset nested [:date])")
   ("nested year" "jolt_layout_nested_year" "(layout-offset nested [:date :year])")
   ("nested month" "jolt_layout_nested_month" "(layout-offset nested [:date :month])")
   ("nested tail" "jolt_layout_nested_tail" "(layout-offset nested [:tail])")
   ("arrays sizeof" "jolt_layout_arrays_size" "(:size arrays)")
   ("arrays alignof" "jolt_layout_arrays_align" "(:alignment arrays)")
   ("array container" "jolt_layout_arrays_params" "(layout-offset arrays [:params])")
   ("array scalar element" "jolt_layout_arrays_params_3" "(layout-offset arrays [:params 3])")
   ("char array element" "jolt_layout_arrays_name_4" "(layout-offset arrays [:name 4])")
   ("struct array element" "jolt_layout_arrays_dates_1" "(layout-offset arrays [:dates 1])")
   ("struct array nested field" "jolt_layout_arrays_dates_1_year" "(layout-offset arrays [:dates 1 :year])")
   ("nested array scalar" "jolt_layout_arrays_matrix_1_2" "(layout-offset arrays [:matrix 1 2])")
   ("arrays tail" "jolt_layout_arrays_tail" "(layout-offset arrays [:tail])")))

(ok "descriptor retained as data"
    (jolt-truthy? (ev "(= (:descriptor flat) [:struct [[:year :int32] [:month :uint8] [:day :uint8]]])")))
(ok "field memory roundtrip"
    (jolt-truthy?
     (ev "(let [p (jolt.ffi/alloc (:size nested))]
            (try
              (jolt.ffi/write p :int32 (layout-offset nested [:date :year]) -2147483648)
              (jolt.ffi/write p :uint16 (layout-offset nested [:tail]) 65535)
              (= [-2147483648 65535]
                 [(jolt.ffi/read p :int32 (layout-offset nested [:date :year]))
                  (jolt.ffi/read p :uint16 (layout-offset nested [:tail]))])
              (finally (jolt.ffi/free p))))")))
(ok "array descriptor retained as data"
    (jolt-truthy?
     (ev "(= (:descriptor arrays) [:struct [[:tag :uint8] [:params [:array 4 :float]] [:name [:array 5 :char]] [:dates [:array 2 [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]] [:matrix [:array 2 [:array 3 :uint16]]] [:tail :uint16]]])")))
(ok "array element memory roundtrip"
    (jolt-truthy?
     (ev "(let [p (jolt.ffi/alloc (:size arrays))]
            (try
              (jolt.ffi/write p :float (layout-offset arrays [:params 3]) 3.5)
              (jolt.ffi/write p :int32 (layout-offset arrays [:dates 1 :year]) -123456789)
              (jolt.ffi/write p :uint16 (layout-offset arrays [:matrix 1 2]) 65535)
              (= [3.5 -123456789 65535]
                 [(jolt.ffi/read p :float (layout-offset arrays [:params 3]))
                  (jolt.ffi/read p :int32 (layout-offset arrays [:dates 1 :year]))
                  (jolt.ffi/read p :uint16 (layout-offset arrays [:matrix 1 2]))])
              (finally (jolt.ffi/free p))))")))


;; The layout lowering emits bare Chez ftype heads into the same scope a jolt
;; local lives in, so munge-name must rename a local that collides. Without
;; that, a local named ftype-pointer-address answered ITS value as the layout's
;; :alignment -- silently wrong data -- and the other four broke the compile,
;; which is why each row is guarded: an unrenamed head must report FAIL here,
;; not abort the gate before the remaining rows run.
(define (evb source) (guard (e (#t #f)) (jolt-truthy? (ev source))))
(ev "(def unshadowed (jolt.ffi/__layout [:struct [[:tag :uint8] [:value :double] [:items [:array 3 :uint16]]]]))")
(for-each
 (lambda (name)
   (ok (string-append "a local named " name " does not shadow the layout lowering")
       (evb (string-append
             "(let [" name " (fn [& _] :shadowed)]
                (let [l (jolt.ffi/__layout [:struct [[:tag :uint8] [:value :double] [:items [:array 3 :uint16]]]])]
                  (= [(:size unshadowed) (:alignment unshadowed)
                      (get (:jolt.ffi/offsets unshadowed) [:value])
                      (get (:jolt.ffi/array-strides unshadowed) [:items])]
                     [(:size l) (:alignment l)
                      (get (:jolt.ffi/offsets l) [:value])
                      (get (:jolt.ffi/array-strides l) [:items])])))"))))
 '("define-ftype" "make-ftype-pointer" "ftype-sizeof" "ftype-&ref"
   "ftype-pointer-address"))

(for-each
 (lambda (row) (ok (car row) (rejects? (cdr row))))
 '(("empty struct rejects" . "(jolt.ffi/__layout [:struct []])")
   ("duplicate field rejects" . "(jolt.ffi/__layout [:struct [[:x :int] [:x :uint]]])")
   ("qualified field rejects" . "(jolt.ffi/__layout [:struct [[:x/y :int]]])")
   ("symbol field rejects" . "(jolt.ffi/__layout [:struct [[x :int]]])")
   ("void rejects" . "(jolt.ffi/__layout [:struct [[:x :void]]])")
   ("string rejects" . "(jolt.ffi/__layout [:struct [[:x :string]]])")
   ("zero array rejects" . "(jolt.ffi/__layout [:struct [[:x [:array 0 :int]]]])")
   ("negative array rejects" . "(jolt.ffi/__layout [:struct [[:x [:array -1 :int]]]])")
   ("fractional array rejects" . "(jolt.ffi/__layout [:struct [[:x [:array 1.5 :int]]]])")
   ("malformed array rejects" . "(jolt.ffi/__layout [:struct [[:x [:array 4]]]])")
   ("array void rejects" . "(jolt.ffi/__layout [:struct [[:x [:array 4 :void]]]])")
   ("nonliteral rejects" . "(let [d [:struct [[:x :int]]]] (jolt.ffi/__layout d))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
