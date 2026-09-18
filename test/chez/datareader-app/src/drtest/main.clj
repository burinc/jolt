(ns drtest.main
  (:require drtest.reader))
;; a *data-readers* entry added at runtime, holding the reader FUNCTION rather
;; than a symbol naming it — the shape the JVM's own table uses. The load path
;; used to hand the analyzer (#<procedure> 'form) and die there.
(alter-var-root #'clojure.core/*data-readers* assoc
                'fnr/code  (fn [_] (list '+ 1 2))
                'fnr/value (fn [s] (str s "-value")))
(defn -main [& _]
  (println #code [:ignored])
  (println (read-string "#my/rev \"hello\""))
  (println #fnr/code [:ignored])
  (println #fnr/value "shout"))
