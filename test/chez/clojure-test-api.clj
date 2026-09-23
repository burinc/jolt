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

;; --- the report-counter vars a reporter reads ------------------------------------
;; test.check and test.chuck bind and read these around their own reporting.
(ok= t/*initial-report-counters* {:test 0 :pass 0 :fail 0 :error 0}
     "*initial-report-counters* is the zeroed summary")
(ok= (binding [t/*report-counters* (ref t/*initial-report-counters*)]
       (some? t/*report-counters*))
     true
     "*report-counters* is bindable")
(ok= (let [before (t/n-pass)]
       (t/inc-report-counter :pass)
       (- (t/n-pass) before))
     1
     "inc-report-counter bumps a counter by key")
(ok= (t/testing "a" (t/testing "b" (vec t/*testing-contexts*))) ["b" "a"]
     "*testing-contexts* stacks innermost first")

(deftest ^:private api-two-assertions (is true) (is true))

(ok= (let [before (t/n-pass)]
       (binding [t/*test-out* (java.io.StringWriter.)] (t/test-vars [#'api-two-assertions]))
       (- (t/n-pass) before))
     2
     "test-vars runs each var's :test fn")

(ok= (let [before (t/n-pass)]
       (binding [t/*test-out* (java.io.StringWriter.)] (t/run-test api-two-assertions))
       (- (t/n-pass) before))
     2
     "run-test takes the var by name")

;; --- the registry replaces on redefine -------------------------------------
;; deftest used to append unconditionally, so reloading a test namespace in a
;; live image ran its tests once more per reload and reported the extra runs as
;; extra tests (jolt#1096). Re-evaluating a deftest form is the same code path a
;; reload takes, so that is what these drive. Reference clojure.test cannot grow
;; here at all: it finds tests through var metadata, so redefining the var
;; replaces the test — checked against `clojure -M` on the same input.

(def ^:private redef-runs (atom []))

(deftest api-redefined (swap! redef-runs conj :first))
(deftest api-redefined (swap! redef-runs conj :second))

(let [entries (filter (fn [e] (= (quote api-redefined) (:name e))) @t/registry)]
  (ok= (count entries) 1
       "a redefined deftest replaces its registry entry rather than adding one")
  ;; and the entry must carry the NEW body — replacing with the stale thunk
  ;; would be just as wrong as appending, and invisible to a count.
  (reset! redef-runs [])
  ((:fn (first entries)))
  (ok= @redef-runs [:second]
       "the replacement registers the new body, not the original"))

;; a replaced entry keeps its position, so a reload does not reorder a
;; namespace's tests against each other
(deftest api-order-first (is true))
(deftest api-order-second (is true))
(deftest api-order-first (is true))
(ok= (->> @t/registry
          (filter (fn [e] (contains? #{(quote api-order-first) (quote api-order-second)}
                                     (:name e))))
          (mapv :name))
     [(quote api-order-first) (quote api-order-second)]
     "replacing an entry keeps its position in the registry")

;; the entry is keyed by namespace AND name, so the same test name in two
;; namespaces stays two tests. Driven through register-test! directly rather
;; than with in-ns gymnastics; the registry is saved and restored around it.
(let [saved @t/registry]
  (t/register-test! (quote reg-probe-a) (quote shared) (fn [] nil))
  (t/register-test! (quote reg-probe-b) (quote shared) (fn [] nil))
  (ok= (count (filter (fn [e] (= (quote shared) (:name e))) @t/registry)) 2
       "the same test name in two namespaces is two entries")
  (t/register-test! (quote reg-probe-a) (quote shared) (fn [] nil))
  (ok= (count (filter (fn [e] (= (quote shared) (:name e))) @t/registry)) 2
       "re-registering one of them replaces only that namespace's entry")
  (reset! t/registry saved))

;; --- (is (thrown? ...)) answers the thing thrown ----------------------------
;; `is`'s own docstring states it: "checks that an instance of c is thrown from
;; body, fails if not; then returns the thing thrown". It used to answer
;; do-report's value instead -- the counters map on a pass -- so binding the
;; result and asserting on it silently stopped asserting (jolt#1091). Every
;; expectation here was read off JVM Clojure 1.12.
;;
;; quiet? runs an assertion with the report swallowed, so these do not print
;; into the gate's output; the pass/fail counters still move and are checked.
(defn- quiet? [f] (binding [t/*test-out* (java.io.StringWriter.)] (f)))

(ok= (quiet? (fn [] (instance? clojure.lang.ExceptionInfo
                               (is (thrown? clojure.lang.ExceptionInfo
                                            (throw (ex-info "boom" {:a 1})))))))
     true
     "thrown? answers the exception, not the counters")

;; the shape the issue is about, and the reason it matters: on a counters map
;; ex-message is nil, so the inner assertion compared nil to a string and tested
;; nothing at all.
(ok= (quiet? (fn [] (let [ex (is (thrown? clojure.lang.ExceptionInfo
                                          (throw (ex-info "boom" {:a 1}))))]
                      [(ex-message ex) (ex-data ex)])))
     ["boom" {:a 1}]
     "the bound exception carries its message and data")

(ok= (quiet? (fn [] (instance? clojure.lang.ExceptionInfo
                               (is (thrown-with-msg? clojure.lang.ExceptionInfo #"boom"
                                                     (throw (ex-info "boom" {})))))))
     true
     "thrown-with-msg? answers the exception too")

;; a subclass matches and still answers the exception
(ok= (quiet? (fn [] (instance? clojure.lang.ExceptionInfo
                               (is (thrown? RuntimeException (throw (ex-info "sub" {})))))))
     true
     "a subclass match answers the exception")

;; nil when nothing matching the CLASS was thrown, which is the JVM's answer.
;; Worth pinning: answering the exception here would be a fresh divergence
;; rather than a fix, since the JVM's catch names the expected class and a
;; mismatch never reaches it.
(ok= (quiet? (fn [] (is (thrown? clojure.lang.ExceptionInfo :nothing-thrown))))
     nil
     "nothing thrown answers nil")
(ok= (quiet? (fn [] (is (thrown? java.io.IOException (throw (ex-info "wrong class" {}))))))
     nil
     "a non-matching class answers nil")
(ok= (quiet? (fn [] (is (thrown-with-msg? java.io.IOException #"boom"
                                          (throw (ex-info "boom" {}))))))
     nil
     "thrown-with-msg? of a non-matching class answers nil")
;; ...but a matching class with a non-matching message answers the exception:
;; the JVM's e# follows the message test inside the class's own catch.
(ok= (quiet? (fn [] (instance? clojure.lang.ExceptionInfo
                               (is (thrown-with-msg? clojure.lang.ExceptionInfo #"nope"
                                                     (throw (ex-info "boom" {})))))))
     true
     "a non-matching message still answers the exception")

;; the value changed; the reporting must not have
(ok= (let [p (t/n-pass) f (t/n-fail)]
       (quiet? (fn []
                 (is (thrown? clojure.lang.ExceptionInfo (throw (ex-info "x" {}))))
                 (is (thrown-with-msg? clojure.lang.ExceptionInfo #"x" (throw (ex-info "x" {}))))
                 (is (thrown? clojure.lang.ExceptionInfo :nothing-thrown))))
       [(- (t/n-pass) p) (- (t/n-fail) f)])
     [2 1]
     "two passes and one fail still counted as before")

(let [n @passes f @fails]
  (doseq [m f] (println "clojure-test-api FAIL " m))
  (println "CLOJURE-TEST-API-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "CLOJURE-TEST-API OK" "CLOJURE-TEST-API FAIL"))
  (flush))
