;; test/chez/poller-registration.clj — a readiness registration must never be
;; lost. Run through jolt (wired into host/chez/smoke.sh).
;;
;; WHY THIS EXISTS. jolt.io-poller's poller thread drained its pending
;; registrations in TWO critical sections — read :pending, then clear it — so a
;; registration landing in between was erased before it ever reached the
;; kqueue/epoll set. That fd's readiness was then never reported and the fiber
;; waiting on it never resumed. The window is microseconds wide, so it presented
;; as one fiber out of eight failing to finish, once, in a `make fibers` sequence,
;; and never again in six isolated runs of that gate.
;;
;; The workload keeps registrations landing while the poller is mid-round: rounds
;; of fibers that all park on their own socket read, over and over, so some
;; registrations are bound to arrive during the drain. Unfixed this loses ~11% of
;; them (283 of 320); fixed it loses none. Every read is bounded by an alts!!
;; timeout, so a lost wakeup is a FAILURE and never a hang — and the run STOPS at
;; the first round that loses one, because otherwise every subsequent loss pays
;; that timeout again: the unfixed version took over eleven minutes to finish what
;; the fixed one does in under two seconds, and a gate that slow is its own
;; problem.
(require '[jolt.socket])
(require '[clojure.core.async :as a])

(def rounds 40)
(def per 8)

(defn- one-round [ss port]
  (let [clients (doall (for [_ (range per)] (java.net.Socket. "127.0.0.1" port)))
        srvs (doall (for [_ (range per)] (.getOutputStream (.accept ss))))
        outs (doall (for [c clients]
                      (binding [a/*go-backend* :fiber]
                        (a/go (let [b (byte-array 8)
                                    n (.read (.getInputStream c) b 0 8)]
                                (String. b 0 n "UTF-8"))))))]
    ;; let them all park before the data arrives, so every read registers
    (Thread/sleep 15)
    (doseq [s srvs] (.write s (.getBytes "x" "UTF-8") 0 1))
    (let [got (doall (for [o outs] (first (a/alts!! [o (a/timeout 2000)]))))]
      (doseq [c clients] (.close c))
      (count (filter #(= "x" %) got)))))

(let [ss (java.net.ServerSocket. 0)
      port (.getLocalPort ss)]
  (loop [r 0 acc 0]
    (cond
      (= r rounds)
      (println "POLLER-REGISTRATION OK" acc)

      :else
      (let [n (one-round ss port)]
        (if (< n per)
          (do (println (str "POLLER-REGISTRATION LOST " (- per n) " of " per
                            " readiness registrations in round " r))
              (System/exit 1))
          (recur (inc r) (+ acc n)))))))
