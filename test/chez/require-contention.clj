;; test/chez/require-contention.clj — one namespace whose load PARKS, required at
;; once by many fibers across many carriers and by a real thread (jolt-04ee). Run
;; through jolt; wired into host/chez/smoke.sh, which caps every case.
;;
;; WHY THIS EXISTS, and why concurrent-require.clj was not already it.
;; concurrent-require.clj covers the parked load thoroughly (its properties H and I)
;; but pins the pool to ONE carrier, because what it is testing there is that two
;; fibers sharing a thread id do not read each other's claim. One carrier is the
;; configuration in which this file's hazard cannot happen: ldr-begin-load! used to
;; park a waiting fiber INSIDE the (jolt-with-mutex ldr-load-mu) region, and the
;; damage that does is a blocking re-acquire of that mutex attached to the fiber's
;; resume — which runs from Chez's rewind, on the carrier thread, at the interrupt
;; depth the fiber parked at, where the carrier can do nothing else until it
;; succeeds. Several carriers rewinding parked waiters at the same time is what makes
;; that reachable. The object monitor's version of the same shape wedged 8 runs in 12
;; at 8 carriers and 0 in 12 at 2 (jolt-dfuo), so the count is the teeth.
;;
;; WHAT IT ASSERTS. The load runs exactly once however many contexts asked for it
;; (the target counts its own loads with defonce + swap!), every asker returns, and
;; every asker sees the form AFTER the park — a namespace that is marked loaded but
;; half-built is the failure the load protocol exists to prevent, and it is silent.
;;
;; HOW IT FAILS NOW, which is the part worth having. Since the rule became a rule
;; (host/chez/locks.ss: a fiber never leaves the CPU while its carrier holds a
;; counted lock, checked at both switch points), a regression to the old shape does
;; not need the window at all: the first fiber that waits for a parked load raises,
;; the go block reports it, and this case fails deterministically instead of wedging
;; 1 run in 12. Verified in that direction by reverting the loader.
(require '[clojure.core.async :as a])

(alter-var-root #'clojure.core.async/*fiber-carrier-count* (constantly 8))

(def askers 16)
(def tmp-root (str "/tmp/jolt-reqcont-" (System/currentTimeMillis)))

;; The target parks at top level: the channel is fed by a real thread after a delay,
;; so the take cannot complete inline and the load is genuinely suspended half-run.
;; `after` is the last form, so an asker that returned early is visible. The delay is
;; long enough that every asker is waiting before the load can finish.
(def target-src
  (str "(ns reqcont.target (:require [clojure.core.async :as a]))\n"
       "(defonce loads (atom 0))\n"
       "(swap! loads inc)\n"
       "(def ch (a/chan 1))\n"
       "(a/thread (Thread/sleep 300) (a/>!! ch :fed))\n"
       "(def got (a/<!! ch))\n"
       "(def after :ran)\n"))

(defn- write-source! []
  (let [dir (str tmp-root "/reqcont")]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/target.clj") target-src)))

(defn- clean-up! []
  (doseq [p [(str tmp-root "/reqcont/target.clj") (str tmp-root "/reqcont") tmp-root]]
    (try (.delete (java.io.File. p)) (catch Throwable _ nil))))

(write-source!)
(jolt.host/set-source-roots! (vec (cons tmp-root (jolt.host/source-roots))))

;; Whole? is asked AFTER require returns, which is the caller's view: the namespace
;; must be complete by then, not merely claimed.
(defn- ask []
  (try (require 'reqcont.target)
       (if (resolve 'reqcont.target/after) :whole :half)
       (catch Throwable e (str (.getMessage e)))))

;; Fibers across all 8 carriers, plus one real thread, all released together. The
;; fibers are spawned in one go so the round-robin spreads them; the thread is there
;; because a thread waits on the condition variable while the fibers park, and both
;; kinds of waiter have to be woken by the same release.
(def gate (a/chan))
(def fibers
  (binding [a/*go-backend* :fiber]
    (doall (for [_ (range askers)]
             (a/go (a/<! gate) (ask))))))
(def thread-asker (a/thread (ask)))

(Thread/sleep 50)
(a/close! gate)                          ; every fiber wakes at once

(let [results (conj (mapv a/<!! fibers) (a/<!! thread-asker))
      loads (deref @(resolve 'reqcont.target/loads))
      bad (remove #{:whole} results)]
  (clean-up!)
  (cond
    (seq bad)
    (do (println "REQUIRE-CONTENTION FAILED" (count bad) "of" (count results)
                 "askers did not get a whole namespace:" (pr-str (vec (distinct bad))))
        (System/exit 1))

    (not= 1 loads)
    (do (println "REQUIRE-CONTENTION FAILED the target's top level ran" loads
                 "times, expected 1")
        (System/exit 1))

    :else
    (do (println "REQUIRE-CONTENTION OK" (count results) "askers, 8 carriers, 1 load")
        (System/exit 0))))
