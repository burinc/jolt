;; scorecard.clj — render bench/README.md from bench/README.tmpl and the output
;; of one benchmark sitting: `bench/run.sh` (the AOT rows and `startup`) and
;; `bench/testcheck.sh` (the run-mode rows). A Selmer template, so the prose
;; lives in the template and this script only supplies the rows.
;;
;;   JOLT_BIN=target/release/jolt bench/run.sh > run.log
;;   JOLT_BIN=target/release/jolt bench/testcheck.sh > tc.log
;;   jolt run bench/scorecard.clj run.log tc.log --measured "Measured 2026-09-09 on …"
;;   jolt run bench/scorecard.clj run.log tc.log --measured "…" --print   # stdout only
;;
;; One same-sitting run is the contract — both logs from one machine in one
;; sitting, or the ratios mean nothing — so this refuses a partial one: every
;; bench in `run.sh --list` (plus `startup`) must have a row in the logs and a
;; description below, and a `jolt build FAILED` line anywhere stops it. Rows are
;; sorted by ratio (jolt ÷ JVM, two decimals under 1), AOT first, then
;; `startup`, then the run-mode rows in the harness's order.
;;
;; Selmer needs java.time, which jolt-lang/time provides; requiring jolt.time
;; ahead of it installs those classes. The first run needs ~/.m2 (or network).
(require 'jolt.deps)
(jolt.deps/add-deps '{:deps {io.github.jolt-lang/time {:git/tag "v0.0.8" :git/sha "33c5e9831c046cfcbe68bc0c9c33e92568eaebb1"}
                             selmer/selmer {:mvn/version "1.13.5"}}})
(require 'jolt.time)
(require '[selmer.parser :as selmer]
         '[selmer.util :as selmer-util]
         '[clojure.string :as str])

;; What each row measures — the table's last column. A bench without an entry
;; here is refused, so adding one to run.sh means saying what it is for.
(def descriptions
  {"fib" "recursion: call overhead + integer arith"
   "tak" "deep three-way self-recursion + integer arith"
   "loop-recur" "tight `loop`/`recur` with `mod`/`quot`/`bit-xor` per iteration"
   "mandelbrot" "pure float compute, no allocation or dispatch"
   "arrays" "primitive `double-array` throughput (hinted `aget`/`aset`)"
   "arrays-unhinted" "the same array code without type hints"
   "byte-arrays" "raw bytes in bulk: block copies, a drained stream, `String`↔`byte[]`, hinted `^bytes` access"
   "gc-arrays" "major-collection pause with a large typed array live (read jolt ms only, see below)"
   "mathfns" "`java.lang.Math` sqrt/sin/cos/log/pow/atan2 over doubles"
   "mathfns-unhinted" "the same math without type hints"
   "collections" "persistent map/vector churn + map/filter/take/reduce over the result"
   "vecops" "vector concat (`into`), `subvec` windows, split/rejoin (the RRB axis)"
   "seqs" "lazy-seq + HOF pipelines: `map`/`filter`/`reduce`, `every?`, `iterate`/`take`, `mapcat`"
   "lazy-threads" "lazy pipelines after a `Thread` has existed (cells claimed by CAS, no mutex per cell)"
   "apply-rest" "`apply` of `+ max min < <=` and a user variadic over a million-element rest (streamed, not materialized)"
   "sorted-access" "shape-answered reads: `count`/`drop` on a vector seq, `rseq`, `first` of a sorted map/set"
   "sorted-build" "`into` a sorted-map/sorted-set in and out of key order, `sorted-map-by`, replace-every-key (one tree walk per insert)"
   "nth-access" "`nth` on a vector, small and large, with and without a default"
   "transducers" "transducer pipelines (`comp` of `map`/`filter`/`take`)"
   "transients" "bulk map/set building through `into`, `assoc!`/`conj!`, `zipmap`/`frequencies`/`group-by`"
   "keyed-lookup" "hashing keywords/symbols/strings and looking them up in small maps"
   "hash-eq" "hashing vectors/maps/sets/records/seqs, collection-keyed lookups, `=` on equal and unequal collections"
   "literals" "constant map/vector/set literals and quoted forms in a fn body, boolean predicates (per-form constant pool)"
   "string-build" "`StringBuilder` in a loop and transducer-over-`join`"
   "string-ops" "`.indexOf`/`.startsWith`/`.substring`/`.toLowerCase` on hinted strings, `clojure.string`, keyword `.getName`"
   "string-ops-unhinted" "the same string interop without type hints"
   "char-scan" "`.charAt` per code point with the `int`/`long`/`unchecked-*` casts, a `case` state machine"
   "char-scan-unhinted" "the same scan without type hints"
   "printing" "`pr-str` over scalars and namespaced maps, `print` into a rebound `*out*`, `format` with numeric directives and flags"
   "mono-dispatch" "monomorphic protocol dispatch (devirt / inline cache can fire)"
   "dispatch" "megamorphic protocol dispatch"
   "binary-trees" "escaping short-lived records: allocation / GC pressure"
   "typed-records" "records with `^double`/`^long`/`^String` field types at construction and every read"
   "typed-records-unhinted" "the same records without field types"
   "stm" "ref creation, `dosync` `ref-set`/`alter`, `deref` in a loop"
   "executors" "`java.util.concurrent`: fire-and-forget enqueue, submit/get, growth to 64 blocking tasks, four producers on one pool"
   "compile-forms" "**compiling**, not running: `load-string` of 200 top-level defns and of one `deftest` holding 200 `is` forms"
   "startup" "a built hello-world, whole process from exec to exit, best of 7 (JVM: `java -cp … clojure.main -m hello`)"})

(def run-mode-descriptions
  {"mix-64" "SplitMix `mix-64`: 64-bit integer arithmetic (heap bignums past the 61-bit fixnum)"
   "deftype+protocol" "open-world deftype allocation + protocol dispatch"
   "split + rand-long" "the PRNG: bignum 64-bit arithmetic + dispatch"
   "gen/large-integer" "`gen/large-integer`: arithmetic + rose-tree generator machinery"
   "(gen/vector gen/large-integer)" "element generation + generator machinery"})

(defn- ratio-str [j v]
  (let [x (/ (Double/parseDouble j) (Double/parseDouble v))]
    (if (< x 1.0) (format "%.2f" x) (format "%.1f" x))))

(defn- parse-aot [text]
  (for [[_ name j v] (re-seq #"(?m)^(\S+)\s+jolt\s+([\d.]+) ms\s+jvm\s+([\d.]+) ms\s+\S+$" text)]
    {:name name :jolt j :jvm v :sort (/ (Double/parseDouble j) (Double/parseDouble v))}))

(defn- parse-run-mode [text]
  (for [[_ label n j v] (re-seq #"(?m)^(.+?)\s+x(\d+)\s+jolt\s+([\d.]+) ms\s+jvm\s+([\d.]+) ms\s+\S+$" text)]
    {:label (str/trim label) :n n :jolt j :jvm v}))

(defn- bench-names [dir]
  (let [src (slurp (java.io.File. dir "run.sh"))
        benches (second (re-find #"(?m)^BENCHES=\"(.*)\"$" src))]
    (conj (mapv #(subs % 0 (str/index-of % ":")) (str/split benches #" ")) "startup")))

(defn- die [& msg]
  (binding [*out* *err*] (println (apply str "scorecard.clj: " msg)))
  (System/exit 1))

(defn -main [& args]
  (let [[logs opts] (loop [as args logs [] opts {}]
                      (cond (empty? as) [logs opts]
                            (= "--measured" (first as)) (recur (nnext as) logs (assoc opts :measured (second as)))
                            (= "--print" (first as)) (recur (next as) logs (assoc opts :print true))
                            :else (recur (next as) (conj logs (first as)) opts)))
        _ (when (or (empty? logs) (str/blank? (:measured opts)))
            (die "usage: scorecard.clj RUN.log [TESTCHECK.log ...] --measured \"…\" [--print]"))
        dir (.getParentFile (.getCanonicalFile (java.io.File. *file*)))
        text (str/join "\n" (map slurp logs))
        _ (when-let [[_ b] (re-find #"(?m)^(\S+)\s+jolt build FAILED" text)]
            (die "the run has a build failure: " b))
        aot (parse-aot text)
        run-mode (parse-run-mode text)
        have (set (map :name aot))
        wanted (bench-names dir)
        missing-rows (remove have wanted)
        missing-desc (remove descriptions wanted)
        row (fn [{:keys [name jolt jvm]}]
              {:name name :ratio (ratio-str jolt jvm) :jolt jolt :jvm jvm :what (descriptions name)})]
    (when (seq missing-rows) (die "no row in the logs for: " (str/join ", " missing-rows)))
    (when (seq missing-desc) (die "no description for: " (str/join ", " missing-desc)))
    (when (empty? run-mode) (die "no run-mode rows (bench/testcheck.sh output) in the logs"))
    (doseq [{:keys [label]} run-mode]
      (when-not (run-mode-descriptions label) (die "no description for the run-mode row: " label)))
    (selmer-util/turn-off-escaping!)
    (let [md (selmer/render
              (slurp (java.io.File. dir "README.tmpl"))
              {:measured (:measured opts)
               :rows (map row (sort-by :sort (remove #(= "startup" (:name %)) aot)))
               :startup (row (first (filter #(= "startup" (:name %)) aot)))
               :run-rows (map (fn [{:keys [label n jolt jvm]}]
                                {:label label :n n :ratio (ratio-str jolt jvm) :jolt jolt :jvm jvm
                                 :what (run-mode-descriptions label)})
                              run-mode)})]
      (if (:print opts)
        (print md)
        (let [out (java.io.File. dir "README.md")]
          (spit out md)
          (println (str "wrote " out ": " (count aot) " AOT rows + " (count run-mode) " run-mode rows")))))))

(apply -main *command-line-args*)
