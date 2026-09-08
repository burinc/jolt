;; The boundary of analyze/unknown-namespace: that check fires only on a DOTTED
;; ns with a lowercase segment after the last dot, because an undotted lowercase
;; name is ambiguous — it may be an :import-ed class short name whose provider has
;; not autoloaded yet. So `str/join` with no (:require [clojure.string :as str])
;; stays a host static and reports as a class miss at the call, not at compile
;; time. Pinned here so widening the analyzer check has to move this on purpose.
(ns input)

(defn f [] (str/join "," [1 2]))

(f)
