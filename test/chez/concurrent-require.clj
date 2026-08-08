;; test/chez/concurrent-require.clj — two threads requiring one namespace.
;;
;; Nothing used to serialize load-namespace*, so both threads passed the
;; loaded-ns check and both ran the target's top-level forms, double-running
;; every def and side effect in it. Worse, the mark-before-load that terminates a
;; require CYCLE marks the namespace loaded BEFORE its forms run, so to a second
;; thread it read as fully loaded while it was still half-built — a require that
;; returns having defined nothing.
;;
;; The loader now follows JLS 12.4.2, the JVM's class-initialization procedure,
;; per namespace: in progress by another thread means block until notified, in
;; progress by this thread means complete normally (the cycle break, which is
;; what mark-before-load already did).
;;
;; Two properties, and the second is the one that mattered:
;;   A. the target's top level ran EXACTLY once, however many threads required it
;;   B. every thread, on return from its require, saw the LAST form in the file
;;
;; Run: jolt run test/chez/concurrent-require.clj  (wired into smoke.sh)

(ns concurrent-require)

(def n-threads 8)
(def tmp-root (str "/tmp/jolt-ldrtest-" (System/currentTimeMillis)))

;; The target. defonce keeps the SAME atom across a second load while the swap!
;; below it runs again, so the counter reads 2 if the file was loaded twice — it
;; measures double-loading directly rather than inferring it. `sentinel` is the
;; last form in the file on purpose: a thread that returned from require while
;; another was still loading would not see it. The loop widens the window.
(def target-src
  (str "(ns ldrtest.target)\n"
       "(defonce counter (atom 0))\n"
       "(swap! counter inc)\n"
       "(def slow (reduce + (range 200000)))\n"
       "(def sentinel :loaded)\n"))

(defn- write-target! []
  (let [dir (str tmp-root "/ldrtest")]
    (.mkdirs (java.io.File. dir))
    (spit (str dir "/target.clj") target-src)))

(defn -main []
  (write-target!)
  (jolt.host/set-source-roots! (vec (cons tmp-root (jolt.host/source-roots))))
  (let [;; every thread waits on this so they all enter require together —
        ;; without it the first finishes before the rest start and there is no race
        go? (atom false)
        saw (atom [])
        errs (atom [])
        fs (doall
             (for [_ (range n-threads)]
               (future
                 (while (not @go?) (Thread/sleep 1))
                 (try
                   (require 'ldrtest.target)
                   ;; resolved AFTER require returns: property B
                   (swap! saw conj (some? (resolve 'ldrtest.target/sentinel)))
                   (catch Throwable e
                     (swap! errs conj (str (.getMessage e))))))))]
    (reset! go? true)
    (doseq [f fs] (deref f))
    (let [loads (deref @(resolve 'ldrtest.target/counter))
          sentinels @saw
          failures (cond-> []
                     (seq @errs)
                     (conj (str "requires threw: " (pr-str @errs)))
                     (not= 1 loads)
                     (conj (str "the target's top level ran " loads
                                " times, expected 1"))
                     (not= n-threads (count sentinels))
                     (conj (str "only " (count sentinels) " of " n-threads
                                " threads completed their require"))
                     (not (every? true? sentinels))
                     (conj (str (count (remove true? sentinels)) " of " n-threads
                                " threads returned from require before the"
                                " namespace's last form had run")))]
      ;; the temp root is per-run (currentTimeMillis), so clean it up rather than
      ;; leave one behind on every smoke run
      (doseq [p [(str tmp-root "/ldrtest/target.clj") (str tmp-root "/ldrtest") tmp-root]]
        (try (.delete (java.io.File. p)) (catch Throwable _ nil)))
      (if (seq failures)
        (do (doseq [f failures] (println "FAIL:" f))
            (println "CONCURRENT-REQUIRE FAILED")
            (System/exit 1))
        (println "CONCURRENT-REQUIRE OK" n-threads "threads, 1 load")))))

(-main)
