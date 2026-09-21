;; clojure.main binds the set!-able compiler flags around every entry — the
;; repl, -e, -m — so a -main, code running AFTER the require's load frame
;; popped, has a thread-local slot for the standard idiom. jolt bound them for
;; -e and for a file load, but not for the -main of `run -m` (nor for a built
;; binary's launcher), so this threw "Can't change/establish root binding"
;; where the same form at the file's top level worked.
(ns eflags.main)

(defn -main [& _]
  (set! *warn-on-reflection* true)
  (set! *assert* false)
  (println "ENTRY-FLAGS" *warn-on-reflection* *assert*))
