;; test/chez/monitor-contention.clj — one monitor, contended by a real THREAD and
;; by FIBERS at the same time (jolt-dfuo). Run through jolt (wired into
;; host/chez/smoke.sh, which caps every case — see below for why the cap is the
;; only thing that can report this failure).
;;
;; WHY THIS EXISTS. monitor-enter! (host/chez/java/concurrency.ss) used to park a
;; waiting fiber INSIDE the critical section that guards the monitor's own
;; bookkeeping, leaning on jolt-with-mutex being a dynamic-wind to release that
;; mutex on the way out and re-acquire it on the resume. locks.ss's precondition
;; for parking inside a jolt-with-mutex is stronger than that reading: no fiber on
;; the carrier may be holding the mutex while this one is off the CPU, because the
;; re-acquire runs from Chez's rewind, on the carrier thread, at the interrupt
;; depth the fiber parked at, and the carrier can do nothing else until it
;; succeeds. A monitor's bookkeeping mutex does not satisfy it: every fiber on the
;; carrier and every thread passes through that region for the same monitor. One
;; run in twelve of this workload wedged the whole process, with that mutex left
;; held by a carrier whose fiber had parked in the wait and every other carrier
;; blocked in the re-acquire. It is what wedged a `make test` for ninety minutes
;; (jolt-8tma).
;;
;; THE CAP IS THE REPORT. A regression here does not fail, it WEDGES: every thread
;; ends up parked, nothing is left in a poller or a timer, and an in-process
;; watchdog cannot fire either — one that only sleeps and reads an atom was tried
;; and went down with the rest. So this case has no internal deadline and relies on
;; smoke.sh's per-case cap (host/chez/cap.sh), which turns the wedge into a named
;; failing case. That is the same lesson jolt-8tma left, applied to its own cause.
;;
;; WHAT IT ASSERTS, and why it is not just "everything finished". The counter is a
;; plain array element read and written back, NOT an atom: the only thing keeping
;; those increments from being lost is the monitor's mutual exclusion, so the total
;; is an exclusion check as well as a liveness one. Losing exclusion is the other
;; half of the same trapdoor (an OS mutex has thread granularity, a fiber is not a
;; thread), and it is what a "fix" that simply stopped parking would reintroduce.
;;
;; CARRIERS ARE PINNED TO 8, not left to the processor count, so the case behaves
;; the same on a laptop and on a one-core CI box. The count is what gives it teeth
;; and it is not a guess: against the pre-fix runtime, 8 carriers wedge 8 runs in
;; 12, 4 carriers wedge 2 in 12, and 2 carriers wedge none at all — the hazard
;; needs enough carriers to be rewinding parked fibers concurrently.
(require '[clojure.core.async :as a])

(alter-var-root #'clojure.core.async/*fiber-carrier-count* (constantly 8))

(def fibers 8)
(def per-fiber 2000)
(def thread-iters 20000)
(def expected (+ thread-iters (* fibers per-fiber)))

(def o (Object.))
(def counter (int-array 1))

;; Read-modify-write with no atomicity of its own: exclusion has to come from the
;; monitor, so a lost increment is a lost exclusion.
(defn- bump! []
  (locking o (aset counter 0 (inc (aget counter 0)))))

(def t (a/thread (dotimes [_ thread-iters] (bump!)) :thread-done))

(def gs (binding [a/*go-backend* :fiber]
          (doall (for [_ (range fibers)]
                   (a/go (dotimes [_ per-fiber] (bump!)) :fiber-done)))))

(let [tv (a/<!! t)
      fvs (mapv a/<!! gs)
      got (aget counter 0)]
  (cond
    (not= :thread-done tv)
    (do (println "MONITOR-CONTENTION THREAD DID NOT FINISH" (pr-str tv)) (System/exit 1))

    (not= (repeat fibers :fiber-done) (seq fvs))
    (do (println "MONITOR-CONTENTION FIBERS DID NOT FINISH" (pr-str fvs)) (System/exit 1))

    (not= expected got)
    (do (println (str "MONITOR-CONTENTION LOST " (- expected got) " of " expected
                      " increments (exclusion broken)"))
        (System/exit 1))

    :else (do (println "MONITOR-CONTENTION OK" got) (System/exit 0))))
