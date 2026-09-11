;; Build-smoke fixture for the compiler verdict: a BARE :& binding compiles a
;; foreign-procedure for each tail shape at the CALL (java/ffi.ss
;; ffi-varargs-compile), which petite cannot do -- the back end lowers it to
;; direct Scheme calls that no :var names, so the verdict has to find it on the
;; :ffi-fn node and keep the compiler.
(ns verdict.varargs
  (:require [jolt.ffi :as ffi]))

(ffi/defcfn c-open "open" [:string :int :&] :int)
(ffi/defcfn c-close "close" [:int] :int)

(defn -main [& _]
  (let [fd (c-open "/dev/null" 0)]
    (println "VERDICT-VARARGS" (if (neg? fd) "open-failed" (do (c-close fd) "ok")))))
