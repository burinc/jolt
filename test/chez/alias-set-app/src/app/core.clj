;; ::o/x is :app.other/x; :o/x is literally :o/x. Two distinct keywords, so this
;; set has two elements and the namespace loads fine.
;;
;; The build re-reads every source file as DATA to scan its requires, and that read
;; runs in scan mode, where an auto keyword whose alias is not registered yet keeps
;; the ALIAS TEXT as its namespace — so both of these read as :o/x and collided.
;; The duplicate-literal check then rejected a program that is perfectly good.
(ns app.core
  (:require [app.other :as o]))
(def s #{::o/x :o/x})
(defn -main [& _] (println (count s)))
