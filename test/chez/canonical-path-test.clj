;; java.io.File/getCanonicalPath gate — it is realpath(3), not "make it
;; absolute": symlinks, "." and ".." all resolve. The containment check every
;; Java program writes,
;;
;;   (.startsWith (.getCanonicalPath child) (.getCanonicalPath root))
;;
;; is only a check at all if links resolve; when getCanonicalPath merely
;; absolutized, a symlink inside a served root passed it while pointing
;; anywhere on the filesystem.
;;
;; Run: bin/jolt run test/chez/canonical-path-test.clj (smoke.sh greps for
;; "CANONICAL-PATH OK").
(ns canonical-path-test
  (:import [java.io File]
           [java.nio.file Files Path Paths LinkOption]))

(def failures (atom []))
(defn check [label got want]
  (when-not (= got want)
    (swap! failures conj (str label ": want " (pr-str want) " got " (pr-str got)))))

(defn- path ^Path [s] (Paths/get (str s) (into-array String [])))
(defn- real-path [s] (str (.toRealPath (path s) (into-array LinkOption []))))

(def root (str (System/getProperty "java.io.tmpdir")
               "/jolt-canon-" (System/currentTimeMillis)))
(def inside (str root "/inside"))
(def outside (str root "/outside"))

(.mkdirs (File. inside))
(.mkdirs (File. outside))
(spit (str outside "/secret.txt") "outside")
(spit (str inside "/plain.txt") "inside")

;; a link INSIDE the tree pointing OUT of it — the case a path check exists for
(Files/createSymbolicLink (path (str inside "/escape.txt"))
                          (path (str outside "/secret.txt"))
                          (into-array java.nio.file.attribute.FileAttribute []))
;; and a link to a directory, so the walk has to resolve an interior component
(Files/createSymbolicLink (path (str inside "/out-dir"))
                          (path outside)
                          (into-array java.nio.file.attribute.FileAttribute []))

(def canon-root (.getCanonicalPath (File. inside)))

;; --- symlinks resolve --------------------------------------------------------

(check "link resolves to its target"
       (.getCanonicalPath (File. (str inside "/escape.txt")))
       (real-path (str outside "/secret.txt")))

(check "link is not reported as itself"
       (= (.getCanonicalPath (File. (str inside "/escape.txt")))
          (.getAbsolutePath (File. (str inside "/escape.txt"))))
       false)

(check "interior link component resolves"
       (.getCanonicalPath (File. (str inside "/out-dir/secret.txt")))
       (real-path (str outside "/secret.txt")))

;; the whole point: a containment check written the usual way now catches it
(check "escape fails a containment check"
       (.startsWith (.getCanonicalPath (File. (str inside "/escape.txt")))
                    (str canon-root "/"))
       false)
(check "a real file passes the same check"
       (.startsWith (.getCanonicalPath (File. (str inside "/plain.txt")))
                    (str canon-root "/"))
       true)

;; --- agreement with java.nio, which already resolved ------------------------

(check "agrees with Path/toRealPath"
       (.getCanonicalPath (File. (str inside "/escape.txt")))
       (real-path (str inside "/escape.txt")))

(check "getCanonicalFile agrees with getCanonicalPath"
       (.getPath (.getCanonicalFile (File. (str inside "/escape.txt"))))
       (.getCanonicalPath (File. (str inside "/escape.txt"))))

;; --- "." and ".." ------------------------------------------------------------

(check "dot segments fold"
       (.getCanonicalPath (File. (str inside "/./plain.txt")))
       (str canon-root "/plain.txt"))

(check "dotdot folds"
       (.getCanonicalPath (File. (str inside "/sub/../plain.txt")))
       (str canon-root "/plain.txt"))

;; a relative path is still resolved against user.dir, as before
(check "relative path is absolute"
       (.startsWith (.getCanonicalPath (File. "project.clj")) "/")
       true)

;; --- paths that do not exist -------------------------------------------------
;; the JVM canonicalizes these too, resolving as far as it can rather than
;; throwing: realpath(3) fails on ENOENT, so the tail is re-attached by hand.

(check "missing leaf still canonicalizes"
       (.getCanonicalPath (File. (str inside "/nope.txt")))
       (str canon-root "/nope.txt"))

(check "missing directories still canonicalize"
       (.getCanonicalPath (File. (str inside "/no/such/dir/file.txt")))
       (str canon-root "/no/such/dir/file.txt"))

(check "missing path under a link resolves the link"
       (.getCanonicalPath (File. (str inside "/out-dir/nope.txt")))
       (str (real-path outside) "/nope.txt"))

(check "dotdot folds in a missing tail"
       (.getCanonicalPath (File. (str inside "/no/such/../dir/f.txt")))
       (str canon-root "/no/dir/f.txt"))

(check "root canonicalizes to itself" (.getCanonicalPath (File. "/")) "/")

;; --- cleanup + report --------------------------------------------------------

(doseq [f [(str inside "/escape.txt") (str inside "/out-dir") (str inside "/plain.txt")
           (str outside "/secret.txt") inside outside root]]
  (try (.delete (File. f)) (catch Throwable _ nil)))

(if (seq @failures)
  (do (println "CANONICAL-PATH FAILURES:")
      (doseq [f @failures] (println " " f))
      (System/exit 1))
  (println "CANONICAL-PATH OK"))
