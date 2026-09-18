;; The boundary of analyze/unknown-namespace, undotted side: a lowercase name
;; that is no alias, namespace or registered class is namespace-shaped, so
;; `str/join` with no (:require [clojure.string :as str]) is rejected where it
;; is written — inside the fn body, before anything runs — as the JVM's
;; Compiler.resolveIn rejects it. It used to be a host static that failed at
;; the call as "Unknown class str". The Capitalized spelling (`Nope/foo`) keeps
;; that late binding: runtime/unknown-class-capitalized-ns pins it.
(ns input)

(defn f [] (str/join "," [1 2]))

(f)
