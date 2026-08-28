;; A source file registers a reader macro and uses it BELOW, in the same file:
;; jolt reads and evaluates one top-level form at a time, so the registration is
;; in place by the time the next form is read.
(ns rmtest.main
  (:require [jolt.reader :as reader]
            [clojure.core.strint :refer [<<]]))

(reader/set-dispatch-macro! \% (fn [form] (list 'clojure.core/vector form form)))

;; the raw tier reads the source itself: everything up to the next | verbatim,
;; backslashes and all
(reader/set-dispatch-macro! \|
  (fn [src i]
    (let [end (.indexOf src "|" i)]
      [(subs src i end) (inc end)]))
  {:raw true})

(def v 3)

(defn -main [& _]
  (println #%(+ 1 2))
  (println #|C:\new|)
  (println #$"interp ~{v} ~(inc v)")
  (println (<< "strint ~{v} ~(inc v)"))
  (println (sort (map str (keys (reader/dispatch-macros))))))
