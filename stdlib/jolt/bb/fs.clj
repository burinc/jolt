(ns jolt.bb.fs
  "The babashka.fs built-ins Jolt supplies.

  Jolt's reader matches `:bb`, and a .cljc library reads that as a promise that
  the host defines the guarded var itself — babashka.fs writes `list-dir` as
  `#?(:bb nil :default (defn list-dir ...))` because babashka provides it
  natively and cannot expose java.nio's DirectoryStream to interpreted code.
  Jolt has to keep the same promise, or the var stays declared and unbound and
  `list-dirs`, `modified-since` and `path-seq` fail at the call rather than at
  the load. Jolt's host does shim DirectoryStream, so this is the JVM
  implementation, interned where babashka's built-in would already be.

  The loader loads this namespace immediately after babashka.fs
  (`ldr-ns-supplements`); nothing requires it directly."
  (:require [babashka.fs]))

(defn- directory-stream
  ([dir]
   (java.nio.file.Files/newDirectoryStream (babashka.fs/path dir)))
  ([dir glob-or-accept]
   (if (string? glob-or-accept)
     (java.nio.file.Files/newDirectoryStream (babashka.fs/path dir) (str glob-or-accept))
     (java.nio.file.Files/newDirectoryStream
       (babashka.fs/path dir)
       (reify java.nio.file.DirectoryStream$Filter
         (accept [_ entry] (boolean (glob-or-accept entry))))))))

(defn list-dir
  "Returns a vector of all paths in `dir`. For descending into subdirectories
  use `glob`. `glob-or-accept` is a glob string such as \"*.edn\" or a
  `(fn accept [path]) -> truthy`."
  ([dir]
   (with-open [stream (directory-stream dir)]
     (vec stream)))
  ([dir glob-or-accept]
   (with-open [stream (directory-stream dir glob-or-accept)]
     (vec stream))))

;; babashka.fs already declares the var (its own list-dirs and path-seq refer to
;; it), so this fills the root the :bb branch left empty.
(intern 'babashka.fs
        (with-meta 'list-dir
          {:doc (:doc (meta #'list-dir))
           :arglists '([dir] [dir glob-or-accept])})
        list-dir)
