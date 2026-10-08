;; jolt.parinfer gate — replays parinfer.js's own case suite (test/chez/
;; parinfer-cases.edn, converted from its test/cases/*.json) the way its
;; test.js structure checks do: the result itself, an idempotence rerun from
;; the result's cursor, a cursor-less rerun in the same mode, and the
;; cross-mode check from its annotated-string tests (a cursor-less result is a
;; fixed point of the other mode). Self-checks and prints PARINFER OK.
;; Run: bin/jolt run test/chez/parinfer-test.clj
(ns parinfer-test
  (:require
   [clojure.edn :as edn]
   [clojure.java.io :as io]
   [jolt.parinfer :as parinfer]))

(def failures (atom []))
(defn fail! [msg] (swap! failures conj msg))

(def cases
  (edn/read-string (slurp (io/file (.getParent (io/file *file*)) "parinfer-cases.edn"))))

(def run-mode
  {:indent parinfer/indent-mode
   :paren parinfer/paren-mode
   :smart parinfer/smart-mode})

;; test.js assertStructure: tab stops and paren trails are compared only when
;; the case states them; an error compares name and position, not message.
(defn check-structure [label actual expected]
  (doseq [k [:text :success :cursor-x :cursor-line]]
    (when-not (= (get actual k) (get expected k))
      (fail! (str label " " k ": want " (pr-str (get expected k)) " got " (pr-str (get actual k))))))
  (when-not (= (nil? (:error actual)) (nil? (:error expected)))
    (fail! (str label " error: want " (pr-str (:error expected)) " got " (pr-str (:error actual)))))
  (when (:error actual)
    (doseq [k [:name :line-no :x]]
      (when-not (= (get-in actual [:error k]) (get-in expected [:error k]))
        (fail! (str label " error " k ": want " (pr-str (get-in expected [:error k]))
                    " got " (pr-str (get-in actual [:error k])))))))
  (when-let [want (:tab-stops expected)]
    (when-not (= want (:tab-stops actual))
      (fail! (str label " tab-stops: want " (pr-str want) " got " (pr-str (:tab-stops actual))))))
  (when-let [want (:paren-trails expected)]
    (when-not (= want (:paren-trails actual))
      (fail! (str label " paren-trails: want " (pr-str want) " got " (pr-str (:paren-trails actual)))))))

(def cross-mode {:indent :paren :paren :indent :smart :paren})

(defn run-case [{:keys [id mode text options result]}]
  (let [label (str "#" id " " (name mode))
        run (run-mode mode)
        ;; returnParens on, as test.js does, so building the tree is exercised
        options (assoc options :return-parens true)
        r1 (try (run text options)
                (catch Throwable e (fail! (str label " threw " (pr-str (ex-message e)))) nil))]
    (when r1
      (check-structure label r1 result)
      (when-not (or (:error result) (:tab-stops result) (:paren-trails result) (:changes options))
        (let [r1' (dissoc r1 :paren-trails)]
          (check-structure (str label " idempotence")
                           (run (:text r1) (assoc options :cursor-x (:cursor-x r1) :cursor-line (:cursor-line r1)))
                           r1')
          (when-not (contains? result :cursor-x)
            (check-structure (str label " rerun") (run (:text r1) options) r1')
            ;; the case's char options still apply in the other mode
            (let [other ((run-mode (cross-mode mode)) (:text r1)
                         (select-keys options [:comment-chars :open-paren-chars :close-paren-chars]))]
              (when-not (and (:success other) (= (:text other) (:text r1)))
                (fail! (str label " cross-mode " (name (cross-mode mode)) ": want " (pr-str (:text r1))
                            " got " (pr-str (select-keys other [:text :error]))))))))))))

(run! run-case cases)

;; ids are unique across the three suites (test.js checks this too)
(when-not (= (count cases) (count (set (map :id cases))))
  (fail! "duplicate case ids"))
(when-not (= 154 (count cases))
  (fail! (str "expected 154 cases, read " (count cases))))

(if (empty? @failures)
  (println "PARINFER OK" (count cases) "cases")
  (do (run! println @failures)
      (println "PARINFER FAILED" (count @failures))
      (System/exit 1)))
