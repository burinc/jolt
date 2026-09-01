;; clojure.core.async.flow gate — the flow graph end to end on jolt, plus the
;; java.util.concurrent seams it stands on (deref of a Future, ExecutionException
;; from .get, instance? Executor, and the workload -> carrier mapping in
;; clojure.core.async.impl.dispatch).
;;
;; Run: bin/jolt run test/chez/flow-test.clj
(ns flow-test
  (:require [clojure.core.async :as async]
            [clojure.core.async.flow :as flow]
            [clojure.core.async.impl.dispatch :as dispatch]
            [jolt.fibers :as fib])
  (:import [java.util.concurrent Executor ExecutorService Future FutureTask
            Executors TimeUnit ExecutionException]))

(def failures (atom []))

;; announce BEFORE evaluating and flush: a check that parks and is never resumed
;; must name itself in the log rather than hang silently.
(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# (try ~got (catch Throwable t# [:threw (ex-message t#)])) w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; --- the j.u.c seams --------------------------------------------------------

(def pool (Executors/newCachedThreadPool))

(check-eq "ExecutorService is an Executor" (instance? Executor pool) true)
(check-eq "ExecutorService is an ExecutorService" (instance? ExecutorService pool) true)
(check-eq "FutureTask is a Future" (instance? Future (FutureTask. (fn [] 1))) true)
(check-eq "FutureTask is a Runnable" (instance? Runnable (FutureTask. (fn [] 1))) true)
(check-eq "submit's Future is a Future" (instance? Future (.submit pool (fn [] 1))) true)

;; deref of a Future — clojure.core/deref falls through to deref-future for
;; anything that is not IDeref, which neither of these is on the JVM either.
(check-eq "deref a submitted Future" @(.submit pool (fn [] 42)) 42)
(check-eq "deref a FutureTask"
          (let [ft (FutureTask. (fn [] 7))] (.execute pool ft) @ft) 7)
(check-eq "timed deref that completes" (deref (.submit pool (fn [] :v)) 2000 :timeout) :v)
(check-eq "timed deref that expires"
          (deref (.submit pool (fn [] (Thread/sleep 3000) :late)) 100 :timeout) :timeout)

;; a task's throw comes back as ExecutionException wrapping it (ASYNC-275)
(check-eq "get wraps a throw in ExecutionException"
          (try (.get (.submit pool (fn [] (throw (ex-info "boom" {})))) 2000 TimeUnit/MILLISECONDS)
               :no-throw
               (catch ExecutionException e (ex-message (ex-cause e))))
          "boom")
(check-eq "deref wraps a throw too"
          (try @(.submit pool (fn [] (throw (ex-info "bang" {}))))
               :no-throw
               (catch ExecutionException e (ex-message (ex-cause e))))
          "bang")

;; Thread(Runnable) accepts a FutureTask, which is a Runnable
(check-eq "Thread runs a FutureTask"
          (let [ft (FutureTask. (fn [] 5)) t (Thread. ft)]
            (.start t) (.join t) @ft)
          5)

;; --- the workload -> executor mapping ---------------------------------------

(doseq [w [:io :mixed :compute :core-async-dispatch]]
  (check-eq (str "executor-for " w " is an Executor")
            (instance? Executor (dispatch/executor-for w)) true))
(check-eq "executor-for rejects an unknown tag"
          (try (dispatch/executor-for :nope) :no-throw (catch Throwable _ :threw))
          :threw)
(check-eq "executor-for is stable per tag"
          (identical? (dispatch/executor-for :io) (dispatch/executor-for :io)) true)

;; :io really is a fiber — the task reports whether it is running on one.
(check-eq ":io runs its task on a fiber"
          (let [p (promise)]
            (.execute (dispatch/executor-for :io)
                      (fn [] (deliver p (fib/in-fiber?))))
            (deref p 2000 :timeout))
          true)
(check-eq ":mixed runs its task on a thread, not a fiber"
          (let [p (promise)]
            (.execute (dispatch/executor-for :mixed)
                      (fn [] (deliver p (fib/in-fiber?))))
            (deref p 2000 :timeout))
          false)

;; --- a flow, end to end -----------------------------------------------------

(def collected (atom []))

(defn source
  ([] {:params {:n "how many"} :outs {:out "the numbers"}})
  ([{:keys [n]}]
   (let [c (async/chan 16)]
     (async/thread (dotimes [i n] (async/>!! c (inc i))))
     {::flow/in-ports {:nums c}}))
  ([state _transition] state)
  ([state _in msg] [state {:out [msg]}]))

(defn doubler
  ([] {:ins {:in "numbers"} :outs {:out "doubled"} :signal-select #{:tick}})
  ([_] {})
  ([state _transition] state)
  ([state in msg]
   (when (= msg 3) (throw (ex-info "boom on 3" {:msg msg})))
   [state {:out [(if (= in :tick) [:tick msg] (* 2 msg))]}]))

(defn sink
  ([] {:ins {:in "doubled"}})
  ([_] {})
  ([state _transition] state)
  ([state _in msg] (swap! collected conj msg) [state nil]))

(def g (flow/create-flow
        {:procs {:src {:proc (flow/process #'source) :args {:n 5}}
                 :dbl {:proc (flow/process #'doubler)}
                 :snk {:proc (flow/process #'sink)}}
         :conns [[[:src :out] [:dbl :in]]
                 [[:dbl :out] [:snk :in]]]}))

(def chans (flow/start g))
(check-eq "start returns the report and error channels"
          (every? some? [(:report-chan chans) (:error-chan chans)]) true)
(flow/resume g)
(Thread/sleep 800)

;; 3 throws, so 1 2 4 5 double through and 3 goes to the error channel
(check-eq "messages flow through the graph" (sort @collected) [2 4 8 10])
(check-eq "a throwing step reports on the error channel"
          (let [[v _] (async/alts!! [(:error-chan chans) (async/timeout 500)])]
            [(::flow/pid v) (ex-message (::flow/ex v))])
          [:dbl "boom on 3"])
(check-eq "the process survived its step throwing"
          (::flow/status (flow/ping-proc g :dbl)) :running)

(check-eq "ping reaches every process" (sort (keys (flow/ping g))) [:dbl :snk :src])
(check-eq "ping-proc reports a count" (::flow/count (flow/ping-proc g :snk)) 4)

(flow/pause g)
(check-eq "pause takes" (::flow/status (flow/ping-proc g :snk)) :paused)
(flow/resume g)
(check-eq "resume takes" (::flow/status (flow/ping-proc g :snk)) :running)

;; inject returns a Future, which deref waits on
(check-eq "inject puts a message on an input"
          (do @(flow/inject g [:dbl :in] [100])
              (Thread/sleep 300)
              (some #{200} @collected))
          200)
(check-eq "inject casts to a signal-selecting process"
          (do @(flow/inject g [::flow/cast :tick] [:ping])
              (Thread/sleep 300)
              (some #{[:tick :ping]} @collected))
          [:tick :ping])

(check-eq "the flow datafies" (map? (clojure.datafy/datafy g)) true)
(check-eq "stop takes" (do (flow/stop g) true) true)

;; --- scale: more :io processes than there are carriers or pool workers ------
;; The point of putting :io on fibers. Each process holds its carrier only while
;; running, so the count here is bounded by memory rather than by threads; with a
;; bounded thread pool everything past the worker count never started at all.

(def reached (atom #{}))

(defn counter-node
  ([] {:params {:id "id"} :ins {:in "x"} :workload :io})
  ([{:keys [id]}] {:id id})
  ([state _transition] state)
  ([{:keys [id] :as state} _in _msg] (swap! reached conj id) [state nil]))

(let [n 200
      pids (map #(keyword (str "p" %)) (range n))
      big (flow/create-flow
           {:procs (into {} (map (fn [p] [p {:proc (flow/process #'counter-node)
                                             :args {:id p}}])
                                 pids))
            :conns []})]
  (flow/start big)
  (flow/resume big)
  (doseq [p pids] @(flow/inject big [p :in] [1]))
  (Thread/sleep 2000)
  (check-eq "200 :io processes all ran" (count @reached) n)
  (flow/stop big))

(if (empty? @failures)
  (do (println "FLOW-TEST OK") (flush) (System/exit 0))
  (do (doseq [f @failures] (println "FAIL:" f))
      (flush)
      (System/exit 1)))
