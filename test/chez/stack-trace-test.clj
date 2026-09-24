;; Thread.getStackTrace and java.lang.StackTraceElement. The frames come from the
;; same reconstruction an uncaught error's backtrace uses: the live continuation,
;; plus the TCO-erased callers the callsite tables can name. Class names follow
;; the JVM's ns$fn munging, which is what callers parse (test.check's
;; clojure-test reporter walks the stack for the assertion's file:line).
;;
;; Where the JVM keeps a frame jolt cannot recover — a caller erased by a tail
;; call through a dynamic dispatch, with nothing static pointing at it — the
;; frame is left out rather than guessed. These rows only pin frames jolt does
;; name, in the JVM's order.
;;
;; Prints the STACK-TRACE OK / FAIL sentinel smoke.sh greps.
(ns stack-trace-test
  (:require [clojure.string :as str]))

(def ^:private fails (atom []))
(def ^:private passes (atom 0))

(defn- ok= [got want label]
  (if (= got want)
    (swap! passes inc)
    (swap! fails conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(defn- own-frames
  "This namespace's frames, as [class file] pairs, innermost first."
  [elems]
  (->> elems
       (map (fn [e] [(.getClassName e) (.getFileName e)]))
       (filter (fn [[c _]] (str/starts-with? c "stack_trace_test$")))
       vec))

;; The stack read in a non-tail position, as callers do: its frame stays live.
(defn- here [] (let [st (.getStackTrace (Thread/currentThread))] st))

;; --- non-tail and tail callers ---------------------------------------------------
(defn- inner [] (here))
(defn- middle [] (let [r (inner)] r))
(defn- outer-tail [] (middle))
(defn- probe-chain [] (let [st (outer-tail)] st))

;; inner and outer-tail are erased by their tail calls; the callsite tables name
;; both, between the live frames around them
(let [st (probe-chain)]
  (ok= (mapv first (own-frames st))
       ["stack_trace_test$here" "stack_trace_test$inner" "stack_trace_test$middle"
        "stack_trace_test$outer_tail" "stack_trace_test$probe_chain"]
       "TCO-erased callers are reconstructed, in order")
  (ok= (vec (StackTraceElement->vec (first st)))
       ["java.lang.Thread" "getStackTrace" "Thread.java" -1]
       "the first element is Thread.getStackTrace itself, as on the JVM")
  (ok= (set (map second (own-frames st))) #{"stack-trace-test.clj"}
       "a frame's file is the source file's base name")
  (ok= (every? pos? (map (fn [e] (.getLineNumber e))
                         (filter (fn [e] (str/starts-with? (.getClassName e) "stack_trace_test$"))
                                 st)))
       true
       "a mapped frame carries its line")
  (ok= (set (map (fn [e] (.getMethodName e)) (rest st))) #{"invoke"}
       "a Clojure frame's method is invoke"))

;; the stack read in a TAIL position: that fn's frame is gone by the time the
;; host call runs, and the site it stored names it
(defn- here-tail [] (.getStackTrace (Thread/currentThread)))
(defn- via-tail [] (let [st (here-tail)] st))
(ok= (mapv first (own-frames (via-tail)))
     ["stack_trace_test$here_tail" "stack_trace_test$via_tail"]
     "a fn that read the stack in tail position names itself")

;; --- a caller erased through apply, under a try ------------------------------------
;; The JVM keeps fail and runner; jolt erased both (apply is a tail call, and the
;; try's guard is runner's). The most recent tail site names fail, and runner's
;; try body registers fail as runner's exit, so both come back.
(defn- checking [f]
  (let [conform! (fn [x] (if (= x :bad) (let [st (here)] st) x))]
    (fn [& args] (let [r (conform! (first args))] (if (= :bad (first args)) r (apply f args))))))
(def ^:private checked (checking (fn [& a] a)))
(defn- fail [& args] (apply checked args))
(defn- runner [] (try (fail :bad) (catch Exception e nil)))
(defn- probe-runner [] (let [st (runner)] st))

(ok= (mapv first (own-frames (probe-runner)))
     ["stack_trace_test$here" "stack_trace_test$checking$fn__0"
      "stack_trace_test$checking$fn__1" "stack_trace_test$fail" "stack_trace_test$runner"
      "stack_trace_test$probe_runner"]
     "anonymous fns are named ns$def$fn__n; an apply-erased caller and a try wrapper come back")

;; --- StackTraceElement as a value ---------------------------------------------
(let [e (StackTraceElement. "a.b$c" "invoke" "c.clj" 7)]
  (ok= [(.getClassName e) (.getMethodName e) (.getFileName e) (.getLineNumber e)]
       ["a.b$c" "invoke" "c.clj" 7]
       "the constructor and accessors")
  (ok= (str e) "a.b$c.invoke(c.clj:7)" "toString is class.method(file:line)")
  (ok= (str (StackTraceElement. "a.b$c" "invoke" "c.clj" -1)) "a.b$c.invoke(c.clj)"
       "an unknown line leaves the line out")
  (ok= (str (StackTraceElement. "a.b$c" "invoke" nil -1)) "a.b$c.invoke(Unknown Source)"
       "an unknown file reads Unknown Source")
  (ok= (= e (StackTraceElement. "a.b$c" "invoke" "c.clj" 7)) true "equal elements are =")
  (ok= (= (hash e) (hash (StackTraceElement. "a.b$c" "invoke" "c.clj" 7))) true
       "equal elements hash alike")
  (ok= (instance? StackTraceElement e) true "instance? StackTraceElement")
  (ok= (class e) StackTraceElement "(class e) is StackTraceElement"))

;; another thread's stack is not reachable from here
(let [t (Thread. (fn [] (Thread/sleep 200)))]
  (.start t)
  (ok= (count (.getStackTrace t)) 0 "another thread's stack is empty")
  (.join t))

(let [n @passes f @fails]
  (doseq [m f] (println "stack-trace FAIL " m))
  (println "STACK-TRACE-RESULT pass" n "fail" (count f))
  (println (if (zero? (count f)) "STACK-TRACE OK" "STACK-TRACE FAIL"))
  (flush))
