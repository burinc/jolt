;; jolt.fibers pools gate — carrier pools besides the default one, so work that
;; pins its carrier (a blocking foreign call) or hogs it can be kept apart from
;; the fibers that must stay responsive. Run:
;; bin/jolt run test/chez/jolt-fiber-pools-test.clj (smoke.sh greps for
;; "JOLT-FIBER-POOLS-TEST OK").
(ns jolt-fiber-pools-test)

(require '[jolt.fibers :as fib])
(require '[jolt.ffi :as ffi])
(require '[clojure.core.async :as a])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

(def ^:dynamic *conveyed* :root)

(defn- throws? [f] (try (f) false (catch Exception _ true)))

;; making a pool
(let [p (fib/pool {:name :io :size 2})]
  (check-eq "pool? on a pool" (fib/pool? p) true)
  (check-eq "pool? on not-a-pool" [(fib/pool? nil) (fib/pool? 1)] [false false])
  (check-eq "pool-name" (fib/pool-name p) :io)
  (check-eq "pool-size" (fib/pool-size p) 2)
  (check-eq "spawn into a pool joins its value"
            (fib/join (fib/spawn (fn [] (+ 1 2)) {:pool p}))
            3)
  (check-eq "pool-of a fiber in the pool"
            (identical? p (fib/pool-of (fib/spawn (fn [] nil) {:pool p})))
            true)
  (check-eq "pool-of a default fiber is nil"
            (fib/pool-of (fib/spawn (fn [] nil)))
            nil)
  (check-eq "spawn with no :pool is the default pool"
            (fib/pool-of (fib/spawn (fn [] nil) {}))
            nil)
  (check-eq "current-fiber inside a pool fiber is its handle"
            (let [f (fib/spawn (fn [] (fib/pool-of (fib/current-fiber))) {:pool p})]
              (identical? p (fib/join f)))
            true)
  ;; a fiber spawned from a pool fiber goes where it is told: the default
  ;; pool unless it names one
  (check-eq "a child spawned in a pool fiber defaults to the default pool"
            (fib/join (fib/spawn (fn [] (fib/pool-of (fib/join (fib/spawn (fn [] (fib/current-fiber)))))) {:pool p}))
            nil)
  (check-eq "bindings convey into a pool fiber"
            (fib/join (binding [*conveyed* :bound] (fib/spawn (fn [] *conveyed*) {:pool p})))
            :bound)
  (check-eq "a throw in a pool fiber rethrows from join"
            (try (fib/join (fib/spawn (fn [] (throw (ex-info "boom" {:k 1}))) {:pool p}))
                 :no-throw
                 (catch Exception e (ex-data e)))
            {:k 1})
  ;; channels, kills and interrupts cross pools
  (let [c (a/chan)
        f (fib/spawn (fn [] (a/<!! c)) {:pool p})]
    (a/>!! c :across)
    (check-eq "a pool fiber takes from a default-pool put" (fib/join f) :across))
  (let [c (a/chan)
        f (fib/spawn (fn [] (try (a/<!! c) (catch Exception e (ex-message e)))) {:pool p})]
    (Thread/sleep 20)
    (fib/interrupt! f (ex-info "interrupted" {}))
    (check-eq "interrupt! reaches a parked pool fiber" (fib/join f) "interrupted"))
  (let [c (a/chan)
        f (fib/spawn (fn [] (try (a/<!! c) :caught (catch Exception _ :caught))) {:pool p})]
    (Thread/sleep 20)
    (fib/kill! f (ex-info "killed" {}))
    (check-eq "kill! ends a parked pool fiber past its catch"
              (try (fib/join f) :survived (catch Exception e (ex-message e)))
              "killed"))
  (check-eq "many fibers over the pool's carriers all finish"
            (reduce + (map fib/join (mapv (fn [i] (fib/spawn (fn [] (fib/yield) i) {:pool p})) (range 100))))
            4950)
  (let [c (a/chan)
        f (fib/spawn (fn [] (a/<!! c)) {:pool p})]
    (Thread/sleep 20)
    (fib/shutdown! p)
    (a/>!! c :after-shutdown)
    (check-eq "a fiber parked in a shut-down pool still finishes"
              (fib/join f 2000 :stranded)
              :after-shutdown))
  (check-eq "spawn into a shut-down pool throws"
            (throws? (fn [] (fib/spawn (fn [] nil) {:pool p})))
            true)
  (check-eq "shutdown! twice is harmless" (do (fib/shutdown! p) :ok) :ok))

(check-eq "pool size must be positive"
          [(throws? (fn [] (fib/pool {:size 0}))) (throws? (fn [] (fib/pool {:size -1})))
           (throws? (fn [] (fib/pool {:size :x})))]
          [true true true])
(check-eq ":pool must be a pool"
          (throws? (fn [] (fib/spawn (fn [] nil) {:pool :io})))
          true)
(check-eq "a pool without a size gets the machine's"
          (let [p (fib/pool {})] (try (pos? (fib/pool-size p)) (finally (fib/shutdown! p))))
          true)

;; The point of a pool: a fiber in a blocking foreign call pins its carrier,
;; and every fiber queued on that carrier waits with it, but fibers in another
;; pool do not. Both pools have one carrier, so placement is certain.
(when-not (re-find #"(?i)windows" (str (System/getProperty "os.name")))
  (ffi/defcfn c-usleep "usleep" [:int] :int)
  (let [blocking (fib/pool {:name :blocking :size 1})
        other (fib/pool {:name :other :size 1})
        order (atom [])
        started (promise)
        b (fib/spawn (fn [] (deliver started true) (c-usleep 300000) (swap! order conj :blocker-done))
                     {:pool blocking})
        _ @started
        same (fib/spawn (fn [] (swap! order conj :same-pool)) {:pool blocking})
        apart (fib/spawn (fn [] (swap! order conj :other-pool)) {:pool other})]
    (mapv fib/join [b same apart])
    (check-eq "a pinned carrier holds its own pool's fibers, not another pool's"
              @order
              [:other-pool :blocker-done :same-pool])
    (fib/shutdown! blocking)
    (fib/shutdown! other)))

(if (empty? @failures)
  (println "JOLT-FIBER-POOLS-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-FIBER-POOLS-TEST FAILED:" (count @failures))))
