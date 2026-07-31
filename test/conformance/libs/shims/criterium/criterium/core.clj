;; criterium.core stub, for conformance runs only.
;;
;; Selmer's test/selmer/benchmark.clj requires criterium and calls quick-bench.
;; That namespace is excluded from the run (it benchmarks, it does not test), but
;; core_test has a top-level (require '[selmer.benchmark :as sb]) and reads
;; selmer.benchmark/user, so the namespace still has to COMPILE or the whole of
;; core_test is a load-fail.
;;
;; Real criterium is a measurement harness built on JVM timing and GC internals;
;; nothing here needs it to measure anything. The macros expand to the expression
;; and nil, so the benchmark bodies are still compiled — a typo in one is still an
;; error — but nothing is run or timed.
(ns criterium.core)

(defmacro quick-bench [expr & _opts] `(do ~expr nil))
(defmacro bench [expr & _opts] `(do ~expr nil))
(defmacro quick-benchmark [expr & _opts] `(do ~expr nil))
(defmacro benchmark [expr & _opts] `(do ~expr nil))
(defmacro with-progress-reporting [expr] expr)

(defn report-result [& _] nil)
(defn estimated-overhead! [& _] nil)
