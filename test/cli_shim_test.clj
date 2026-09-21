(ns cli-shim-test
  (:require [jolt.cli :as cli]))

(def failures (atom 0))

(defn check [label expected actual]
  (if (= expected actual)
    (println "  ok  " label)
    (do (swap! failures inc)
        (println "  FAIL" label "\n    expected:" (pr-str expected)
                 "\n    actual:  " (pr-str actual)))))

(check "parse-opts coerces"
       {:port 8080}
       (cli/parse-opts ["--port" "8080"] {:coerce {:port :long}}))

(check "format-opts renders a default"
       "  --port  Port (default: 80)"
       (cli/format-opts {:spec {:port {:desc "Port" :default 80 :coerce :long}}}))

;; dispatch reaches the handler, folding the fn's own :org.babashka/cli meta
(def dispatched (atom nil))
(defn greet {:org.babashka/cli {:coerce {:loud :boolean}}} [m] (reset! dispatched m))
(cli/dispatch [{:cmds ["greet"] :fn greet :args->opts [:name]}] ["greet" "ada" "--loud"])
(check "dispatch folds fn metadata"
       {:name "ada" :loud true}
       (:opts @dispatched))

;; *exit-fn* is deliberately NOT re-exported: it is a dynamic var, which
;; import-vars cannot express as a delegating fn. Rebind it on babashka.cli.
(check "*exit-fn* is not re-exported"
       nil
       (resolve 'jolt.cli/*exit-fn*))

(println "cli shim gate:" (if (zero? @failures) "passed" "FAILED"))
(when (pos? @failures) (System/exit 1))
