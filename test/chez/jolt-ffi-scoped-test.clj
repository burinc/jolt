(ns jolt-ffi-scoped-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))
(defn rejects? [f]
  (try (f) false (catch Throwable _ true)))

(def layout (ffi/layout [:struct [[:value :int32] [:tag :uint8]]]))

(check "with-alloc returns body value"
       (= :answer (ffi/with-alloc [p 8] (ffi/write p :uint64 0 42) :answer)))
(check "with-out sizes a scalar"
       (= -32768 (ffi/with-out [p :int16]
                    (ffi/write p :int16 0 -32768)
                    (ffi/read p :int16))))
(check "with-layout sizes a layout"
       (= [123 250]
          (ffi/with-layout [p layout]
            (ffi/write-field p layout :value 123)
            (ffi/write-field p layout :tag 250)
            [(ffi/read-field p layout :value)
             (ffi/read-field p layout :tag)])))
(check "with-c-string roundtrip"
       (= "héllo" (ffi/with-c-string [p "héllo"] (ffi/ptr->string p))))
(check "with-c-string returns body value"
       (= 17 (ffi/with-c-string [p "ignored"] 17)))
(check "with-c-string-array builds pointers"
       (= ["alpha" "βeta" ""]
          (ffi/with-c-string-array [p 3] ["alpha" "βeta" ""]
            (mapv (fn [index]
                    (ffi/ptr->string
                     (ffi/read p :pointer (* index (ffi/sizeof :pointer)))))
                  (range 3)))))
(check "with-c-string-array evaluates values once"
       (= 1 (let [calls (atom 0)]
              (ffi/with-c-string-array [p 1]
                (do (swap! calls inc) ["one"])
                @calls))))
(check "with-c-string-array count mismatch rejects"
       (rejects? #(ffi/with-c-string-array [p 2] ["one"] p)))
(check "body exception escapes"
       (rejects? #(ffi/with-layout [p layout] (throw (ex-info "boom" {})))))
(check "helper allocation frees once on return"
       (= 1 (let [real-free ffi/free frees (atom 0)]
              (with-redefs [ffi/free (fn [p] (swap! frees inc) (real-free p))]
                (ffi/with-alloc [p 1] :ok))
              @frees)))
(check "helper allocation frees once on exception"
       (= 1 (let [real-free ffi/free frees (atom 0)]
              (with-redefs [ffi/free (fn [p] (swap! frees inc) (real-free p))]
                (rejects? #(ffi/with-alloc [p 1] (throw (ex-info "boom" {})))))
              @frees)))
(check "partial C string array frees members and array"
       (= 2 (let [real-free ffi/free real-string->ptr ffi/string->ptr
                  frees (atom 0) calls (atom 0)]
              (with-redefs
                [ffi/free (fn [p] (swap! frees inc) (real-free p))
                 ffi/string->ptr
                 (fn [value]
                   (if (= 2 (swap! calls inc))
                     (throw (ex-info "conversion failed" {}))
                     (real-string->ptr value)))]
                (rejects? #(ffi/with-c-string-array [p 2] ["one" "two"] p)))
              @frees)))

(if (empty? @failures)
  (do (println "JOLT-FFI-SCOPED-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
