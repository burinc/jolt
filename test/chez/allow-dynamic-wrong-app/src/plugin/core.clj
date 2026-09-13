(ns plugin.core)

;; Reached only through app.core/dynaload's computed require: no ns form names
;; this namespace, so the build does not bake it and a run must load it from
;; this source.
(defn greet [who] (str "hello " who))
