;; A .clj namespace requiring a .jolt one, so the build has to resolve both.
(ns jxapp.main
  (:require [clojure.string]
            [jxapp.lib :as lib]))

(defn -main [& _]
  (println "JOLT-EXT" (lib/shout "built") (lib/twice :x)))
