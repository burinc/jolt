;; The heap ceiling's forced full collection must not carry the heap past it
;; (jolt-exoj). Run by `make gcpolicy` under JOLT_MAX_HEAP=256m.
;;
;; The same work as gc_policy_test.clj's ceiling mode, as top-level forms: that
;; shape lands the ceiling's first full collection with ~140MB of data spread
;; over generations 1-3 and the total already at the ceiling, every run. The
;; collection is tight (old generations marked in place), but Chez copies a
;; segment anyway when its chunk is under a quarter used or it was marked
;; before and is now under three quarters live, and here that was nearly all of
;; it: one collection of every generation held ~120MB of copies beside their
;; sources and peaked at 322MB. The fn-shaped ceiling mode meets the same
;; collection only under CPU contention, which is how it showed up: as a flake.
;;
;; The gate runs this from an empty directory. From the repo root the project's
;; deps.edn is read, which shifts the baseline heap enough that the first forced
;; collection comes at a kinder moment (269MB before the fix).
(ns gc-ceiling-forced-test)

(def held (atom nil))
(reset! held (vec (map (fn [i] {:i i :s (str "held-" i)}) (range 600000))))
(jolt.host/reset-maximum-memory-bytes!)
(loop [i 0 window []]
  (when (< i 40)
    (recur (inc i) (mapv (fn [j] {:i j :s (str j "-" i)}) (range 200000)))))
(println "peak" (jolt.host/maximum-memory-bytes) "max" (.maxMemory (Runtime/getRuntime)))
