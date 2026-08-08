;; jolt implements the channel buffers natively (host/chez/java/async.ss), so the
;; upstream clojure.core.async.impl.buffers namespace does not exist here. The
;; suites reach for it directly — async_test builds a promise-chan out of
;; b/promise-buffer — so this stands in, mapping each constructor onto jolt's.
(ns clojure.core.async.impl.buffers
  (:require [clojure.core.async :as async]))

(def fixed-buffer async/buffer)
(def dropping-buffer async/dropping-buffer)
(def sliding-buffer async/sliding-buffer)
(def promise-buffer async/__promise-buffer)
