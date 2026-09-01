;; executors — java.util.concurrent dispatch: what it costs to get a task onto a
;; worker and, for the submit shapes, the result back. The four phases are the four
;; ways a pool is asked to do that, and they fail differently:
;;
;;   drain      fire-and-forget onto a cached pool, faster than the workers can
;;              clear it. Measures the enqueue, the wake, and the growth rule under
;;              a producer that outruns them — the shape where a pool that wakes
;;              every idle worker per task, or grows one per queued task, collapses.
;;   round-trip submit and wait, one at a time. The handoff both ways, with no
;;              queue depth to hide behind: park, unpark, and the future's latch.
;;   ramp       tasks that block until the last one has started, so the pool must
;;              actually reach that many threads. Thread creation, plus the growth
;;              decision on the one workload that genuinely needs it.
;;   contended  four producers on one pool: how much of the queue's mutex is left
;;              after they have finished fighting over it.
;;
;; Not a compiler-pass benchmark — the cost is in the runtime's queue and wakes
;; (host/chez/java/concurrency.ss), and the suite is where the runtime's hot paths
;; get watched. It is here because nothing else in the suite measures concurrency
;; throughput, and a 17x regression in it once passed every correctness gate.
;;
;; Portable Clojure (jolt + JVM Clojure).
;;   bench/run.sh executors 60000
(ns executors
  (:import [java.util.concurrent Executors TimeUnit CountDownLatch Callable]))

;; n trivial tasks at a growing pool, drained through shutdown/awaitTermination so
;; that nothing per-task is added to the measurement but the dispatch itself.
(defn drain [n]
  (let [ex (Executors/newCachedThreadPool)
        c (atom 0)
        f (fn [] (swap! c inc))]
    (.execute ex f)                                     ; one worker up first
    (dotimes [_ n] (.execute ex f))
    (.shutdown ex)
    (.awaitTermination ex 120 TimeUnit/SECONDS)
    @c))

;; submit one, wait for its value, repeat: a full handoff each way per task.
(defn round-trip [n]
  (let [ex (Executors/newCachedThreadPool)
        one (fn [] 1)
        total (loop [i 0 acc 0]
                (if (< i n)
                  (recur (inc i) (+ acc (long (.get (.submit ex ^Callable one)))))
                  acc))]
    (.shutdownNow ex)
    total))

;; k tasks that each block until the last of them has started, so the pool has to
;; grow to k threads before the latch can fall.
(defn ramp [k]
  (let [ex (Executors/newCachedThreadPool)
        latch (CountDownLatch. k)
        go (promise)]
    (dotimes [_ k] (.execute ex (fn [] (.countDown latch) (deref go 60000 :timeout))))
    (.await latch 60 TimeUnit/SECONDS)
    (deliver go true)
    (.shutdown ex)
    (.awaitTermination ex 60 TimeUnit/SECONDS)
    k))

;; p producer threads sharing one pool, released together.
(defn contended [n p]
  (let [ex (Executors/newCachedThreadPool)
        c (atom 0)
        f (fn [] (swap! c inc))
        per (quot n p)
        start (CountDownLatch. 1)
        done (CountDownLatch. p)
        ts (mapv (fn [_] (Thread. (fn []
                                    (.await start)
                                    (dotimes [_ per] (.execute ex f))
                                    (.countDown done))))
                 (range p))]
    (.execute ex f)
    (doseq [t ts] (.start t))
    (.countDown start)
    (.await done)
    (.shutdown ex)
    (.awaitTermination ex 120 TimeUnit/SECONDS)
    @c))

(defn run [n]
  (+ (drain n)
     (round-trip (quot n 20))
     (ramp 64)
     (contended n 4)))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 60000)]
    (dotimes [_ 2] (run (quot n 4)))                     ; warmup
    (let [runs 3
          times (mapv (fn [_]
                        (let [t0 (System/nanoTime)
                              r (run n)
                              ms (/ (- (System/nanoTime) t0) 1000000.0)]
                          [ms r]))
                      (range runs))
          mss (mapv first times)
          mean (/ (reduce + mss) runs)]
      (println "executors n" n "result" (second (first times)))
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) mss))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
