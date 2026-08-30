(ns libadd.core
  (:require [jolt.ffi :as ffi]))

(def point-layout (ffi/layout [:struct [[:x :float] [:y :float]]]))

(defn add [x y] (+ x y))
(defn point-size [] (ffi/layout-size point-layout))

;; Publish `add` and `point_size` as C-callable entry points. An embedder
;; resolves them via jolt_lookup("<name>") after jolt_library_init. export! runs
;; at the library's top-level (during heap build), so both are available before
;; jolt_library_init returns.
;;
;; point_size is the one that reaches the Clojure half of jolt.ffi. A library
;; image is not the build driver's image, so a driver that reads its own loaded
;; set as the library's leaves layout-size interned but UNBOUND at the call.
(ffi/export! "add" add [:int :int] :int)
(ffi/export! "point_size" point-size [] :int)
