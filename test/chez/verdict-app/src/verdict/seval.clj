;; Build-smoke fixture for the compiler verdict: jolt.scheme/eval-string
;; compiles Scheme text at run time, so it is a compile ref and the compiler
;; stays in the binary.
(ns verdict.seval
  (:require [jolt.scheme :as s]))

(defn -main [& _]
  (println "VERDICT-SEVAL" (s/eval-string "(+ 40 2)")))
