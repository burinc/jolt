;; A jolt that spawns has to restore SIG_DFL for SIGCHLD before its FIRST spawn.
;; The disposition survives exec, so jolt can arrive with SIG_IGN through no choice
;; of its own — a CI runner, a supervisor, any parent that ignored it — and with it
;; in place the kernel reaps every child itself, waitpid can only fail ECHILD, and
;; no exit status is knowable.
;;
;; The restore is once per process, on the first spawn, so this file must set
;; SIG_IGN before spawning anything: process-test.clj sets it AFTER a spawn on
;; purpose, to exercise the reap loop, and therefore cannot reach this path at all.
;;
;; SIG_IGN is set here rather than by the shell (`trap '' CHLD`) because a shell
;; may use SIGCHLD for its own job control and decline to pass the ignore through
;; exec — macOS sh does pass it, Linux sh does not, so a shell-driven version
;; passed locally and proved nothing in CI.
(ns sigchld-test
  (:require [clojure.string :as str]
            [jolt.ffi]
            [jolt.process :refer [process]]))

(jolt.ffi/load-library)
(def c-signal (jolt.ffi/__cfn "signal" [:int :pointer] :pointer))
(def SIGCHLD (if (str/includes? (System/getProperty "os.name") "Mac") 20 17))
(def SIG_DFL 0)
(def SIG_IGN 1)

;; query = install SIG_DFL, read what was there, put it back
(defn disposition [] (let [prev (c-signal SIGCHLD SIG_DFL)] (c-signal SIGCHLD prev) prev))

(let [set-rc (c-signal SIGCHLD SIG_IGN)
      before (disposition)]
  (if (not= before SIG_IGN)
    ;; the precondition did not take — say so rather than passing vacuously
    (println "SIGCHLD-TEST FAILED: could not set SIG_IGN (signal returned" set-rc
             ", disposition reads" before ")")
    (let [exit  (:exit (deref (process ["sh" "-c" "exit 5"])))   ; the FIRST spawn
          after (disposition)]
      (println "inherited:" before "after-spawn:" after "exit:" exit)
      (cond
        (= after SIG_IGN)
        (println "SIGCHLD-TEST FAILED: SIG_IGN survived the first spawn —"
                 "the SIG_DFL restore did not run")
        (not= exit 5)
        (println "SIGCHLD-TEST FAILED: exit status was" exit "not 5")
        :else
        (println "SIGCHLD-TEST OK")))))
