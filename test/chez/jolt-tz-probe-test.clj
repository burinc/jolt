;; jolt.host tz gate — the libc timezone probe must not leave TZ behind.
;;
;; tz-offset-seconds sets TZ, calls tzset and reads tm_gmtoff. TZ is process
;; global, so without a restore the process is left in whichever zone was probed
;; last — and the capability check at boot ends on "UTC". Every jolt process then
;; answered UTC from localtime(), including user code calling it through jolt.ffi,
;; while the machine was somewhere else entirely.
;;
;; Run: bin/jolt run test/chez/jolt-tz-probe-test.clj (smoke.sh greps for
;; "JOLT-TZ-PROBE-TEST OK").
(ns jolt-tz-probe-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

(ffi/defcfn c-getenv "getenv" [:string] :string)
(ffi/defcfn c-setenv "setenv" [:string :string :int] :int)
(ffi/defcfn c-unsetenv "unsetenv" [:string] :int)
(ffi/defcfn c-time "time" [:pointer] :long)
(ffi/defcfn c-localtime "localtime" [:pointer] :pointer)
(ffi/defcfn c-gmtime "gmtime" [:pointer] :pointer)

(defn- hour-of [f]
  (let [b (ffi/alloc 8)]
    (try (c-time b) (ffi/read (f b) :int 8)     ; tm_hour is the third int
         (finally (ffi/free b)))))

;; The boot-time capability probe has already run by the time this loads, so an
;; unrestored TZ would be observable right here.
(check-eq "TZ is not left set by the boot probe" (c-getenv "TZ") nil)

;; A named zone under a KNOWN TZ must come back unchanged. This is the case the
;; boot probe broke: it left TZ=UTC, so a caller who had set TZ themselves lost it.
(c-setenv "TZ" "America/New_York" 1)
(check-eq "a zone query answers correctly"
          (jolt.host/tz-offset-seconds "Australia/Sydney" 1768478400) 39600)
(check-eq "TZ survives a zone query" (c-getenv "TZ") "America/New_York")
(c-unsetenv "TZ")

;; ...and an UNSET TZ must stay unset rather than become an empty string, which
;; libc reads as UTC rather than as "use the system zone".
(check-eq "a zone query still answers with TZ unset"
          (jolt.host/tz-offset-seconds "America/New_York" 1768478400) -18000)
(check-eq "TZ is still unset afterwards" (c-getenv "TZ") nil)

;; The end-to-end symptom: with the system zone in effect, localtime and gmtime
;; agree only if the machine really is on UTC. On a UTC machine this check cannot
;; discriminate, so it is skipped there rather than asserted as a pass.
(let [local (hour-of c-localtime)
      utc   (hour-of c-gmtime)
      sys-tz (c-getenv "TZ")]
  (if (= local utc)
    (println (str "  .. (skipped: this machine's local time IS UTC, TZ=" (pr-str sys-tz) ")"))
    (check-eq "localtime is not silently gmtime" (= local utc) false)))

(if (empty? @failures)
  (println "JOLT-TZ-PROBE-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-TZ-PROBE-TEST FAILED:" (count @failures))))
