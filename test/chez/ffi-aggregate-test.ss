(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/ffi.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a~n" name)))
(define (ev source) (jolt-compile-eval source "user"))
(define (rejects? source) (guard (e (#t #t)) (ev source) #f))

(define helper (getenv "JOLT_FFI_AGGREGATE_HELPER"))
(unless helper (error #f "JOLT_FFI_AGGREGATE_HELPER is required"))
(sa-load-shared-object helper)
(ev "(jolt.ffi/load-library)")

(define date "[:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]")
(define nested "[:by-value [:struct [[:tag :uint8] [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]] [:tail :uint16]]]]")
(define large "[:by-value [:struct [[:a :uint64] [:b :uint64] [:c :uint64]]]]")

(ev (string-append "(def c-date-score (jolt.ffi/__cfn \"jolt_agg_date_score\" [" date "] :int64))"))
(ev (string-append "(def c-date-blocking (jolt.ffi/__cfn \"jolt_agg_date_score\" [" date "] :int64 :blocking))"))
(ev (string-append "(def c-two-dates (jolt.ffi/__cfn \"jolt_agg_two_dates\" [" date " " date " :int32] :int64))"))
(ev (string-append "(def c-nested-score (jolt.ffi/__cfn \"jolt_agg_nested_score\" [" nested "] :uint64))"))
(ev (string-append "(def c-large-score (jolt.ffi/__cfn \"jolt_agg_large_score\" [" large "] :uint64))"))
(ev (string-append "(def c-date-varargs (jolt.ffi/__cfn \"jolt_agg_date_plus_varargs\" [" date " :int :varargs :int :int] :int64))"))
(ev (string-append "(def c-make-date (jolt.ffi/__cfn \"jolt_agg_make_date\" [:int32 :uint8 :uint8] " date "))"))
(ev (string-append "(def c-make-date-blocking (jolt.ffi/__cfn \"jolt_agg_make_date\" [:int32 :uint8 :uint8] " date " :blocking))"))
(ev (string-append "(def c-make-nested (jolt.ffi/__cfn \"jolt_agg_make_nested\" [:uint8 " date " :uint16] " nested "))"))
(ev (string-append "(def c-add-large (jolt.ffi/__cfn \"jolt_agg_add_large\" [" large " " large "] " large "))"))

(ev "(def date-layout (jolt.ffi/__layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))")
(ev "(def nested-layout (jolt.ffi/__layout [:struct [[:tag :uint8] [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]] [:tail :uint16]]]))")
(ev "(def large-layout (jolt.ffi/__layout [:struct [[:a :uint64] [:b :uint64] [:c :uint64]]]))")
(ev "(defn layout-offset [layout path] (get (:jolt.ffi/offsets layout) path))")
(ev "(defn put-date [p year month day] (jolt.ffi/write p :int32 (layout-offset date-layout [:year]) year) (jolt.ffi/write p :uint8 (layout-offset date-layout [:month]) month) (jolt.ffi/write p :uint8 (layout-offset date-layout [:day]) day) p)")
(ev "(defn put-large [p a b c] (jolt.ffi/write p :uint64 (layout-offset large-layout [:a]) a) (jolt.ffi/write p :uint64 (layout-offset large-layout [:b]) b) (jolt.ffi/write p :uint64 (layout-offset large-layout [:c]) c) p)")

(ok "flat argument"
    (= 20260723 (jnum->exact (ev "(let [p (jolt.ffi/alloc (:size date-layout))] (try (put-date p 2026 7 23) (c-date-score p) (finally (jolt.ffi/free p))))"))))
(ok "blocking flat argument"
    (= 20260723 (jnum->exact (ev "(let [p (jolt.ffi/alloc (:size date-layout))] (try (put-date p 2026 7 23) (c-date-blocking p) (finally (jolt.ffi/free p))))"))))
(ok "multiple aggregate arguments"
    (= 40461237 (jnum->exact (ev "(let [a (jolt.ffi/alloc (:size date-layout)) b (jolt.ffi/alloc (:size date-layout))] (try (put-date a 2026 7 23) (put-date b 2020 5 6) (c-two-dates a b 8) (finally (jolt.ffi/free a) (jolt.ffi/free b))))"))))
(ok "nested argument"
    (= 20261531 (jnum->exact (ev "(let [p (jolt.ffi/alloc (:size nested-layout))] (try (jolt.ffi/write p :uint8 (layout-offset nested-layout [:tag]) 3) (put-date (+ p (layout-offset nested-layout [:date])) 2026 7 23) (jolt.ffi/write p :uint16 (layout-offset nested-layout [:tail]) 805) (c-nested-score p) (finally (jolt.ffi/free p))))"))))
(ok "large argument"
    (= 321 (jnum->exact (ev "(let [p (jolt.ffi/alloc (:size large-layout))] (try (put-large p 1 2 3) (c-large-score p) (finally (jolt.ffi/free p))))"))))
(ok "aggregate before varargs"
    (= 20260734 (jnum->exact (ev "(let [p (jolt.ffi/alloc (:size date-layout))] (try (put-date p 2026 7 23) (c-date-varargs p 2 5 6) (finally (jolt.ffi/free p))))"))))

(ok "flat return writes destination and returns it"
    (jolt-truthy? (ev "(let [p (jolt.ffi/alloc (:size date-layout))] (try (= [p 1999 12 31] [(c-make-date p 1999 12 31) (jolt.ffi/read p :int32 (layout-offset date-layout [:year])) (jolt.ffi/read p :uint8 (layout-offset date-layout [:month])) (jolt.ffi/read p :uint8 (layout-offset date-layout [:day]))]) (finally (jolt.ffi/free p))))")))
(ok "blocking flat return writes destination"
    (jolt-truthy? (ev "(let [p (jolt.ffi/alloc (:size date-layout))] (try (= [p -2147483648 255 254] [(c-make-date-blocking p -2147483648 255 254) (jolt.ffi/read p :int32 (layout-offset date-layout [:year])) (jolt.ffi/read p :uint8 (layout-offset date-layout [:month])) (jolt.ffi/read p :uint8 (layout-offset date-layout [:day]))]) (finally (jolt.ffi/free p))))")))
(ok "nested return"
    (jolt-truthy? (ev "(let [d (jolt.ffi/alloc (:size date-layout)) out (jolt.ffi/alloc (:size nested-layout))] (try (put-date d -123456789 250 251) (c-make-nested out 252 d 65535) (= [252 -123456789 250 251 65535] [(jolt.ffi/read out :uint8 (layout-offset nested-layout [:tag])) (jolt.ffi/read out :int32 (layout-offset nested-layout [:date :year])) (jolt.ffi/read out :uint8 (layout-offset nested-layout [:date :month])) (jolt.ffi/read out :uint8 (layout-offset nested-layout [:date :day])) (jolt.ffi/read out :uint16 (layout-offset nested-layout [:tail]))]) (finally (jolt.ffi/free d) (jolt.ffi/free out))))")))
(ok "large return and multiple arguments"
    (jolt-truthy? (ev "(let [a (jolt.ffi/alloc (:size large-layout)) b (jolt.ffi/alloc (:size large-layout)) out (jolt.ffi/alloc (:size large-layout))] (try (put-large a 10 11 12) (put-large b 20 21 22) (c-add-large out a b) (= [30 32 34] [(jolt.ffi/read out :uint64 (layout-offset large-layout [:a])) (jolt.ffi/read out :uint64 (layout-offset large-layout [:b])) (jolt.ffi/read out :uint64 (layout-offset large-layout [:c]))]) (finally (jolt.ffi/free a) (jolt.ffi/free b) (jolt.ffi/free out))))")))

(ok "null argument rejects before native entry"
    (jolt-truthy? (ev "(try (c-date-score 0) false (catch NullPointerException _ true))")))
(ok "null destination rejects before native entry"
    (jolt-truthy? (ev "(try (c-make-date 0 1 2 3) false (catch NullPointerException _ true))")))
(ok "aggregate variadic argument rejects"
    (rejects? (string-append "(jolt.ffi/__cfn \"x\" [:int :varargs " date "] :int)")))
(ok "aggregate return plus varargs rejects"
    (rejects? (string-append "(jolt.ffi/__cfn \"x\" [:int :varargs :int] " date ")")))
(ok "aggregate callback rejects"
    (rejects? (string-append "(jolt.ffi/__ccallable identity [" date "] :int)")))
(ok "aggregate callback return rejects"
    (rejects? (string-append "(jolt.ffi/__ccallable identity [] " date ")")))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
