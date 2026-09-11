;; Build-smoke fixture for the compiler verdict (host/chez/dce.ss
;; dce-needs-compiler?): -main never references `compiled`, but its init RUNS at
;; start -- nothing is pruned in a default build -- so the verdict must root
;; every def, not only what -main reaches, and keep the compiler for this eval.
;; Rooted at -main alone the binary booted from petite and died in this init.
(ns verdict.evaldef)

(def compiled (eval '(fn [x] (* 2 x))))

(defn -main [& _]
  (println "VERDICT-EVALDEF ok"))
