;; The issue #1292 half of the stall gate: the report is opt-in. One row, the
;; shape of ffi-gc-stall-test.clj's row 1 — main parks three seconds in an
;; unmarked sleep while a future allocates, so a collection waits on the sleep.
;; ffi-gc-stall-test.sh runs it with JOLT_GC_STALL unset (no report), at a
;; threshold past the sleep (no report) and at one inside it (one report,
;; naming that threshold). The stall itself is the same in every run.
(ns ffi-gc-stall-quiet)

(require '[jolt.ffi :as ffi])

(ffi/defcfn c-sleep-active "sleep" [:uint] :uint)

(defn churn [] (dotimes [_ 400] (dorun (map str (range 2000)))))

(let [f (future (churn) :churned)]
  (c-sleep-active 3)
  (if (= :churned @f)
    (do (println "FFI-GC-STALL-QUIET OK") (flush) (System/exit 0))
    (do (println "FAIL: the future did not finish") (flush) (System/exit 1))))
