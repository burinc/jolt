(ns app.core)

;; Tree-shake fixture: :allow-dynamic vouches for a RESOLUTION the graph cannot
;; follow (resolve, requiring-resolve ...), not for a ref that RUNS the
;; compiler. `compute` evals and the app's deps.edn allows it, and the shake
;; still bails: the compiler image is direct-linked against the whole core, so
;; it cannot run over a shaken one -- it used to shake (dropping the compiler
;; too), and the eval died. The bail names the eval and offers no allow entry.
;;
;; ^:redef keeps compute the def the bail names (the inline pass would
;; otherwise splice it into -main).
(defn ^:redef compute [n]
  ((eval (list 'fn '[x] (list '* 'x n))) 7))

(defn dead [] :never)

(defn -main [& _]
  (println "allow-dynamic-eval" (compute 6)))
