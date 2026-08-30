;; java.io.File path-normalization gate — every JVM File constructor runs its
;; path through FileSystem.normalize(), so a File's path is always normalized:
;; runs of "/" collapse to one and a trailing "/" is dropped. "." and ".." are
;; NOT resolved, by the JVM or here — that is getCanonicalPath's job, which
;; canonical-path-test.clj covers.
;;
;; jolt used to keep the path exactly as given, so (File. "/a/b//c") answered
;; "/a/b//c". The visible route in was createTempFile: $TMPDIR ends in "/" on
;; macOS, so every temp file came back with a doubled separator in its path.
;;
;; The expected values below are JVM values, measured against Clojure 1.12.3 on
;; OpenJDK 25 rather than reasoned about.
;;
;; Run: bin/jolt run test/chez/path-normalize-test.clj (smoke.sh greps for
;; "PATH-NORMALIZE OK").
(ns path-normalize-test
  (:require [clojure.java.io :as io])
  (:import [java.io File]))

(def failures (atom []))
(defn check [label got want]
  (when-not (= got want)
    (swap! failures conj (str label ": want " (pr-str want) " got " (pr-str got)))))

;; --- the one-arg constructor -------------------------------------------------

(doseq [[given want] [["/a/b//c"   "/a/b/c"]
                      ["/a/b/"     "/a/b"]
                      ["/a//b//c"  "/a/b/c"]
                      ["//a/b"     "/a/b"]
                      ["a//b"      "a/b"]
                      ["//a//b//"  "/a/b"]
                      ["///a"      "/a"]
                      ["a//"       "a"]
                      ["/a//"      "/a"]
                      ;; a separator-only path is "/", not the empty string
                      ["//"        "/"]
                      ["/"         "/"]
                      [""          ""]
                      ;; "." and ".." survive: the constructor does not resolve
                      ;; them, so neither may normalization
                      ["."         "."]
                      ["./"        "."]
                      ["..//"      ".."]
                      ["/a/./b"    "/a/./b"]
                      ["/a/b/../c" "/a/b/../c"]]]
  (check (str "(File. " (pr-str given) ")") (.getPath (File. given)) want))

;; --- the two-arg constructor -------------------------------------------------
;; The seam already joined correctly. What did not was a duplicate INSIDE either
;; argument, which the seam-local join never looked at.

(check "(File. parent-with-trailing child)" (.getPath (File. "/a/b/" "c")) "/a/b/c")
(check "(File. parent-with-inner-dup child)" (.getPath (File. "/a//b" "c")) "/a/b/c")
(check "(File. parent child-with-dup)" (.getPath (File. "/a" "b//c")) "/a/b/c")
;; the two-arg constructor has no as-relative-path contract: it joins an
;; absolute child rather than rejecting it, and the JVM agrees
(check "(File. parent absolute-child)" (.getPath (File. "/a/b" "/c")) "/a/b/c")

;; --- clojure.java.io/file and as-file ----------------------------------------
;; io/file never reached the joining path at all: it is jolt-make-file directly,
;; whose multi-arg loop appends "/" unconditionally.

(check "(io/file parent child)" (.getPath (io/file "/a/b/" "c")) "/a/b/c")
(check "(io/file parent child more)" (.getPath (io/file "/a/b/" "c" "d")) "/a/b/c/d")
(check "(io/file dup)" (.getPath (io/file "/a//b")) "/a/b")
(check "(io/as-file trailing)" (.getPath (io/as-file "/a//b/")) "/a/b")

;; --- the route in ------------------------------------------------------------
;; createTempFile builds its path from $TMPDIR, which ends in "/" on macOS. It
;; also builds its jfile directly rather than through the constructor, which is
;; why the invariant belongs at the record and not at one call site.

(let [tmp (File/createTempFile "jolt-pathnorm" ".tmp")]
  (try
    (check "createTempFile has no doubled separator"
           (boolean (re-find #"//" (.getPath tmp))) false)
    (check "createTempFile still names a real file" (.exists tmp) true)
    (finally (.delete tmp))))

;; a File built under a directory whose path carries a trailing separator still
;; round-trips through the filesystem
(let [d (File. (str (System/getProperty "java.io.tmpdir") "/"))
      f (io/file (.getPath d) (str "jolt-pathnorm-" (System/currentTimeMillis) ".txt"))]
  (try
    (spit f "ok")
    (check "write/read under a trailing-separator dir" (slurp f) "ok")
    (check "and its path has no doubled separator"
           (boolean (re-find #"//" (.getPath f))) false)
    (finally (.delete f))))

;; --- report ------------------------------------------------------------------

(if (seq @failures)
  (do (println "PATH-NORMALIZE FAILURES:")
      (doseq [f @failures] (println "  " f))
      (System/exit 1))
  (println "PATH-NORMALIZE OK"))
