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
;; a separator-only child normalizes to "/" first, and resolve then joins
;; parent+"/" -- which the constructor's normalize pass collapses back down.
;; All five measured on the JVM.
(check "(File. parent separator-only-child)" (.getPath (File. "/a/b" "///")) "/a/b")
(check "(File. parent double-sep-only-child)" (.getPath (File. "/a/b" "//")) "/a/b")
(check "(File. root separator-only-child)" (.getPath (File. "/" "//")) "/")
(check "(File. parent absolute-child-trailing)" (.getPath (File. "/a/b/" "/c/")) "/a/b/c")
(check "(File. parent absolute-child-single)" (.getPath (File. "/a/b" "/")) "/a/b")
(check "(File. parent empty-child)" (.getPath (File. "/a/b" "")) "/a/b")
(check "(File. root child)" (.getPath (File. "/" "c")) "/c")
(check "(File. file-parent child)" (.getPath (File. (File. "/a//b") "c")) "/a/b/c")

;; --- clojure.java.io/file and as-file ----------------------------------------
;; io/file never reached the joining path at all: it is jolt-make-file directly,
;; whose multi-arg loop appends "/" unconditionally.

(check "(io/file parent child)" (.getPath (io/file "/a/b/" "c")) "/a/b/c")
(check "(io/file parent child more)" (.getPath (io/file "/a/b/" "c" "d")) "/a/b/c/d")
(check "(io/file dup)" (.getPath (io/file "/a//b")) "/a/b")
(check "(io/as-file trailing)" (.getPath (io/as-file "/a//b/")) "/a/b")

;; --- io/file's as-relative-path contract -------------------------------------
;; io/file is not the File constructor. Clojure puts every child through
;; as-relative-path, which throws on an absolute one, while the two-arg
;; constructor above joins it. Normalization alone would have hidden this:
;; joining "/a/b" and "/c" gives "/a/b//c", which collapses to a plausible
;; "/a/b/c" answer to a call the JVM rejects.

(defn- raises-not-relative? [f]
  (try (f) false
       (catch IllegalArgumentException e
         (boolean (re-find #"is not a relative path" (.getMessage e))))))

(check "(io/file parent absolute-child) raises"
       (raises-not-relative? #(io/file "/a/b" "/c")) true)
(check "(io/file parent child absolute-more) raises"
       (raises-not-relative? #(io/file "/a" "b" "/c")) true)
;; as-relative-path goes through as-file first, so what .isAbsolute sees -- and
;; what the thrown message names -- is the NORMALIZED path
(check "(io/file parent absolute-dup-child) message names the normalized path"
       (try (io/file "/a/b" "//c") nil
            (catch IllegalArgumentException e (.getMessage e)))
       "/c is not a relative path")
;; a child with an interior separator is still relative, and joins
(check "(io/file parent nested-relative-child)" (.getPath (io/file "/a" "b/c")) "/a/b/c")
(check "(io/file relative relative)" (.getPath (io/file "a" "b")) "a/b")

;; io/as-relative-path itself: public in clojure.java.io on the JVM, and it
;; answers the normalized path on the way through
(check "(io/as-relative-path relative-dup)" (io/as-relative-path "a//b") "a/b")
(check "(io/as-relative-path trailing)" (io/as-relative-path "b/") "b")
(check "(io/as-relative-path of a File)" (io/as-relative-path (File. "x//y")) "x/y")
(check "(io/as-relative-path absolute-dup) message names the normalized path"
       (try (io/as-relative-path "//c") nil
            (catch IllegalArgumentException e (.getMessage e)))
       "/c is not a relative path")

;; io/make-parents builds (apply io/file f more) on the JVM, so it carries the
;; same contract: an absolute child raises rather than quietly joining
(check "(io/make-parents parent absolute-child) raises"
       (raises-not-relative? #(io/make-parents "/a/b" "/c")) true)

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
