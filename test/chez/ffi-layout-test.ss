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

(ev "(def flat (jolt.ffi/__layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))")
(ev "(def padded (jolt.ffi/__layout [:struct [[:tag :uint8] [:value :double] [:tail :uint16]]]))")
(ev "(def nested (jolt.ffi/__layout [:struct [[:tag :uint8] [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]] [:tail :uint16]]]))")

(for-each
 (lambda (row) (ok (car row) (= (c (cadr row)) (n (caddr row)))))
 '(("flat sizeof" "jolt_layout_flat_size" "(:size flat)")
   ("flat alignof" "jolt_layout_flat_align" "(:alignment flat)")
   ("flat year" "jolt_layout_flat_year" "(get (:jolt.ffi/offsets flat) [:year])")
   ("flat month" "jolt_layout_flat_month" "(get (:jolt.ffi/offsets flat) [:month])")
   ("flat day" "jolt_layout_flat_day" "(get (:jolt.ffi/offsets flat) [:day])")
   ("padded sizeof" "jolt_layout_padded_size" "(:size padded)")
   ("padded alignof" "jolt_layout_padded_align" "(:alignment padded)")
   ("padded value" "jolt_layout_padded_value" "(get (:jolt.ffi/offsets padded) [:value])")
   ("padded tail" "jolt_layout_padded_tail" "(get (:jolt.ffi/offsets padded) [:tail])")
   ("nested sizeof" "jolt_layout_nested_size" "(:size nested)")
   ("nested alignof" "jolt_layout_nested_align" "(:alignment nested)")
   ("nested struct" "jolt_layout_nested_date" "(get (:jolt.ffi/offsets nested) [:date])")
   ("nested year" "jolt_layout_nested_year" "(get (:jolt.ffi/offsets nested) [:date :year])")
   ("nested month" "jolt_layout_nested_month" "(get (:jolt.ffi/offsets nested) [:date :month])")
   ("nested tail" "jolt_layout_nested_tail" "(get (:jolt.ffi/offsets nested) [:tail])")))

(ok "descriptor retained as data"
    (jolt-truthy? (ev "(= (:descriptor flat) [:struct [[:year :int32] [:month :uint8] [:day :uint8]]])")))
(ok "field memory roundtrip"
    (jolt-truthy?
     (ev "(let [p (jolt.ffi/alloc (:size nested))]
            (try
              (jolt.ffi/write p :int32 (get (:jolt.ffi/offsets nested) [:date :year]) -2147483648)
              (jolt.ffi/write p :uint16 (get (:jolt.ffi/offsets nested) [:tail]) 65535)
              (= [-2147483648 65535]
                 [(jolt.ffi/read p :int32 (get (:jolt.ffi/offsets nested) [:date :year]))
                  (jolt.ffi/read p :uint16 (get (:jolt.ffi/offsets nested) [:tail]))])
              (finally (jolt.ffi/free p))))")))

(for-each
 (lambda (row) (ok (car row) (rejects? (cdr row))))
 '(("empty struct rejects" . "(jolt.ffi/__layout [:struct []])")
   ("duplicate field rejects" . "(jolt.ffi/__layout [:struct [[:x :int] [:x :uint]]])")
   ("qualified field rejects" . "(jolt.ffi/__layout [:struct [[:x/y :int]]])")
   ("symbol field rejects" . "(jolt.ffi/__layout [:struct [[x :int]]])")
   ("void rejects" . "(jolt.ffi/__layout [:struct [[:x :void]]])")
   ("string rejects" . "(jolt.ffi/__layout [:struct [[:x :string]]])")
   ("array rejects" . "(jolt.ffi/__layout [:struct [[:x [:array 4 :int]]]])")
   ("nonliteral rejects" . "(let [d [:struct [[:x :int]]]] (jolt.ffi/__layout d))")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
