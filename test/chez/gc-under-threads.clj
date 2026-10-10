;; System/gc while another thread computes: the full collection must happen (a
;; weakly held object clears), not degrade to a no-op because the other thread
;; was active when (collect) was tried.
(let [stop (atom false)
      worker (future (loop [i 0] (if @stop i (recur (inc i)))))
      wr (java.lang.ref.WeakReference. (vec (range 1000)))]
  (Thread/sleep 50)
  (System/gc)
  (let [cleared (nil? (.get wr))]
    (reset! stop true)
    @worker
    (println "cleared" cleared)
    (shutdown-agents)))
