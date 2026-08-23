;; jolt.ffi :string <-> NULL gate. Chez's `string` foreign type carries NULL in
;; both directions as #f; jolt's nil is a separate sentinel, so without the
;; backend's wrapping the boundary leaked Scheme — passing nil raised "invalid
;; foreign-procedure argument #[jolt-nil-v1]", and a NULL return arrived as false.
;; Run: bin/jolt run test/chez/jolt-ffi-string-null-test.clj (smoke.sh greps for
;; "JOLT-FFI-STRING-NULL-TEST OK").
(ns jolt-ffi-string-null-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; setlocale(int, const char *): NULL QUERIES the current locale instead of
;; setting it, so it exercises "NULL is a meaningful argument" without needing a
;; helper library. LC_ALL is 0 on both platforms jolt targets.
(ffi/defcfn c-setlocale "setlocale" [:int :string] :string)

;; getenv returns NULL for a name that is not set — the return direction.
(ffi/defcfn c-getenv "getenv" [:string] :string)

;; --- argument direction ------------------------------------------------------
(let [queried (c-setlocale 0 nil)]
  (check-eq "nil argument reaches C as NULL (setlocale queries)"
            (string? queried) true)
  (check-eq "the queried locale is non-empty" (pos? (count queried)) true))

;; A real string still marshals; nil support must not disturb the common path.
(check-eq "a string argument still marshals" (string? (c-setlocale 0 "C")) true)

;; --- return direction --------------------------------------------------------
(check-eq "a NULL return arrives as nil, not false"
          (c-getenv "JOLT_FFI_STRING_NULL_TEST_DEFINITELY_UNSET")
          nil)
(check-eq "a NULL return is not false"
          (false? (c-getenv "JOLT_FFI_STRING_NULL_TEST_DEFINITELY_UNSET"))
          false)
(check-eq "a non-NULL return is still a string" (string? (c-getenv "PATH")) true)

;; --- nil is only special for :string -----------------------------------------
;; :pointer keeps taking ffi/null as the integer 0; nothing here changes that.
(check-eq "ffi/null is still 0" (ffi/null? ffi/null) true)

(if (empty? @failures)
  (println "JOLT-FFI-STRING-NULL-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-FFI-STRING-NULL-TEST FAILED:" (count @failures))))
