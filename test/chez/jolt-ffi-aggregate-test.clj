(ns jolt-ffi-aggregate-test)

(require '[jolt.ffi :as ffi])

(def helper (System/getenv "JOLT_FFI_AGGREGATE_HELPER"))
(when-not helper
  (throw (ex-info "JOLT_FFI_AGGREGATE_HELPER is required" {})))

(def date-layout
  (ffi/layout [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]))

;; The public macros require literal signature data, so keep the descriptor
;; inline rather than referring to date-layout in these declarations. Define
;; the bindings before loading the helper to exercise lazy scoped resolution.
(def date-score
  (ffi/foreign-fn "jolt_agg_date_score"
                  [[:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]]
                  :int64))
(ffi/defcfn date-score-defcfn "jolt_agg_date_score"
  [[:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]]
  :int64)
(def make-date
  (ffi/foreign-fn "jolt_agg_make_date" [:int32 :uint8 :uint8]
                  [:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]))
(def date-plus-varargs
  (ffi/foreign-fn "jolt_agg_date_plus_varargs"
                  [[:by-value [:struct [[:year :int32] [:month :uint8] [:day :uint8]]]]
                   :int :varargs :int :int]
                  :int64))

(ffi/load-library helper)

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))
(defn rejects? [f]
  (try (f) false (catch Throwable _ true)))

(let [input (ffi/alloc (ffi/layout-size date-layout))
      output (ffi/alloc (ffi/layout-size date-layout))]
  (try
    (ffi/write-field input date-layout :year -123456789)
    (ffi/write-field input date-layout :month 250)
    (ffi/write-field input date-layout :day 251)
    (check "public by-value argument"
           (= -1234567864749 (date-score input)))
    (check "public defcfn by-value argument"
           (= -1234567864749 (date-score-defcfn input)))
    (check "public scoped aggregate before varargs"
           (= -1234567864738 (date-plus-varargs input 2 5 6)))
    (check "public by-value return"
           (= [output 2026 7 23]
              [(make-date output 2026 7 23)
               (ffi/read-field output date-layout :year)
               (ffi/read-field output date-layout :month)
               (ffi/read-field output date-layout :day)]))
    (finally (ffi/free input) (ffi/free output))))

(check "public null argument rejects"
       (rejects? #(date-score ffi/null)))
(check "public null destination rejects"
       (rejects? #(make-date ffi/null 2026 7 23)))
(check "public aggregate callback rejects"
       (rejects?
        #(eval '(ffi/foreign-callable identity
                  [[:by-value [:struct [[:year :int32]]]]]
                  :int))))
(check "public scalar callback control"
       (let [pointer (eval '(ffi/foreign-callable identity [:int] :int))]
         (try (pos? pointer) (finally (ffi/free-callable pointer)))))
(check "public aggregate export rejects"
       (rejects?
        #(eval '(ffi/export! "aggregate" identity
                  [[:by-value [:struct [[:year :int32]]]]]
                  :int))))
(check "public scalar export control"
       (pos? (eval '(ffi/export! "scalar-control" identity [:int] :int))))

(if (empty? @failures)
  (do (println "JOLT-FFI-AGGREGATE-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
