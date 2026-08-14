;; jolt.scheme gate (epic jolt-of08.6) — the Scheme escape hatch: call host
;; Scheme procedures and evaluate Scheme text from jolt, by decision (we want
;; interop). The contract is RAW: no marshaling layer — numbers, strings,
;; booleans and chars are shared representations; anything else crosses as
;; whatever it is on the other side, and host values round-trip opaquely.
;; Host-specific and non-portable by design.
;; Run: bin/jolt run test/chez/jolt-scheme-test.clj (smoke.sh greps for
;; "JOLT-SCHEME-TEST OK").
(ns jolt-scheme-test)

(require '[jolt.scheme :as scheme])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; call: resolve a top-level Scheme procedure by name and apply it
(check-eq "call +" (scheme/call "+" 1 2) 3)
(check-eq "call string-append" (scheme/call "string-append" "a" "b") "ab")
(check-eq "call expt" (scheme/call "expt" 2 10) 1024)

;; proc: the procedure as a value, callable like any jolt fn
(let [upcase (scheme/proc "char-upcase")]
  (check-eq "proc is callable" (upcase \a) \A))
(check-eq "proc composes" (map (scheme/proc "char-upcase") [\a \b]) [\A \B])

;; a host value round-trips opaquely through jolt
(let [v (scheme/call "vector" 1 2 3)]
  (check-eq "host value answers its own predicates" (scheme/call "vector?" v) true)
  (check-eq "host value is not fooled by jolt values" (scheme/call "vector?" [1 2 3]) false)
  (check-eq "host value reads back" (scheme/call "vector-ref" v 0) 1))

;; eval-string: Scheme text, last form's value; definitions persist
(check-eq "eval-string" (scheme/eval-string "(let ((x 3)) (* x 14))") 42)
(check-eq "eval-string multiple forms"
          (scheme/eval-string "(define jolt-scheme-gate-var 7) jolt-scheme-gate-var")
          7)

;; booleans cross as booleans
(check-eq "scheme #t is true" (scheme/call "even?" 4) true)
(check-eq "scheme #f is false" (scheme/call "even?" 5) false)

;; errors are catchable jolt-side
(check-eq "an unbound name throws"
          (try (scheme/call "no-such-procedure-jolt-gate" 1) :no-throw
               (catch Exception e :threw))
          :threw)
(check-eq "a scheme error throws"
          (try (scheme/call "car" 5) :no-throw
               (catch Throwable e :threw))
          :threw)

;; defsfn sugar
(scheme/defsfn sch-max "max")
(check-eq "defsfn binds a callable" (sch-max 3 9 5) 9)

(if (empty? @failures)
  (println "JOLT-SCHEME-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-SCHEME-TEST FAILED:" (count @failures))))
