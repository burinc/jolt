;; spec_coverage.clj — generate the spec status dashboard (Appendix A of the
;; spec, `coverage.md` in the jolt-lang.github.io site under
;; resources/md/spec/).
;;
;; Cross-references three sources:
;;   1. tools/clojuredocs-export.json — the clojure.core var inventory (the surface)
;;   2. this jolt's own clojure.core: what it interns and what resolves
;;   3. the symbols the conformance corpus + unit cases exercise
;;
;; It runs ON jolt, so the jolt it measures is the one running it — a built
;; binary or bin/jolt, whichever you start it with:
;;
;;   jolt run tools/spec_coverage.clj                      # writes ../jolt-lang.github.io/resources/md/spec/coverage.md
;;   jolt run tools/spec_coverage.clj path/to/coverage.md  # somewhere else
;;
;; Run from the repo root (the inputs are repo-relative). clojure.data.json and
;; jolt-lang/time are pulled in with jolt.deps/add-deps, so the first run needs
;; ~/.m2 (or network).
(require 'jolt.deps)
;; data.json's instant writer imports java.time, which jolt-lang/time provides;
;; requiring jolt.time before data.json is what installs those classes.
(jolt.deps/add-deps '{:deps {io.github.jolt-lang/time {:git/tag "v0.0.8" :git/sha "33c5e9831c046cfcbe68bc0c9c33e92568eaebb1"}
                             org.clojure/data.json {:mvn/version "2.5.2"}}})
(require 'jolt.time)
(require '[clojure.data.json :as json]
         '[clojure.string :as str])

;; --- 1. the surface -----------------------------------------------------------
(def ^:private data (json/read-str (slurp "tools/clojuredocs-export.json") :key-fn keyword))
(def ^:private core-vars (filter #(= "clojure.core" (:ns %)) (:vars data)))
(def ^:private core (vec (sort (map :name core-vars))))
(def ^:private examples (set (map :name (filter #(seq (:examples %)) core-vars))))

;; --- 2. what this jolt provides -----------------------------------------------
;; Two notions: INTERNED (in clojure.core's interns — visible to ns
;; introspection) and RESOLVABLE (usable in code; some seed fns resolve through
;; fallback paths without being interned — itself a conformance finding).
(def ^:private interned (set (map name (keys (ns-interns 'clojure.core)))))
(def ^:private resolvable (set (filter #(some? (resolve (symbol %))) core)))
(def ^:private jolt-has (into interned resolvable))

;; --- 3. what the tests exercise ---------------------------------------------
;; A var counts as tested when its name appears as a WHOLE TOKEN anywhere in the
;; test sources (assertions live inside strings, so call-position-only matching
;; missed *1, +', ., .., /, and bare transducer refs like cat). A token is a
;; maximal run of symbol characters, which is exactly what the old
;; lookbehind/lookahead regex asserted around the name.
(def ^:private test-tokens
  (let [text (str (slurp "test/chez/corpus.edn") "\n" (slurp "test/chez/unit.edn"))]
    (set (re-seq #"[\w*+!?<>=_.'/-]+" text))))

;; --- classification -------------------------------------------------------------
(def ^:private special
  #{"catch" "finally" "do" "def" "defmacro" "fn" "if" "let" "loop" "quote" "recur" "throw"
    "try" "var" "new" "set!" "monitor-enter" "monitor-exit"
    ;; '.' is the interop special form — (resolve '.) is nil on the JVM too
    "."})
(def ^:private agents
  #{"agent" "send" "send-off" "send-via" "await" "await-for" "await1" "agent-error"
    "agent-errors" "clear-agent-errors" "error-handler" "error-mode"
    "set-agent-send-executor!" "set-agent-send-off-executor!" "restart-agent"
    "shutdown-agents" "release-pending-sends" "add-tap" "tap>" "remove-tap"
    "set-error-handler!" "set-error-mode!"})
(def ^:private stm
  #{"dosync" "ref" "ref-set" "alter" "commute" "ensure" "ref-history-count" "ref-max-history"
    "ref-min-history" "sync" "io!"})
(def ^:private jvm
  #{"class" "class?" "cast" "bases" "supers" "compile" "add-classpath" "definline" "bean"
    "accessor" "create-struct" "defstruct" "struct" "struct-map" "amap" "areduce" "memfn"
    "enumeration-seq" "iterator-seq" "resultset-seq" "print-ctor" "print-dup" "print-method"
    "print-simple" "primitives-classnames" "vector-of" "PrintWriter-on" "StackTraceElement->vec"
    "Throwable->map" "Inst" "->ArrayChunk" "->Vec" "->VecNode" "->VecSeq" "-cache-protocol-fn"
    "-reset-methods" "EMPTY-NODE" "method-sig" "proxy-name" "gen-class" "gen-interface"
    "find-protocol-impl" "find-protocol-method" "with-loading-context" "load" "load-file"
    "load-reader" "loaded-libs" "requiring-resolve" "default-data-readers" ".." "." "pcalls"
    "pmap" "pvalues" "stream-into!" "stream-reduce!" "stream-seq!" "stream-transduce!"
    "mix-collection-hash" "iteration" "unquote" "unquote-splicing"})

(defn- classify [n]
  (cond
    (jolt-has n) (if (test-tokens n) "implemented+tested" "implemented-untested")
    (re-matches #"\*.*\*" n) "dynamic-var"
    (special n) "special-form"
    (agents n) "agents-taps"
    (stm n) "stm-refs"
    (jvm n) "jvm-specific"
    :else "missing-portable"))

(def ^:private cls (into {} (map (fn [n] [n (classify n)]) core)))
(def ^:private counts (frequencies (vals cls)))
(def ^:private stamp (str (java.time.LocalDate/now)))

(defn- dashboard []
  (let [core-set (set core)
        n (fn [k] (get counts k 0))
        rows (map (fn [v] (str "| `" v "` | " (cls v) " | " (if (examples v) "✓" "") " |")) core)]
    (str "# Appendix A — Coverage Dashboard (generated)\n\n"
         "Generated " stamp " by `tools/spec_coverage.clj` — do not edit by hand.\n\n"
         "Surface: **" (count core) "** clojure.core vars (ClojureDocs export; " (count examples) " with\n"
         "community examples). jolt interns " (count (filter core-set jolt-has)) " of them.\n\n"
         "| Status | Count | Meaning |\n|---|---|---|\n"
         "| implemented+tested | " (n "implemented+tested") " | in jolt and exercised by spec/conformance |\n"
         "| implemented-untested | " (n "implemented-untested") " | in jolt, no direct test — spec entries will add them |\n"
         "| resolvable-not-interned | " (count (remove special (filter core-set (remove interned resolvable))))
         " | works in code but invisible to ns introspection (conformance finding) |\n"
         "| missing-portable | " (n "missing-portable") " | portable semantics, jolt lacks it — implementation gap |\n"
         "| special-form | " (n "special-form") " | specified in §3, not a library var |\n"
         "| dynamic-var | " (n "dynamic-var") " | classification needed: portable default vs host-dependent |\n"
         "| agents-taps | " (n "agents-taps") " | out of scope pending concurrency design note |\n"
         "| stm-refs | " (n "stm-refs") " | out of scope pending concurrency design note |\n"
         "| jvm-specific | " (n "jvm-specific") " | catalogued, not specified |\n\n"
         "Classifications are initial and mechanical — reclassifying is an ordinary\n"
         "spec change. A var is *Verified* only when its §9 entry exists and carries no\n"
         "UNVERIFIED field; that column will be added as entries land.\n\n"
         "## Per-var status\n\n"
         "| Var | Status | ClojureDocs examples |\n|---|---|---|\n"
         (str/join "\n" rows) "\n")))

(let [out (or (first *command-line-args*) "../jolt-lang.github.io/resources/md/spec/coverage.md")]
  (spit out (dashboard))
  (println (str "wrote " out " — " (count core) " vars"))
  (doseq [[k v] (sort-by (comp - val) counts)] (println (str "  " k ": " v))))
