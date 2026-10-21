(ns jolt.profile
  "Execution-count profiling, over Chez Scheme's compile-profile counters.

  Code compiled while instrumentation is on carries a counter on every
  expression, and the counters are read back here by Clojure file, line and
  function. The counts are exact, not sampled: a line that ran 1973 times says
  1973.

  Instrumentation is a compile-time switch. It applies to code compiled AFTER it
  is turned on, so turn it on and then load (or reload) what you want to
  measure:

    (require '[jolt.profile :as prof])
    (prof/instrument!)
    (require 'my.app :reload)
    (prof/instrument! false)   ; optional: stop instrumenting new code
    (prof/clear!)
    (my.app/run)
    (prof/report)

  Or for a whole run, set JOLT_PROFILE=1 and the report prints on stderr as the
  process exits:

    JOLT_PROFILE=1 jolt run -m my.app

  Only code jolt compiles at runtime is instrumented: your namespaces and the
  libraries they load from source. The runtime and the stdlib that ships
  compiled in the jolt binary are not, so a call into clojure.core counts as
  one evaluation of the calling expression. While instrumentation is on,
  namespaces load from source rather than from the AOT cache, and the code it
  compiles is slower than uninstrumented code. Counters are not atomic: code
  running on several threads at once may lose increments.

  Two numbers describe a line or a fn:

    :hits   how many times it ran. For a fn this is its most-run line, which is
            its call count unless it loops.
    :evals  how many expressions it evaluated in all, which is the closest
            thing to how much work it did.

  `measure` is separate from the counters: it reports the time, allocation and
  collector work of evaluating its body."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [jolt.host :as host]))

(defn instrument!
  "Turn on instrumentation for code compiled from now on, or with false turn it
  off. Code already compiled keeps its counters either way. Returns true;
  throws when the host cannot instrument."
  ([] (instrument! true))
  ([on?]
   (if (host/profile-instrument! (boolean on?))
     true
     (throw (ex-info "jolt.profile: this host has no compile-profile counters"
                     {:host :unsupported})))))

(defn instrumenting?
  "True while code being compiled is instrumented."
  []
  (boolean (host/profile-instrumenting?)))

(defn clear!
  "Reset every counter to zero."
  []
  (host/profile-clear!)
  nil)

(defn- same-file? [a b]
  (and (string? a) (string? b)
       (or (= a b) (str/ends-with? a (str "/" b)) (str/ends-with? b (str "/" a)))))

;; [file line] -> {:hits :evals :fn-hits :fn-evals :owner :form-line}. A counter
;; is one expression of one compiled copy of a line: within a copy the line ran
;; as often as its most-run expression, and copies of the same line in different
;; forms (an inlined call, a redefinition) ran separately, so they add up. The
;; :fn- pair leaves out top-level code — what a form does as it loads, a defn's
;; own included — which ran on that line but belongs to no fn.
(defn- line-table [sites]
  (let [merge-copy (fn [r n top?]
                     (cond-> (-> r
                                 (update :max (fnil max 0) n)
                                 (update :sum (fnil + 0) n))
                       (not top?) (-> (update :fn-max (fnil max 0) n)
                                      (update :fn-sum (fnil + 0) n))))
        per-copy (reduce (fn [acc [file line n owner source form-line top?]]
                           (update acc [source file line]
                                   (fn [r]
                                     (-> (merge-copy r n top?)
                                         (assoc :owner (or owner (:owner r))
                                                :form-line form-line)))))
                         {} sites)
        add (fnil + 0)]
    (reduce-kv (fn [acc [_ file line] r]
                 (update acc [file line]
                         (fn [t]
                           {:hits (add (:hits t) (:max r))
                            :evals (add (:evals t) (:sum r))
                            :fn-hits (add (:fn-hits t) (:fn-max r 0))
                            :fn-evals (add (:fn-evals t) (:fn-sum r 0))
                            :owner (or (:owner r) (:owner t))
                            :form-line (or (:form-line r) (:form-line t))})))
               {} per-copy)))

;; file -> defs sorted by line, each [fqn line]
(defn- defs-by-file [files]
  (->> (host/profile-defs (vec files))
       (group-by second)
       (reduce-kv (fn [m file ds] (assoc m file (sort-by second (map (fn [[q _ l]] [q l]) ds))))
                  {})))

;; The def a line belongs to: the last one that starts at or after the top-level
;; form the line came from and at or before the line. None means top-level code.
(defn- owning-def [defs form-line line]
  (when (and form-line line)
    (last (filter (fn [[_ l]] (<= form-line l line)) defs))))

(defn- rows []
  (let [table (line-table (host/profile-sites))
        defs (defs-by-file (distinct (keep first (keys table))))]
    (for [[[file line] {:keys [hits evals fn-hits fn-evals owner form-line]}] table
          :when (pos? evals)]
      (let [d (when (and (pos? fn-evals) (not owner))
                (owning-def (get defs file) form-line line))
            f (when (pos? fn-evals) (or owner (first d)))]
        {:file file :line line :hits hits :evals evals
         :fn (some-> f symbol)
         :fn-hits fn-hits :fn-evals fn-evals
         :def-line (second d)}))))

(defn line-counts
  "Every instrumented line that ran, most-run first, as maps of :file, :line,
  :hits (times the line ran), :evals (expressions it evaluated) and :fn (the
  symbol of the fn it is in, or nil for top-level code)."
  []
  (->> (rows)
       (map #(dissoc % :def-line :fn-hits :fn-evals))
       (sort-by (juxt (comp - :hits) :file :line))))

(defn fn-counts
  "Every instrumented fn that ran, most work first, as maps of :fn, :file,
  :line (where it is defined), :hits (its most-run line: the call count unless
  it loops) and :evals (expressions evaluated in its body)."
  []
  (->> (rows)
       (filter :fn)
       (group-by :fn)
       (map (fn [[f rs]]
              {:fn f
               :file (:file (first rs))
               :line (or (some :def-line rs) (apply min (keep :line rs)))
               :hits (apply max (map :fn-hits rs))
               :evals (reduce + (map :fn-evals rs))}))
       (sort-by (juxt (comp - :evals) (comp str :fn)))))

(defn- source-lines [file]
  (try
    (let [f (io/file file)
          src (cond (.exists f) f
                    :else (io/resource file))]
      (when src (vec (str/split-lines (slurp src)))))
    (catch Exception _ nil)))

(defn- pad-left [s n]
  (let [s (str s)] (str (apply str (repeat (- n (count s)) \space)) s)))

(defn- pad-right [s n]
  (let [s (str s)] (str s (apply str (repeat (- n (count s)) \space)))))

(defn- location [{:keys [file line]}]
  (str (or file "NO_SOURCE_FILE") (when line (str ":" line))))

(defn report
  "Print the most-run fns and lines. Options:

    :limit  how many rows of each table (default 20)"
  ([] (report {}))
  ([{:keys [limit] :or {limit 20}}]
   (let [fns (take limit (fn-counts))
         lines (take limit (line-counts))
         sources (memoize source-lines)]
     (if (empty? lines)
       (println "jolt.profile: no instrumented code has run")
       (do
         (println "jolt.profile: fns by work")
         (println (str (pad-left "evals" 12) (pad-left "hits" 12) "  fn"))
         (doseq [{:keys [evals hits] :as r} fns]
           (println (str (pad-left evals 12) (pad-left hits 12) "  "
                         (pad-right (:fn r) 32) " " (location r))))
         (println)
         (println "jolt.profile: lines by hits")
         (println (str (pad-left "hits" 12) "  line"))
         (doseq [{:keys [file line hits] :as r} lines]
           (let [text (when (and file line) (get (sources file) (dec line)))]
             (println (str (pad-left hits 12) "  " (pad-right (location r) 40)
                           (when text (str "  " (str/trim text))))))))))))

(defn annotate
  "Print the source of file with each line's hit count in the margin. file is
  the path the code was loaded from, or its classpath-relative name."
  [file]
  (let [hits (into {} (for [r (line-counts) :when (same-file? (:file r) file)]
                        [(:line r) (:hits r)]))
        lines (or (source-lines file)
                  (throw (ex-info (str "jolt.profile: cannot read " file) {:file file})))
        width (max 6 (count (str (apply max 0 (vals hits)))))]
    (doseq [[i text] (map-indexed vector lines)]
      (println (str (pad-left (get hits (inc i) "") width) " | " text)))))

(defn report-at-exit
  "The JOLT_PROFILE exit hook: the report, on stderr."
  []
  (host/profile-instrument! false)
  (binding [*out* *err*]
    (report)
    (flush)))

(defn stats*
  "One reading of the process's time, allocation and collector counters, as a
  map of nanos and bytes. `measure` takes one on each side of its body."
  []
  (let [[cpu real gcs gc-cpu _gc-real _gc-bytes allocated] (host/profile-stats)]
    {:cpu-nanos cpu :real-nanos real :gc-count gcs :gc-cpu-nanos gc-cpu
     :allocated-bytes allocated}))

(defn- ms [nanos] (/ (double nanos) 1e6))

(defn measure*
  "Call f with no arguments and return a map of its :result with the :real-ms
  and :cpu-ms it took, the :allocated-bytes it allocated, and the :gc-count
  collections and :gc-ms of collector cpu time that ran meanwhile."
  [f]
  (let [before (stats*)
        result (f)
        after (stats*)
        d #(- (% after) (% before))]
    {:result result
     :real-ms (ms (d :real-nanos))
     :cpu-ms (ms (d :cpu-nanos))
     :allocated-bytes (d :allocated-bytes)
     :gc-count (d :gc-count)
     :gc-ms (ms (d :gc-cpu-nanos))}))

(defmacro measure
  "Evaluate body and return a map of its :result with the :real-ms and :cpu-ms
  it took, the :allocated-bytes it allocated, and the :gc-count collections and
  :gc-ms of collector cpu time that ran meanwhile."
  [& body]
  `(measure* (fn [] ~@body)))
