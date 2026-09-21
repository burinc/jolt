(ns jolt.cli
  "Command-line argument parsing and subcommand dispatch: parse a vector of
  arguments into an options map with coercion and validation, render help text,
  and dispatch a command tree to a handler. The implementation is the vendored
  babashka.cli; jolt.cli is the public surface. See
  https://github.com/babashka/cli for the API of each function.

  The main entry points are `parse-opts` (arguments to an options map),
  `parse-args` (the same, keeping leftover arguments), `dispatch` (route a
  command tree to a handler), and `format-opts` (render help text from a spec).

  jolt.tasks uses this to give a bb.edn task with :exec-fn or :cmd the same
  --help, coercion and subcommand behaviour babashka gives it."
  (:require [babashka.cli]
            [jolt.util :refer [import-vars]]))

;; Excluded from the public surface:
;;   *exit-fn* — a dynamic var, which import-vars cannot re-export as a
;;               delegating fn. Rebind it on babashka.cli directly.
(import-vars babashka.cli :exclude #{*exit-fn*})
