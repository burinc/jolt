(ns jolt.fs
  "File-system utilities: paths, files, directories, globbing, copy/move,
  timestamps, POSIX permissions, and symbolic links. The implementation is the
  vendored babashka.fs; jolt.fs is the public surface and exposes only the
  operations Jolt fully supports on this host.

  Path-valued results are java.nio.file.Path values. See
  https://github.com/babashka/fs for the API of each function."
  (:require [babashka.fs]
            [jolt.util :refer [import-vars]]))

;; zip / gzip need java.util.zip, which Jolt does not shim yet — keep them out
;; of the public surface rather than exposing operations that fail.
;; list-dir is defined below: the vendored source leaves it to babashka's
;; built-in on a :bb host, and Jolt's reader takes the :bb branch.
(import-vars babashka.fs :exclude #{zip unzip gzip gunzip list-dir})

(defn- directory-stream
  ([dir] (java.nio.file.Files/newDirectoryStream (babashka.fs/path dir)))
  ([dir glob-or-accept]
   (if (string? glob-or-accept)
     (java.nio.file.Files/newDirectoryStream (babashka.fs/path dir) glob-or-accept)
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
