;; gc-arrays — what a MAJOR COLLECTION costs while a large primitive array is
;; live. Not throughput: the timed region contains nothing but full collections,
;; with one array rooted across them, so what is measured is the collector's own
;; work over that live set.
;;
;; The axis is again the BACKING (see byte-arrays for the access side). A jolt
;; ^longs/^ints array is an fxvector and a ^bytes array is a bytevector — leaf
;; objects with no pointers in them — so the collector has nothing to trace
;; through, where a boxed vector of the same length is a slot per element that it
;; must walk on every full collection. That is a property of the heap shape rather
;; than of any compiler pass, and nothing else in the suite measures it: a change
;; that puts a typed array back on a boxed backing keeps every answer correct, and
;; every other benchmark here (which allocates arrays and drops them) sees only a
;; small part of the difference.
;;
;; Four phases, in this order and reported separately:
;;   floor    no large array live — the fixed cost of a full collection over the
;;            runtime's own image, which every row below includes
;;   longs    a live long-array (fxvector: not traced)
;;   bytes    a live byte-array (bytevector: not traced)
;;   boxed    a live object-array of the same length, holding one shared value —
;;            the CONTROL, and what a typed array's pause looks like when its
;;            backing is a boxed vector. It is a scan of `cells` slots, not a
;;            traversal of `cells` objects, so its cost is the walk itself
;;
;; `mean:` covers the two phases the backings changed (longs + bytes), measured
;; three times over; floor and boxed are reported per collection on their own line
;; and stay out of the mean, because neither is expected to move and a large
;; constant on both sides would only dilute the ratio the release gate reads. The
;; control runs a tenth of the collections for the same reason — one of its
;; collections costs two orders of magnitude more than one of the gated ones.
;;
;; Each phase allocates its array inside its own frame and hands back only a
;; nanosecond count, so the next phase does not inherit the previous live set; the
;; array is READ after the timed region, which is what keeps it rooted across the
;; collections rather than dead on arrival (a GC measurement whose live value is
;; not actually reachable measures the floor and nothing else).
;;
;; Portable Clojure (jolt + JVM Clojure). System/gc is a hint on the JVM and a full
;; collection here, and the two collectors are not the same machine, so the vs-JVM
;; column on this row is an order-of-magnitude reading only — the useful comparison
;; is jolt against jolt, which is what ci/bench-gate.sh does.
;;   bench/run.sh gc-arrays 150
(ns gc-arrays)

(def cells (* 8 1024 1024))   ; elements in the live array

(defn pause-ns ^long [^long collects]
  (let [t0 (System/nanoTime)]
    (loop [i 0]
      (when (< i collects)
        (System/gc)
        (recur (inc i))))
    (- (System/nanoTime) t0)))

(defn floor-phase ^long [^long collects]
  (pause-ns collects))

(defn longs-phase ^long [^long n ^long collects]
  (let [a (long-array n 7)
        el (pause-ns collects)]
    (when (zero? (aget ^longs a (dec n))) (println "unexpected zero"))
    el))

(defn bytes-phase ^long [^long n ^long collects]
  (let [a (byte-array n (byte 7))
        el (pause-ns collects)]
    (when (zero? (aget ^bytes a (dec n))) (println "unexpected zero"))
    el))

(defn boxed-phase ^long [^long n ^long collects]
  (let [shared (Object.)
        a (object-array n)]
    (loop [i 0]
      (when (< i n)
        (aset a i shared)
        (recur (inc i))))
    (let [el (pause-ns collects)]
      (when (nil? (aget ^objects a (dec n))) (println "unexpected nil"))
      el)))

(defn us-each [^long nanos ^long collects] (/ (Math/round (/ nanos collects 100.0)) 10.0))

(defn -main [& args]
  (let [collects (if (seq args) (Integer/parseInt (first args)) 150)
        ;; the control is a per-collect figure and each of its collections costs
        ;; two orders of magnitude more than the phases being gated, so it runs a
        ;; tenth as many rather than dominating the bench's wall time.
        ctl (max 1 (quot collects 10))
        warm (max 1 (quot collects 10))
        reps 3]
    (floor-phase warm)                                   ; warmup
    (longs-phase 1024 warm)
    (let [flr (floor-phase collects)
          pairs (mapv (fn [_] [(longs-phase cells collects)
                               (bytes-phase cells collects)])
                      (range reps))
          box (boxed-phase cells ctl)
          lng (long (/ (reduce + (mapv (fn [p] (nth p 0)) pairs)) reps))
          byt (long (/ (reduce + (mapv (fn [p] (nth p 1)) pairs)) reps))
          means (mapv (fn [p] (/ (+ (nth p 0) (nth p 1)) 2.0)) pairs)
          mean (/ (reduce + means) reps)]
      (println "gc-arrays collects" collects "cells" cells "control collects" ctl)
      ;; Sanity check on the measurement itself, as a ratio inside this one run: the
      ;; control's collection walks `cells` slots, so it MUST cost measurably more
      ;; than the floor's. When it does not, no collection is being timed — Chez refuses
      ;; to collect while more than one thread is active and jolt's System/gc is then
      ;; a guarded no-op (all the JVM's hint contract promises either) — and a mean
      ;; over no-op calls would read as an extremely fast collector. So none is
      ;; printed, which ci/bench-gate.sh treats as a failure. It is the right
      ;; failure: the number would otherwise be meaningless on both sides.
      ;; The 1.25x bar is deliberately loose: the two differ by the WALK, which is
      ;; a fixed cost, so the ratio shrinks as the floor grows — under `jolt run` the
      ;; dev image's own live heap puts the floor at 29ms and this reads 1.9x, where
      ;; a built binary reads about 1600x. A no-op run reads 1.0x, since both phases
      ;; then time the same empty loop.
      (if (<= (/ box ctl) (* 1.25 (/ flr collects)))
        (println "no collection was timed: the boxed control cost no more per"
                 "collect than the floor (System/gc a no-op, or a collector that"
                 "no longer walks a boxed vector)")
        (do
          (println "per-collect us: floor" (us-each flr collects)
                   " longs" (us-each lng collects)
                   " bytes" (us-each byt collects)
                   " boxed" (us-each box ctl))
          (println "runs:" (mapv (fn [m] (/ (Math/round (/ m 100000.0)) 10.0)) means))
          (println "mean:" (/ (Math/round (/ mean 100000.0)) 10.0) "ms"))))))
