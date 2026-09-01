(ns jolt-ffi-layout-test)

(require '[jolt.ffi :as ffi])

(def helper (System/getenv "JOLT_FFI_LAYOUT_HELPER"))
(when-not helper
  (throw (ex-info "JOLT_FFI_LAYOUT_HELPER is required" {})))
(ffi/load-library helper)

(ffi/defcfn flat-size "jolt_layout_flat_size" [] :size_t)
(ffi/defcfn flat-align "jolt_layout_flat_align" [] :size_t)
(ffi/defcfn flat-month "jolt_layout_flat_month" [] :size_t)
(ffi/defcfn padded-size "jolt_layout_padded_size" [] :size_t)
(ffi/defcfn padded-align "jolt_layout_padded_align" [] :size_t)
(ffi/defcfn padded-value "jolt_layout_padded_value" [] :size_t)
(ffi/defcfn nested-date "jolt_layout_nested_date" [] :size_t)
(ffi/defcfn nested-year "jolt_layout_nested_year" [] :size_t)
(ffi/defcfn arrays-size "jolt_layout_arrays_size" [] :size_t)
(ffi/defcfn arrays-align "jolt_layout_arrays_align" [] :size_t)
(ffi/defcfn arrays-params "jolt_layout_arrays_params" [] :size_t)
(ffi/defcfn arrays-params-3 "jolt_layout_arrays_params_3" [] :size_t)
(ffi/defcfn arrays-name-4 "jolt_layout_arrays_name_4" [] :size_t)
(ffi/defcfn arrays-dates-1-year "jolt_layout_arrays_dates_1_year" [] :size_t)
(ffi/defcfn arrays-matrix-1-2 "jolt_layout_arrays_matrix_1_2" [] :size_t)
(ffi/defcfn data-size "jolt_layout_data_size" [] :size_t)
(ffi/defcfn data-align "jolt_layout_data_align" [] :size_t)
(ffi/defcfn msg-size "jolt_layout_msg_size" [] :size_t)
(ffi/defcfn msg-align "jolt_layout_msg_align" [] :size_t)
(ffi/defcfn msg-easy "jolt_layout_msg_easy" [] :size_t)
(ffi/defcfn msg-data "jolt_layout_msg_data" [] :size_t)
(ffi/defcfn msg-data-result "jolt_layout_msg_data_result" [] :size_t)
(ffi/defcfn union-tail-size "jolt_layout_union_tail_size" [] :size_t)
(ffi/defcfn union-tail-align "jolt_layout_union_tail_align" [] :size_t)
(ffi/defcfn union-tail-data "jolt_layout_union_tail_data" [] :size_t)
(ffi/defcfn union-tail-tail "jolt_layout_union_tail_tail" [] :size_t)

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))
(defn rejects? [f]
  (try (f) false (catch Throwable _ true)))

(def date-layout
  (ffi/layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))
(def padded-layout
  (ffi/layout [:struct [[:tag :uint8] [:value :double] [:tail :uint16]]]))
(def nested-layout
  (ffi/layout [:struct [[:tag :uint8]
                       [:date [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]
                       [:tail :uint16]]]))
(def arrays-layout
  (ffi/layout [:struct [[:tag :uint8]
                        [:params [:array :float 4]]
                        [:name [:array :char 5]]
                        [:dates [:array [:struct [[:year :int32]
                                                    [:month :uint8]
                                                    [:day :uint8]]] 2]]
                        [:matrix [:array [:array :uint16 3] 2]]
                        [:tail :uint16]]]))
(def huge-array-layout
  (ffi/layout [:struct [[:prefix :uint8]
                        [:payload [:array :uint8 1000000]]
                        [:suffix :uint8]]]))
(def huge-matrix-layout
  (ffi/layout [:struct [[:matrix [:array [:array :uint8 1000] 1000]]]]))

(check "flat size" (= (flat-size) (ffi/layout-size date-layout)))
(check "flat alignment" (= (flat-align) (ffi/layout-alignment date-layout)))
(check "keyword path" (= (flat-month) (ffi/field-offset date-layout :month)))
(check "padded size" (= (padded-size) (ffi/layout-size padded-layout)))
(check "padded alignment" (= (padded-align) (ffi/layout-alignment padded-layout)))
(check "padded field offset" (= (padded-value) (ffi/field-offset padded-layout :value)))
(check "nested struct offset" (= (nested-date) (ffi/field-offset nested-layout [:date])))
(check "nested scalar offset" (= (nested-year) (ffi/field-offset nested-layout [:date :year])))
(check "arrays size" (= (arrays-size) (ffi/layout-size arrays-layout)))
(check "arrays alignment" (= (arrays-align) (ffi/layout-alignment arrays-layout)))
(check "array container offset" (= (arrays-params) (ffi/field-offset arrays-layout :params)))
(check "array scalar offset" (= (arrays-params-3) (ffi/field-offset arrays-layout [:params 3])))
(check "char array element offset" (= (arrays-name-4) (ffi/field-offset arrays-layout [:name 4])))
(check "struct array field offset"
       (= (arrays-dates-1-year) (ffi/field-offset arrays-layout [:dates 1 :year])))
(check "nested array offset"
       (= (arrays-matrix-1-2) (ffi/field-offset arrays-layout [:matrix 1 2])))
(check "descriptor data" (= [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]
                            (:descriptor date-layout)))
(check "million-element array metadata stays compact"
       (= [4 1 1]
          [(count (:jolt.ffi/offsets huge-array-layout))
           (count (:jolt.ffi/array-counts huge-array-layout))
           (count (:jolt.ffi/array-strides huge-array-layout))]))
(check "million-element array resolves its final element arithmetically"
       (= [1000002 1000000 1000001]
          [(ffi/layout-size huge-array-layout)
           (ffi/field-offset huge-array-layout [:payload 999999])
           (ffi/field-offset huge-array-layout :suffix)]))
(check "million-element nested array metadata stays shape-sized"
       (= [3 2 2 1000000 999999]
          [(count (:jolt.ffi/offsets huge-matrix-layout))
           (count (:jolt.ffi/array-counts huge-matrix-layout))
           (count (:jolt.ffi/array-strides huge-matrix-layout))
           (ffi/layout-size huge-matrix-layout)
           (ffi/field-offset huge-matrix-layout [:matrix 999 999])]))

(let [p (ffi/alloc (ffi/layout-size nested-layout))]
  (try
    (ffi/write-field p nested-layout [:date :year] -2147483648)
    (ffi/write-field p nested-layout [:date :month] 255)
    (ffi/write-field p nested-layout :tail 65535)
    (check "signed field roundtrip"
           (= -2147483648 (ffi/read-field p nested-layout [:date :year])))
    (check "byte field roundtrip"
           (= 255 (ffi/read-field p nested-layout [:date :month])))
    (check "unsigned field roundtrip"
           (= 65535 (ffi/read-field p nested-layout :tail)))
    (finally (ffi/free p))))

(ffi/with-layout [p arrays-layout]
  (ffi/write-field p arrays-layout [:params 3] 3.5)
  (ffi/write-field p arrays-layout [:name 4] \A)
  (ffi/write-field p arrays-layout [:dates 1 :year] -123456789)
  (ffi/write-field p arrays-layout [:matrix 1 2] 65535)
  (check "public array element roundtrip"
         (= [3.5 \A -123456789 65535]
            [(ffi/read-field p arrays-layout [:params 3])
             (ffi/read-field p arrays-layout [:name 4])
             (ffi/read-field p arrays-layout [:dates 1 :year])
             (ffi/read-field p arrays-layout [:matrix 1 2])])))

;; --- unions ------------------------------------------------------------------
;; A union is as large as its largest member and aligned to its strictest, and
;; every member starts at the union's own offset. Checked against the C witness
;; rather than against Chez, since the point is the platform ABI.
(def data-union (ffi/layout [:union [[:whatever :pointer] [:result :int32] [:wide :double]]]))
(def msg-layout
  (ffi/layout [:struct [[:msg :int32]
                        [:easy :pointer]
                        [:data [:union [[:whatever :pointer] [:result :int32] [:wide :double]]]]]]))
(def union-tail-layout
  (ffi/layout [:struct [[:tag :uint8]
                        [:data [:union [[:whatever :pointer] [:result :int32] [:wide :double]]]]
                        [:tail :uint16]]]))

(check "bare union size" (= (data-size) (ffi/layout-size data-union)))
(check "bare union alignment" (= (data-align) (ffi/layout-alignment data-union)))
(check "union members all start at 0"
       (= [0 0 0] [(ffi/field-offset data-union :whatever)
                   (ffi/field-offset data-union :result)
                   (ffi/field-offset data-union :wide)]))
(check "struct holding a union: size" (= (msg-size) (ffi/layout-size msg-layout)))
(check "struct holding a union: alignment" (= (msg-align) (ffi/layout-alignment msg-layout)))
(check "field before the union" (= (msg-easy) (ffi/field-offset msg-layout :easy)))
(check "the union member's own offset"
       (= (msg-data) (ffi/field-offset msg-layout [:data :whatever])))
(check "a member inside the union" (= (msg-data-result) (ffi/field-offset msg-layout [:data :result])))
(check "a union pushes the field after it into place"
       (and (= (union-tail-size) (ffi/layout-size union-tail-layout))
            (= (union-tail-align) (ffi/layout-alignment union-tail-layout))
            (= (union-tail-data) (ffi/field-offset union-tail-layout [:data :result]))
            (= (union-tail-tail) (ffi/field-offset union-tail-layout :tail))))

;; A union carries no tag, so `read` answers a POINTER to its bytes and the
;; caller reads the member it knows applies; `write` names the member.
(def msg-kind (ffi/place msg-layout :msg))
(def msg-result (ffi/place msg-layout [:data :result]))
(check "write names the member, read answers the whole struct"
       (ffi/with-layout [p msg-layout]
         (ffi/write p msg-layout {:msg 1 :easy ffi/null :data [:result 42]})
         (let [m (ffi/read p msg-layout)]
           (and (= 1 (:msg m))
                ;; the union reads as a pointer AT the union's offset
                (ffi/pointer? (:data m))
                (= (+ p (msg-data)) (:data m))
                ;; and through that pointer, with a type of the caller's own
                (= 42 (ffi/read (:data m) :int32))))))
(check "a place reaches a union member by path"
       (ffi/with-layout [p msg-layout]
         (ffi/write p msg-layout {:msg 7 :easy ffi/null :data [:result 9]})
         (and (= 7 (ffi/read p msg-kind)) (= 9 (ffi/read p msg-result)))))
(check "writing through a member place lands in the union"
       (ffi/with-layout [p msg-layout]
         (ffi/write p msg-layout {:msg 0 :easy ffi/null :data [:result 0]})
         (ffi/write p msg-result 12345)
         (= 12345 (ffi/read-field p msg-layout [:data :result]))))
(check "members overlap: writing one is visible through another"
       (ffi/with-layout [p data-union]
         (ffi/write p data-union [:result -1])
         (= 0xffffffff (bit-and (ffi/read-field p data-union :whatever) 0xffffffff))))
(check "read-field and write-field reach a union member"
       (ffi/with-layout [p msg-layout]
         (ffi/write-field p msg-layout [:data :result] 77)
         (= 77 (ffi/read-field p msg-layout [:data :result]))))
(check "a union value must be a member pair"
       (rejects? #(ffi/with-layout [p data-union] (ffi/write p data-union {:result 1}))))
(check "a union value naming an unknown member rejects"
       (rejects? #(ffi/with-layout [p data-union] (ffi/write p data-union [:nope 1]))))
(check "a union is not passed by value"
       (rejects? #(eval '(jolt.ffi/__cfn "f" [[:by-value [:union [[:a :int]]]]] :void))))
(check "nor inside a by-value struct"
       (rejects? #(eval '(jolt.ffi/__cfn "f" [[:by-value [:struct [[:a [:union [[:b :int]]]]]]]] :void))))
(check "an empty union rejects" (rejects? #(eval '(jolt.ffi/__layout [:union []]))))
(check "duplicate union member names reject"
       (rejects? #(eval '(jolt.ffi/__layout [:union [[:a :int] [:a :int]]]))))

(check "unknown path rejects"
       (rejects? #(ffi/field-offset date-layout :missing)))
(check "struct read rejects"
       (rejects? #(ffi/read-field ffi/null nested-layout :date)))
(check "invalid layout rejects"
       (rejects? #(ffi/layout-size {})))
(check "array container read rejects"
       (rejects? #(ffi/read-field ffi/null arrays-layout :params)))
(check "negative array index rejects"
       (rejects? #(ffi/field-offset arrays-layout [:params -1])))
(check "array upper-bound index rejects"
       (rejects? #(ffi/field-offset arrays-layout [:params 4])))
(check "keyword in array position rejects"
       (rejects? #(ffi/field-offset arrays-layout [:params :missing])))
(check "index after scalar rejects"
       (rejects? #(ffi/field-offset arrays-layout [:tag 0])))
(check "path starting with array index rejects"
       (rejects? #(ffi/field-offset arrays-layout [0])))

(if (empty? @failures)
  (do (println "JOLT-FFI-LAYOUT-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
