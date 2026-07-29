;; A duplicate set literal. The loader accepts it (the analyzer lowers the set
;; form without a duplicate check), so this namespace loads; the build's require
;; scan re-reads every source file as DATA, and rdr-form->data does check, so the
;; failure happens in a phase that never evaluates a form. That is the phase which
;; used to report no location at all.
(ns app.dup)
(defn f [] (count #{1 1}))
