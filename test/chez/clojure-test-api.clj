;; clojure.test public-surface gate: the vars that are not `is`/`deftest` but that
;; real suites and test runners reach for. Every expectation here is reference
;; clojure.test behavior, checked against `clojure -M` on the same inputs.
;;
;; Kept separate from clojure-test.clj (which gates the assertion/report/fixture
;; machinery) so a missing var reads as a missing var. Prints the
;; `CLOJURE-TEST-API OK` / `FAIL` sentinel smoke.sh greps.
;;
;; Where jolt's model differs from the reference, the difference is asserted here
;; rather than glossed: test-ns reports a delta off one cumulative counter atom
;; instead of binding *report-counters* to a per-namespace ref.
(ns clojure-test-api
  (:require [clojure.test :as t :refer [deftest is]]
            [clojure.string :as str]))

(def ^:private fails (atom []))
(def ^:private passes (atom 0))

(defn- ok= [got want label]
  (if (= got want)
    (swap! passes inc)
    (swap! fails conj (str label ": want " (pr-str want) " got " (pr-str got)))))

;; --- *test-out* / with-test-out --------------------------------------------------
;; A reporter that captures test output binds *test-out*; everything clojure.test
;; prints must go through it. This is what test.check's clojure-test integration
;; needs (with-test-out*).
(ok= (let [sw (java.io.StringWriter.)]
       (binding [t/*test-out* sw] (t/with-test-out (print "captured")))
       (str sw))
     "captured"
     "with-test-out binds *out* to *test-out*")

(deftest ^:private api-failing-test
  (is (= 1 2)))

;; the FAIL line clojure.test prints for a failing assertion goes to *test-out*
(ok= (let [sw (java.io.StringWriter.)]
       (binding [t/*test-out* sw] (t/test-var #'api-failing-test))
       (boolean (str/includes? (str sw) "FAIL")))
     true
     "a failure report is written to *test-out*")

;; --- report is ^:dynamic ---------------------------------------------------------
;; A suite that installs its own reporter for the duration of a run rebinds report
;; rather than adding methods. test.check's clojure-test suite does; so does any
;; TAP/JUnit reporter.
(ok= (let [got (atom nil)]
       [(binding [t/report (fn [_] (reset! got :seen))] (t/do-report {:type :pass}) @got)
        (some? (:dynamic (meta #'t/report)))])
     [:seen true]
     "clojure.test/report is dynamic and rebindable")

;; --- successful? -----------------------------------------------------------------
(ok= [(t/successful? {:test 1 :pass 1 :fail 0 :error 0})
      (t/successful? {:test 1 :pass 0 :fail 1 :error 0})
      (t/successful? {:test 1 :pass 0 :fail 0 :error 1})
      (t/successful? {})]
     [true false false true]
     "successful? is (and (zero? fail) (zero? error)), absent keys count as zero")

;; --- compose-fixtures / join-fixtures --------------------------------------------
(ok= (let [log (atom [])
           f1 (fn [g] (swap! log conj :f1-in) (g) (swap! log conj :f1-out))
           f2 (fn [g] (swap! log conj :f2-in) (g) (swap! log conj :f2-out))]
       ((t/compose-fixtures f1 f2) (fn [] (swap! log conj :body)))
       @log)
     [:f1-in :f2-in :body :f2-out :f1-out]
     "compose-fixtures nests f2 inside f1")

(ok= (let [log (atom [])
           mk (fn [k] (fn [g] (swap! log conj k) (g)))]
       ((t/join-fixtures [(mk :a) (mk :b) (mk :c)]) (fn [] (swap! log conj :body)))
       @log)
     [:a :b :c :body]
     "join-fixtures composes in order")

(ok= (let [ran (atom false)]
       ((t/join-fixtures []) (fn [] (reset! ran true)))
       @ran)
     true
     "join-fixtures of nothing is still a valid fixture")

;; --- function? / get-possibly-unbound-var ----------------------------------------
(def ^:private a-value 42)
(defn- a-fn [] 1)

(ok= [(t/function? inc) (t/function? 'inc) (t/function? 'when) (t/function? 42)
      (t/function? 'clojure-test-api/a-fn) (t/function? 'clojure-test-api/a-value)]
     [true true false false true false]
     "function? sees through a symbol but rejects a macro")

(ok= (t/get-possibly-unbound-var #'a-value) 42
     "get-possibly-unbound-var is var-get for a bound var")

;; --- testing-vars-str / testing-contexts-str -------------------------------------
(ok= (binding [t/*testing-vars* (list #'a-fn)]
       (t/testing-vars-str {:file "f.clj" :line 7}))
     "(a-fn) (f.clj:7)"
     "testing-vars-str renders the var names then file:line")

(ok= (t/testing (str "outer") (t/testing "inner" (t/testing-contexts-str)))
     "outer inner"
     "testing-contexts-str joins outermost first")

;; --- assert-predicate / assert-any / try-expr ------------------------------------
;; The building blocks a library uses to write its own assert-expr method. Each
;; returns FORMS, so check that evaluating them reports the right way.
(defmethod t/assert-expr 'api-pred? [msg form]
  (t/assert-predicate msg form))
(defmethod t/assert-expr 'api-any [msg form]
  (t/assert-any msg form))

(defn- tally-of [f]
  (let [before {:pass (t/n-pass) :fail (t/n-fail) :error (t/n-error)}]
    (binding [t/*test-out* (java.io.StringWriter.)] (f))
    {:pass (- (t/n-pass) (:pass before))
     :fail (- (t/n-fail) (:fail before))
     :error (- (t/n-error) (:error before))}))

(defn- api-pred? [a b] (= a b))
(defmacro api-any [x] `(identity ~x))

(ok= (tally-of #(is (api-pred? 1 1))) {:pass 1 :fail 0 :error 0}
     "assert-predicate passes when the predicate holds")
(ok= (tally-of #(is (api-pred? 1 2))) {:pass 0 :fail 1 :error 0}
     "assert-predicate fails when it does not")
(ok= (tally-of #(is (api-any true))) {:pass 1 :fail 0 :error 0}
     "assert-any passes on a truthy value")
(ok= (tally-of #(is (api-any nil))) {:pass 0 :fail 1 :error 0}
     "assert-any fails on nil")
(ok= (tally-of #(t/try-expr "msg" (api-pred? 1 (throw (ex-info "boom" {})))))
     {:pass 0 :fail 0 :error 1}
     "try-expr turns an unexpected throw into an :error report")

;; --- *load-tests* ----------------------------------------------------------------
;; With *load-tests* false, deftest / with-test / set-test create nothing. The
;; binding has to be in place while the form is MACROEXPANDED, hence eval.
(ok= (binding [t/*load-tests* false]
       (eval '(do (clojure.test/deftest api-not-created (clojure.test/is false))
                  (some? (resolve 'api-not-created)))))
     false
     "*load-tests* false suppresses deftest")

;; --- set-test / deftest- ---------------------------------------------------------
(defn- settable [] :v)
(t/set-test settable (is (= :v (settable))))
(ok= (some? (:test (meta #'settable))) true
     "set-test attaches a :test fn without changing the var's value")
(ok= (settable) :v "set-test leaves the value alone")

(t/deftest- api-private-test (is true))
(ok= (:private (meta #'api-private-test)) true "deftest- marks the var private")

;; --- test-ns / test-all-vars / run-test-var --------------------------------------
;; test-ns returns this call's summary. jolt's is a delta off the cumulative
;; counter atom rather than a per-namespace ref's contents; the summary shape is
;; the same, which is what callers use.
(let [s (binding [t/*test-out* (java.io.StringWriter.)]
          (t/test-ns 'clojure-test-api))]
  (ok= (:type s) :summary "test-ns returns a :summary map")
  (ok= (and (pos? (:test s)) (pos? (:fail s))) true
       "test-ns counts this namespace's tests, including the deliberately failing one"))

(ok= (let [before (t/n-pass)]
       (binding [t/*test-out* (java.io.StringWriter.)] (t/run-test-var #'api-private-test))
       (- (t/n-pass) before))
     1
     "run-test-var runs one var's test")

(let [n @passes f @fails]
  (doseq [m f] (println "clojure-test-api FAIL " m))
  (println "CLOJURE-TEST-API-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "CLOJURE-TEST-API OK" "CLOJURE-TEST-API FAIL"))
  (flush))
