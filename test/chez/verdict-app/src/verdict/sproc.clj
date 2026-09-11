;; Build-smoke fixture for the compiler verdict: jolt.scheme/proc is a top-level
;; lookup that needs no compiler, so it lives in the runtime half
;; (host-contract.ss scheme-proc) and a compiler-DROPPED binary still answers
;; it. It used to sit in compile-eval.ss, the file such a binary leaves out.
(ns verdict.sproc
  (:require [jolt.scheme :as s]))

(defn -main [& _]
  (println "VERDICT-SPROC" (s/call "fx+" 40 2)))
