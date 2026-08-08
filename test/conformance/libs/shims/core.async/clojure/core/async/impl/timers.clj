;; Same as impl.buffers: jolt's timeout is native, and timers_test requires this
;; namespace :refer :all for it.
(ns clojure.core.async.impl.timers
  (:require [clojure.core.async :as async]))

(def timeout async/timeout)
