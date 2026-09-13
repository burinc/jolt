(ns app.core)

;; Fixture for a WRONG :allow-dynamic vouch. `dynaload` is spec.gen's shape (a
;; `require` of a computed name, then a `resolve`) and deps.edn vouches for it,
;; so every build -- the default one too, since the compiler verdict runs on
;; every build -- drops the compiler image. But -main takes the path: the
;; require runs, names plugin.core, which nothing requires statically so the
;; build never baked it, and the loader finds its SOURCE on the roots (the
;; fixture runs from its own directory). Compiling that source needs the
;; compiler the vouch let the build drop. The loader refuses by name, pointing
;; at the vouch; it used to die on a raw "variable jolt-aot-capture-file is not
;; bound" from the first compiler parameter it touched.
;;
;; ^:redef keeps dynaload the def the vouch names (see allow-dynamic-app).
(defn ^:redef dynaload [s]
  (let [ns (namespace s)]
    (require (symbol ns))
    (or (resolve s)
        (throw (ex-info (str "Var " s " is not on the classpath") {})))))

(defn -main [& _]
  (println "before")
  (println ((dynaload 'plugin.core/greet) "world")))
