(ns jolt.process
  "Shelling out and spawning sub-processes: run a command, stream or capture its
  output, pipe processes together, check exit codes. The implementation is the
  vendored babashka.process, driven by Jolt's java.lang.ProcessBuilder / Process
  shims (host/chez/java/process.ss) over the operating system's process API;
  jolt.process is the public surface.

  The main entry points are `process` (spawn, returns a process record you can
  deref for the result), `sh` (run and block, capturing :out/:err strings),
  `shell` (run inheriting stdio, throw on failure), the `$` macro (convenience
  with ~ interpolation), `check` (throw on non-zero exit), and `pipeline` /
  threading with `->` for connecting processes. See
  https://github.com/babashka/process for the API of each function.

  `exec` (replace the current image, GraalVM/babashka-only) is not re-exported:
  it is unsupported outside a native image and would only ever throw here."
  (:require [babashka.process]
            ;; babashka.process loads its pprint method conditionally at runtime
            ;; (when clojure.pprint is present); require it here so it is in the
            ;; static closure and gets embedded in an AOT-built binary.
            [babashka.process.pprint]
            [jolt.util :refer [import-vars]]))

;; Excluded from the public surface:
;;   *defaults* / null-file / Process / ProcessBuilder / ProcessBuilder$Redirect /
;;   print-method  — non-fn vars (dynamic var, delay, record/class, multimethod)
;;                    that import-vars cannot re-export as delegating fns.
;;   if-before-jdk8 / if-has-exec — internal implementation macros.
;;   exec — GraalVM-only; always throws on this host.
(import-vars babashka.process
  :exclude #{*defaults* null-file Process ProcessBuilder ProcessBuilder$Redirect
             print-method if-before-jdk8 if-has-exec exec})

;; babashka.process registers a :shutdown hook after the process has started, so
;; a SIGTERM landing between the spawn and the registration ended jolt with no
;; hook to run, and the child tree outlived it -- what :shutdown destroy-tree is
;; there to prevent (the process gate's SIGTERM row caught it on a loaded
;; runner). process* is the one spawn every entry point goes through (process,
;; shell, sh, $), so it is wrapped here to register the hook FIRST, holding a
;; promise of the process that it delivers once the spawn returns. A hook that
;; runs inside the window waits for that delivery, then kills the tree. As
;; upstream, the hook is dropped and run once the process exits, and it is
;; dropped again if the spawn throws.
(alter-var-root
  #'babashka.process/process*
  (fn [spawn]
    (fn [{:keys [opts] :as args}]
      (if-let [shutdown (:shutdown (merge babashka.process/*defaults* opts))]
        (let [rt (Runtime/getRuntime)
              started (promise)
              hook (Thread. (fn [] (when-let [p (deref started 5000 nil)] (shutdown p))))]
          (.addShutdownHook rt hook)
          (let [p (try (spawn (assoc-in args [:opts :shutdown] nil))
                       (catch Throwable e
                         (.removeShutdownHook rt hook)
                         (throw e)))]
            (deliver started p)
            (-> (.onExit ^java.lang.Process (:proc p))
                (.thenRun (fn []
                            (try (.removeShutdownHook rt hook) (catch Exception _ nil))
                            (.start hook))))
            p))
        (spawn args)))))

