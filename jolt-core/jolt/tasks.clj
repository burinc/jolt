(ns jolt.tasks
  "The task runner behind `jolt <task>` / `jolt run <task>` / `jolt tasks`.

  Tasks come from a project's bb.edn or deps.edn `:tasks` map (jolt.deps merges
  both, bb.edn last) and follow babashka's semantics:

    {:tasks {:init     (def version \"1.2.3\")     ; once, before any task
             :requires ([babashka.fs :as fs])      ; for every task
             :enter    (println \"->\" (:name (current-task)))
             :leave    (println \"<-\" (:name (current-task)))

             clean {:doc \"remove build output\" :task (fs/delete-tree \"target\")}
             build {:doc \"build\" :depends [clean] :task (shell \"make\")}
             ship  {:requires ([app.release :as r]) :task (r/ship! version)}}}

  A task's value is either a map — :doc, :task (the body), :depends, :requires,
  :private, :extra-paths, :extra-deps — or the body on its own. Bodies run in
  the `user` namespace with clojure.core and babashka.tasks referred, so
  `shell`, `jolt`, `clojure`, `run` and `current-task` are available
  unqualified, and the arguments after the task name are *command-line-args*.

  Two forms are jolt's own rather than babashka's, and work in either file:
  a STRING body is a shell command line (babashka would evaluate it as an
  expression, which does nothing), and a map with :main-opts runs them like an
  alias's — `{:doc \"test\" :main-opts [\"-m\" \"app.test\"]}`.

  jolt.main injects what it owns (how to resolve the project, how to run
  :main-opts) rather than being required back — this namespace is loaded only
  when a task actually runs, and stays out of the CLI's startup closure.

  babashka.tasks is required lazily for the same reason, one level down: a
  string or :main-opts task with no hooks needs neither it nor the
  babashka.process it pulls in, and requiring it up front put half a second on
  every `jolt <task>` that only wanted to run a shell line.")

;; Task bodies are evaluated in `user`, like babashka's.
(def ^:private task-ns 'user)

;; The run in progress, for babashka.tasks/run to re-enter. One per process:
;; the CLI runs one task tree, and under :parallel every thread shares it (the
;; only mutable part is the :ran registry, an atom).
(def ^:private current-ctx (atom nil))

;; The tasks whose bodies are on the stack in THIS thread — a task that depends
;; on itself, directly or through a cycle, would otherwise wait on a delay it is
;; itself forcing.
(def ^:private ^:dynamic *in-progress* #{})

(defn tasks-of
  "The runnable entries of a :tasks map — every symbol key. The keyword keys
  (:init / :requires / :enter / :leave) configure the run, they are not tasks."
  [tasks]
  (into {} (remove (comp keyword? key)) tasks))

(defn- entry
  "The task named `name` as a map, with its :name — nil when there is none. A
  non-map value is the body: `{build (shell \"make\")}`."
  [tasks name]
  (let [sym (symbol name)]
    (when-let [v (get (tasks-of tasks) sym)]
      (if (map? v) (assoc v :name sym) {:name sym :task v}))))

(defn overrides-builtin?
  "Does the project declare a task by this name that asks to shadow the jolt
  command of the same name? babashka's :override-builtin, verbatim: a task only
  displaces a built-in command when it says so, so adding a `run` or `path`
  task cannot silently break the CLI."
  [tasks name]
  (boolean (:override-builtin (entry tasks name))))

;; --- the task namespace ------------------------------------------------------

(defn- eval-body [form]
  (binding [*ns* (the-ns task-ns)] (eval form)))

;; :requires land their :as aliases in the CURRENT namespace, so this has to run
;; with *ns* bound to the task namespace — a per-task :requires left to whatever
;; namespace the CLI happened to be in registered the alias somewhere else, and
;; the body then failed to resolve it ("Unknown class c").
(defn- require-all! [specs]
  (when (seq specs)
    (binding [*ns* (the-ns task-ns)]
      (doseq [spec specs] (require spec)))))

(defn- prepare-ns!
  "Create the task namespace, refer core + the babashka.tasks API into it, run
  the :tasks-level :requires, then :init. Held in the run context as a delay:
  once per invocation, on the first task that needs it, and safe to force from
  two :parallel threads at once."
  [tasks]
  (create-ns task-ns)
  (require 'babashka.tasks)
  (binding [*ns* (the-ns task-ns)]
    (refer 'clojure.core)
    (refer 'babashka.tasks :only '[shell jolt clojure run current-task]))
  (require-all! (:requires tasks))
  (when-let [init (:init tasks)] (eval-body init))
  true)

;; Does running this task involve evaluating Clojure in the task namespace? A
;; code body or a per-task :requires does; so does any :tasks-level hook, which
;; runs around every task including a shell one. A string or :main-opts task in
;; a :tasks map with no hooks does not, and takes neither the namespace setup
;; nor the babashka.tasks load.
(defn- needs-task-ns? [tasks t]
  (boolean (or (:requires t)
               (and (contains? t :task) (not (string? (:task t))))
               (:init tasks) (:requires tasks) (:enter tasks) (:leave tasks))))

;; --- running -----------------------------------------------------------------

(defn- shell-line!
  "A string body: one shell command line, run by the shell (so pipes, globs and
  && work), failing the task with its exit status."
  [cmd]
  (let [status (jolt.host/sh cmd)]
    (when-not (and (integer? status) (zero? status))
      (throw (ex-info (str "task exited with " status)
                      {:babashka/exit (if (integer? status) status 1) :cmd cmd})))))

(defn- run-body! [ctx t]
  (cond
    (contains? t :main-opts) ((:run-main-opts ctx) (:main-opts t) (:args ctx))
    (string? (:task t))      (shell-line! (:task t))
    (contains? t :task)      (eval-body (:task t))
    :else (throw (ex-info (str "task " (:name t) " has no :task body") {:task (:name t)}))))

(declare ensure-run!)

(defn- run-one! [ctx sym]
  (let [tasks (:tasks ctx)
        t (or (entry tasks sym)
              (throw (ex-info (str "unknown command or task: " sym " (see 'jolt tasks')")
                              {:name (str sym)})))
        deps (:depends t)]
    ;; :depends first — each at most once per invocation. :parallel runs the
    ;; independent ones concurrently; the registry below is what keeps a shared
    ;; dependency from running twice when it does.
    (when (seq deps)
      (if (:parallel ctx)
        (doseq [f (doall (map (fn [d] (future (ensure-run! ctx d))) deps))] @f)
        (doseq [d deps] (ensure-run! ctx d))))
    (if-not (needs-task-ns? tasks t)
      (run-body! ctx t)
      (do
        @(:prepare ctx)
        (with-bindings {(requiring-resolve 'babashka.tasks/*task*) t}
          (require-all! (:requires t))
          (when-let [h (:enter tasks)] (eval-body h))
          (run-body! ctx t)
          (when-let [h (:leave tasks)] (eval-body h)))))))

(defn- ensure-run!
  "Run `name` unless this invocation already has. The registry holds a delay per
  task, so two :depends edges onto the same task run it once even when they are
  being walked by different threads."
  [ctx name]
  (let [sym (symbol name)]
    (when (contains? *in-progress* sym)
      (throw (ex-info (str "circular task dependency at " sym) {:task (str sym)})))
    (let [d (delay (binding [*in-progress* (conj *in-progress* sym)] (run-one! ctx sym)))]
      @(get (swap! (:ran ctx) #(if (contains? % sym) % (assoc % sym d))) sym))))

(defn run-nested!
  "babashka.tasks/run: run a task from inside another one. The named task always
  runs (that is what the call asked for); its :depends still honour the
  invocation's already-ran registry."
  [name opts]
  (let [sym (symbol name)
        ctx (or @current-ctx
                (throw (ex-info "run called outside a task" {:task (str sym)})))]
    (when (contains? *in-progress* sym)
      (throw (ex-info (str "circular task dependency at " sym) {:task (str sym)})))
    (binding [*in-progress* (conj *in-progress* sym)]
      (run-one! (merge ctx (select-keys opts [:parallel])) sym))))

(defn- exit-code
  "The exit status a thrown task failure should become, or nil for an error that
  is not one — a failed subprocess (babashka.process/check's ex-data carries
  :cmd and :exit) or an explicit :babashka/exit. Anything else is a program
  error and belongs in the uncaught handler's report, with a stack trace.

  The cause chain, not just the throw: a :depends that failed under :parallel
  arrives wrapped by the future's deref, and reading only the top ex-data lost
  the child's status there (the task reported 1 with a stack trace over it)."
  [e]
  (loop [e e]
    (when e
      (let [d (ex-data e)
            code (or (:babashka/exit d)
                     (when (and (:cmd d) (integer? (:exit d)) (not (zero? (:exit d))))
                       (:exit d)))]
        (if code code (recur (ex-cause e)))))))

(defn- check-depends-acyclic!
  "Walk the static :depends graph reachable from `name` and raise on a cycle
  BEFORE anything runs. *in-progress* catches a cycle the sequential walk enters,
  but it is per-thread and conveyed down each branch: under :parallel two sibling
  branches force each other's delay, neither one's *in-progress* holds the other's
  task, and the run DEADLOCKED with no output where the sequential one reported.
  :depends is static data, so the graph is where that question is actually
  answerable. An unknown name has no edges here — run-one! still reports it."
  [tasks name]
  (letfn [(walk [sym path seen]
            (cond
              (contains? path sym)
              (throw (ex-info (str "circular task dependency at " sym) {:task (str sym)}))
              (contains? seen sym) seen
              :else
              (conj (reduce (fn [s d] (walk (symbol d) (conj path sym) s))
                            seen
                            (:depends (entry tasks sym)))
                    sym)))]
    (walk (symbol name) #{} #{})
    nil))

(defn run-task!
  "Run one task tree. `ctx` is
  {:tasks :name :args :app-args :run-main-opts :parallel} — :args is the argv
  after the task name verbatim (what a :main-opts task forwards), :app-args the
  same with a leading \"--\" consumed (what a code body sees as
  *command-line-args*).

  A failed subprocess exits with ITS status and prints nothing further — the
  child already reported, and a jolt stack trace over it would only bury that.
  Every other exception propagates to the CLI's uncaught handler."
  [{:keys [tasks name app-args] :as ctx}]
  (let [ctx (assoc ctx :ran (atom {}) :prepare (delay (prepare-ns! tasks)))]
    (reset! current-ctx ctx)
    (binding [*command-line-args* (seq app-args)]
      (try
        (check-depends-acyclic! tasks name)
        (ensure-run! ctx (symbol name))
        (catch :default e
          (if-let [code (exit-code e)]
            (System/exit code)
            (throw e)))))))

;; --- the listing -------------------------------------------------------------

(defn list-tasks!
  "`jolt tasks` — the project's task names and their :doc, babashka's listing.
  :private tasks are helpers for other tasks and stay out of it."
  [tasks]
  (let [entries (->> (tasks-of tasks)
                     (remove (fn [[_ v]] (and (map? v) (:private v))))
                     (sort-by (comp str key)))]
    (if (empty? entries)
      (println "No tasks found. Add a :tasks map to bb.edn or deps.edn.")
      (let [w (apply max (map (comp count str key) entries))]
        (println "The following tasks are available:")
        (println)
        (doseq [[k v] entries]
          (let [doc (when (map? v) (:doc v))]
            (println (if doc
                       (str (apply str k (repeat (- w (count (str k))) \space)) "  " doc)
                       (str k)))))))))
