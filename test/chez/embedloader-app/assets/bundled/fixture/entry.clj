(ns fixture.entry
  (:require [fixture.lib :as lib]))

(def source-file *file*)

(defn answer [] (lib/plus 40 2))
