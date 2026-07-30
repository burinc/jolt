;; Library-conformance driver: replay third-party Clojure libraries' own
;; clojure.test suites on jolt and compare the tallies against the recorded
;; standings in manifest.edn.
;;
;; The library checkouts are NOT vendored — they are ordinary upstream clones
;; under $JOLT_CONFORMANCE_LIBS (default ../conformance-libraries). This gate is
;; therefore opt-in (`make libconformance`) and skips cleanly when the checkout
;; is absent. What lives in this repo is the recipe (which paths, which deps,
;; which namespaces) and the expected tally, so a jolt change that regresses a
;; library is caught here instead of being noticed months later.
;;
;; Usage:
;;   jolt run test/conformance/libs/run.clj [lib ...]      ; all, or the named ones
;;   JOLT_LIBCONF_UPDATE=1 jolt run ... > /dev/null        ; rewrite :expect tallies
(ns lib-conformance-driver
  (:require [clojure.edn :as edn]
            [clojure.string :as str]
            [jolt.process :as p]))

(def ^:private repo-root
  (or (System/getenv "JOLT_REPO_ROOT") (System/getProperty "user.dir")))

(def ^:private here (str repo-root "/test/conformance/libs"))

(def ^:private libs-root
  (or (System/getenv "JOLT_CONFORMANCE_LIBS")
      (str (.getParent (java.io.File. repo-root)) "/conformance-libraries")))

(def ^:private siblings-root
  ;; first-party jolt libraries (xml, time, db, ...) sit beside the jolt checkout
  (or (System/getenv "JOLT_SIBLING_LIBS")
      (.getParent (java.io.File. repo-root))))

;; Absolute: each child runs with :dir set to the library's own root, so a
;; relative JOLT_BIN (what the Makefile passes) would not resolve there.
(def ^:private jolt-bin
  (let [b (or (System/getenv "JOLT_BIN") "target/release/jolt")]
    (if (str/starts-with? b "/") b (str repo-root "/" b))))

;; ---------------------------------------------------------------- paths

(defn- exists? [p] (.exists (java.io.File. p)))

(defn- resolve-path
  "A manifest path is relative to the library's own root unless it starts with
  `@` (relative to the conformance-libraries root), `~` (a first-party jolt
  sibling library) or `/` (absolute)."
  [lib-root p]
  (cond
    (str/starts-with? p "/") p
    (str/starts-with? p "@") (str libs-root "/" (subs p 1))
    (str/starts-with? p "~") (str siblings-root "/" (subs p 1))
    :else (str lib-root "/" p)))

;; ---------------------------------------------------------------- ns discovery

;; The name in an `ns` form may sit behind metadata — `(ns ^{:doc "..."} the.name`
;; is how several contrib suites are written — so skip any leading ^{...} / ^:kw.
(def ^:private ns-form-re
  #"\(ns\s+(?:\^(?:\{[^}]*\}|[^\s]+)\s+)*([a-zA-Z][^\s\(\)\[\]{},;]*)")

(defn- ns-name-of [file]
  (let [src (slurp file)]
    (when-let [m (re-find ns-form-re src)]
      (second m))))

(defn- test-file?
  "Does this file define tests? Matches `deftest`/`defspec` however it is
  qualified — plenty of suites call it `t/deftest` through an alias rather than
  referring it in."
  [src]
  (boolean (re-find #"\(\s*(?:[\w.\-]+/)?(?:deftest|defspec)[\s\n]" src)))

(defn- walk-files [dir]
  (let [f (java.io.File. dir)]
    (if (.isDirectory f)
      (mapcat walk-files (map str (.listFiles f)))
      [dir])))

(defn- discover-nses
  "Every namespace under `test-paths` that defines tests, by its own ns form."
  [test-dirs]
  (->> test-dirs
       (filter exists?)
       (mapcat walk-files)
       (filter #(or (str/ends-with? % ".clj") (str/ends-with? % ".cljc")))
       (keep (fn [f]
               (let [src (slurp f)]
                 (when (test-file? src) (ns-name-of f)))))
       distinct
       sort))

;; ---------------------------------------------------------------- run one lib

(def ^:private result-re
  #"TOTAL tests=(-?\d+) pass=(-?\d+) fail=(-?\d+) error=(-?\d+) load-fail=(-?\d+)")

(defn- parse-total [out]
  (when-let [m (re-find result-re out)]
    (let [[_ t pa f e lf] m]
      {:tests (parse-long t) :pass (parse-long pa)
       :fail (parse-long f) :error (parse-long e) :load-fail (parse-long lf)})))

(defn- run-lib [{:keys [name root paths deps extra-deps nses exclude-nses timeout] :as entry}]
  (let [lib-root (str libs-root "/" (or root name))
        srcs (map #(resolve-path lib-root %) (or paths ["src" "test"]))
        deps (map #(resolve-path lib-root %) (or deps []))
        test-dirs (map #(resolve-path lib-root %) (:test-paths entry ["test"]))
        cp (vec (concat [(str here "/runner")] srcs deps))
        missing (remove exists? cp)
        nses (remove (set (or exclude-nses []))
                     (or nses (discover-nses test-dirs)))
        timeout-ms (* 1000 (or timeout 300))]
    (cond
      (seq missing) {:status :missing-paths :detail (vec missing)}
      (empty? nses) {:status :no-tests}
      :else
      (let [sdeps (cond-> {:paths cp} extra-deps (assoc :deps extra-deps))
            cmd (vec (concat [jolt-bin "-Sdeps" (pr-str sdeps)
                              "-m" "lib-conformance-run" (str timeout-ms)]
                             nses))
            r (apply p/sh {:out :string :err :string
                           :dir lib-root
                           :extra-env {"JOLT_NO_USER_DEPS" "1"}}
                     cmd)
            out (str (:out r) (:err r))]
        (merge {:status :ran :exit (:exit r) :out out :nses (vec nses)}
               (or (parse-total out) {:status :no-result}))))))

;; ---------------------------------------------------------------- reporting

(defn- worse? [{:keys [pass fail error load-fail]} exp]
  (or (< pass (:pass exp 0))
      (> fail (:fail exp 0))
      (> error (:error exp 0))
      (> load-fail (:load-fail exp 0))))

(defn- tally-str [{:keys [tests pass fail error load-fail]}]
  (str "tests=" tests " pass=" pass " fail=" fail " error=" error
       (when (and load-fail (pos? load-fail)) (str " load-fail=" load-fail))))

(defn -main [& args]
  (when-not (exists? libs-root)
    (println (str "SKIP: no library checkout at " libs-root
                  " (set JOLT_CONFORMANCE_LIBS)"))
    (System/exit 0))
  (let [manifest (edn/read-string (slurp (str here "/manifest.edn")))
        wanted (set args)
        entries (cond->> (:libs manifest)
                  (seq wanted) (filter #(wanted (:name %))))
        logdir (str repo-root "/target/libconformance")]
    (.mkdirs (java.io.File. logdir))
    (let [rows (doall
                 (for [{:keys [name skip expect] :as e} entries]
                   (if skip
                     (do (println (format "%-20s SKIP  %s" name skip))
                         {:name name :verdict :skip})
                     (let [r (run-lib e)]
                       (when (:out r)
                         (spit (str logdir "/" name ".log") (:out r)))
                       (case (:status r)
                         :missing-paths
                         (do (println (format "%-20s MISSING  %s" name
                                              (str/join " " (:detail r))))
                             {:name name :verdict :missing})
                         :no-tests
                         (do (println (format "%-20s NO-TESTS" name))
                             {:name name :verdict :no-tests})
                         :no-result
                         (do (println (format "%-20s NO-RESULT  exit=%s (see %s/%s.log)"
                                              name (:exit r) logdir name))
                             {:name name :verdict :fail})
                         (let [bad (and expect (worse? r expect))
                               better (and expect (> (:pass r) (:pass expect 0)))]
                           (println (format "%-20s %-6s %s%s"
                                            name
                                            (cond bad "WORSE" better "BETTER" :else "ok")
                                            (tally-str r)
                                            (if expect
                                              (str "   expected " (tally-str expect))
                                              "   (no recorded expectation)")))
                           {:name name :verdict (cond bad :fail better :better :else :ok)
                            :got (select-keys r [:tests :pass :fail :error :load-fail])}))))))
          bad (filter #(= :fail (:verdict %)) rows)]
      (println)
      (println (format "%d libraries: %d ok, %d better, %d regressed, %d skipped/missing"
                       (count rows)
                       (count (filter #(= :ok (:verdict %)) rows))
                       (count (filter #(= :better (:verdict %)) rows))
                       (count bad)
                       (count (filter #(#{:skip :missing :no-tests} (:verdict %)) rows))))
      (when (seq bad)
        (println "REGRESSED:" (str/join " " (map :name bad))))
      (System/exit (if (seq bad) 1 0)))))

;; run on load so `jolt run test/conformance/libs/run.clj [lib ...]` executes.
(apply -main *command-line-args*)
