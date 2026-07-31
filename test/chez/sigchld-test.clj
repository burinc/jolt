;; Started with SIGCHLD = SIG_IGN inherited across exec (smoke.sh runs this under
;; `trap '' CHLD`). A jolt that spawns has to restore SIG_DFL before its first
;; spawn, or the kernel reaps its children and no exit status is knowable. Reading
;; the disposition needs a spawn to have happened first, so the order matters.
(ns sigchld-test
  (:require [clojure.string :as str]
            [jolt.ffi]
            [jolt.process :refer [process]]))

(jolt.ffi/load-library)
(def c-signal (jolt.ffi/__cfn "signal" [:int :pointer] :pointer))
(def SIGCHLD (if (str/includes? (System/getProperty "os.name") "Mac") 20 17))

(defn disposition []          ; query = install SIG_DFL, read the old, put it back
  (let [prev (c-signal SIGCHLD 0)] (c-signal SIGCHLD prev) prev))

(let [before (disposition)
      _      (deref (process ["sh" "-c" "exit 5"]))
      after  (disposition)]
  (println "inherited:" before "after-spawn:" after)
  (if (and (= before 1) (not= after 1))
    (println "SIGCHLD-TEST OK")
    (println "SIGCHLD-TEST FAILED: inherited" before "after" after
             "(want inherited 1 = SIG_IGN, after anything but 1)")))
