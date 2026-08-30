(ns libadd.core
  (:require [jolt.ffi :as ffi]))

(def point-layout (ffi/layout [:struct [[:x :float] [:y :float]]]))

(defn add [x y] (+ x y))
(defn point-size [] (ffi/layout-size point-layout))

;; Publish scalar controls and a function that calls the Clojure half of
;; jolt.ffi. The latter catches a source-mode build driver mistaking jolt.ffi,
;; loaded by jolt.main in the build process, for code inherited by this distinct
;; library image: that leaves layout-size interned but UNBOUND at invocation.
(ffi/export! "add" add [:int :int] :int)
(ffi/export! "point_size" point-size [] :int)
