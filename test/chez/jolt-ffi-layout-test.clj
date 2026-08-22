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

(check "flat size" (= (flat-size) (ffi/layout-size date-layout)))
(check "flat alignment" (= (flat-align) (ffi/layout-alignment date-layout)))
(check "keyword path" (= (flat-month) (ffi/field-offset date-layout :month)))
(check "padded size" (= (padded-size) (ffi/layout-size padded-layout)))
(check "padded alignment" (= (padded-align) (ffi/layout-alignment padded-layout)))
(check "padded field offset" (= (padded-value) (ffi/field-offset padded-layout :value)))
(check "nested struct offset" (= (nested-date) (ffi/field-offset nested-layout [:date])))
(check "nested scalar offset" (= (nested-year) (ffi/field-offset nested-layout [:date :year])))
(check "descriptor data" (= [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]
                            (:descriptor date-layout)))

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

(check "unknown path rejects"
       (rejects? #(ffi/field-offset date-layout :missing)))
(check "struct read rejects"
       (rejects? #(ffi/read-field ffi/null nested-layout :date)))
(check "invalid layout rejects"
       (rejects? #(ffi/layout-size {})))

(if (empty? @failures)
  (do (println "JOLT-FFI-LAYOUT-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
