;; Build-smoke fixture for the compiler verdict: a require by a COMPUTED name.
;; verdict.plugin is on the roots but nothing names it statically, so the build
;; never bakes it and the binary loads it from source at run time -- which needs
;; the compiler. Every 0.8.6 binary carried one; a default build that dropped it
;; died here on "variable jolt-aot-capture-file is not bound".
(ns verdict.dynreq)

(defn -main [& [nm]]
  (require (symbol (or nm "verdict.plugin")))
  (println "VERDICT-DYNREQ" (some? (the-ns (symbol (or nm "verdict.plugin"))))))
