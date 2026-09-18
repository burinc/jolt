;; string-ops-unhinted — the twin of `string-ops` with the declared type tags
;; removed. Same phases, same calls, same sizes; no `^String` on a target and no
;; `^clojure.lang.Keyword` on a keyword.
;;
;; Inference still proves what it can — `scan-proven` builds its own string, and a
;; method whose return type is known keeps proving down a chain — which is the
;; point: this row is what a user gets when they write no hints at all, not a
;; hypothetical worst case. What it loses is every proof that came from a DECLARED
;; tag, so `scan-hinted`, `direct-methods`, `core-over-strings` and `kw-parts`
;; drop to the generic dispatcher.
;;
;; Kept as its own suite entry because ci/bench-gate.sh compares a ratio PER
;; BENCHMARK, so the declared-tag path and the no-tag path need two rows for a
;; regression in one to be visible when the other improves.
;;
;; A transcription of string_ops.clj — edit the two together; what differs is
;; exactly the tags. The phase names are kept verbatim for that reason, so
;; `scan-hinted` here is the same function with nothing declared on it: the names
;; identify which phase a row is comparable to, not what this file proves.
;;
;; Portable Clojure (jolt + JVM Clojure). Without the tags the JVM reflects on
;; every interop call here, which is the reference this is measured against.
;;   bench/run.sh string-ops-unhinted 100000
(ns string-ops-unhinted
  (:require [clojure.string :as str]))

(def entity "some.qualified/entity-name")
(def words (mapv (fn [i] (str "word" i)) (range 16)))
(def kws (mapv (fn [i] (keyword "bench" (str "key" i))) (range 16)))

;; --- hinted String target -----------------------------------------------------
(defn scan-hinted [s]
  (unchecked-add
   (unchecked-add (.indexOf s ".") (.length s))
   (unchecked-add (if (.startsWith s "some") 1 0)
                  (count (.substring s 1 5)))))

;; --- unhinted: the target must be PROVEN a string by inference ---------------
(defn scan-proven [s]
  (let [t (str s "!")]
    (unchecked-add
     (unchecked-add (.indexOf t "/") (if (.endsWith t "!") 1 0))
     (count (.toLowerCase t)))))

;; --- chained interop: every target but the first is an interop RESULT ---------
;; Only provable once a method's return type is known; before that each outer call
;; carried a string? test and a dispatch arm.
(defn chain-proven [s]
  (unchecked-add
   (.length (.toUpperCase (.trim s)))
   (let [t (.substring s 0 8)]                  ; let-bound interop result
     (unchecked-add (.length (.toLowerCase t))
                    (if (.startsWith (.trim t) "some") 1 0)))))

;; --- methods that had no direct form: they fell to the generic dispatcher -----
(defn direct-methods [a b]
  (unchecked-add
   (unchecked-add (if (.equals a b) 1 0) (if (.equalsIgnoreCase a b) 1 0))
   (unchecked-add (.lastIndexOf a "e")
                  (unchecked-add (if (.isBlank a) 1 0) (.compareTo a b)))))

;; --- clojure.core over PROVEN strings ----------------------------------------
(defn core-over-strings [s t]
  (unchecked-add
   (unchecked-add (count s) (count t))
   (unchecked-add (count (str s t)) (count (str s "-" t)))))

;; --- the clojure.string layer over arguments that are already strings --------
(defn strfns [s]
  (unchecked-add
   (unchecked-add (count (str/upper-case s)) (count (str/lower-case s)))
   (unchecked-add (if (str/starts-with? s "some") 1 0)
                  (if (str/includes? s "entity") 1 0))))

(defn join-words [ws] (count (str/join "," ws)))

;; --- hinted Keyword target ----------------------------------------------------
(defn kw-parts [k]
  (unchecked-add (count (.getName k))
                 (count (.getNamespace k))))

(defn kw-core [k]
  (unchecked-add (count (name k)) (count (namespace k))))

(defn walk-kws [ks]
  (reduce (fn [acc k] (unchecked-add acc (unchecked-add (kw-parts k) (kw-core k))))
          0 ks))

(defn run [iters]
  (let [s entity
        other "some.qualified/other-name"]
    (loop [i 0 acc 0]
      (if (< i iters)
        (recur (inc i)
               (unchecked-add
                acc
                (unchecked-add
                 (unchecked-add
                  (unchecked-add (scan-hinted s) (scan-proven s))
                  (unchecked-add (chain-proven s)
                                 (unchecked-add (direct-methods s other)
                                                (core-over-strings s other))))
                 (unchecked-add
                  (unchecked-add (strfns s) (join-words words))
                  (walk-kws kws)))))
        acc))))

(defn -main [& args]
  (let [iters (if (seq args) (Integer/parseInt (first args)) 100000)]
    (dotimes [_ 2] (run (quot iters 4)))                 ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/currentTimeMillis)
                           r (run iters)
                           el (- (System/currentTimeMillis) t0)]
                       (when (zero? r) (println "unexpected zero"))
                       el))
                   (range runs))]
      (println "runs:" ts)
      (println "mean:" (quot (reduce + ts) runs) "ms"))))
