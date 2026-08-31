;; java.io.File path-normalization gate — every JVM File constructor runs its
;; arguments through FileSystem.normalize(): runs of "/" collapse to one and a
;; trailing "/" is dropped. "." and ".." are NOT resolved, by the JVM or here —
;; that is getCanonicalPath's job, which canonical-path-test.clj covers.
;;
;; The one-arg constructor normalizes and is done. The two-arg one normalizes
;; each ARGUMENT and then resolves them, which is a different contract: an empty
;; parent resolves against getDefaultParent() rather than against "". Both
;; shapes are pinned below.
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
(check "(File. parent absolute-child-trailing)" (.getPath (File. "/a/b/" "/c/")) "/a/b/c")
(check "(File. parent absolute-child-dup)" (.getPath (File. "/a/b" "/c//d")) "/a/b/c/d")
(check "(File. parent empty-child)" (.getPath (File. "/a/b" "")) "/a/b")
(check "(File. root child)" (.getPath (File. "/" "c")) "/c")
(check "(File. file-parent child)" (.getPath (File. (File. "/a//b") "c")) "/a/b/c")
(check "(File. parent-with-trailing-dup child)" (.getPath (File. "/a/b//" "c")) "/a/b/c")
(check "(File. parent child-with-trailing)" (.getPath (File. "/a/b" "c//")) "/a/b/c")
(check "(File. parent dotdot-child)" (.getPath (File. "/a/b" "..//")) "/a/b/..")
(check "(File. dot-parent child)" (.getPath (File. "." "b")) "./b")
(check "(File. relative empty-child)" (.getPath (File. "a" "")) "a")

;; a separator-only child normalizes to "/", and resolve answers the parent
;; alone. Careful measuring this one against an old JVM: resolve grew its
;; c == "/" case in JDK 21, and through JDK 20 (File. "/a/b" "/") was "/a/b/",
;; a trailing separator no one-arg constructor can produce. 21 onward it is
;; "/a/b" — checked on 20, 21 and 26, and jolt matches 21+.
(check "(File. parent separator-only-child)" (.getPath (File. "/a/b" "///")) "/a/b")
(check "(File. parent double-sep-only-child)" (.getPath (File. "/a/b" "//")) "/a/b")
(check "(File. parent absolute-child-single)" (.getPath (File. "/a/b" "/")) "/a/b")
(check "(File. root separator-only-child)" (.getPath (File. "/" "//")) "/")

;; an EMPTY parent resolves against getDefaultParent(), which is "/" -- not
;; against the empty string, so the child comes back absolute
(check "(File. empty-parent child)" (.getPath (File. "" "c")) "/c")
(check "(File. empty-parent absolute-child)" (.getPath (File. "" "/c")) "/c")
(check "(File. empty-parent empty-child)" (.getPath (File. "" "")) "/")
(check "(File. empty-file-parent child)" (.getPath (File. (File. "") "c")) "/c")
;; The hinted local below is only there to pick an overload for the JVM
;; compiler, which cannot resolve (File. nil "c") on its own. Every File
;; constructor taking a null in that position agrees on the answer.
(let [^String s-nil nil]
  ;; a nil parent is the child alone, default parent not consulted
  (check "(File. nil-parent child)" (.getPath (File. s-nil "c")) "c")
  (check "(File. nil-parent absolute-child)" (.getPath (File. s-nil "/c")) "/c")
  ;; a null CHILD is null-checked before any of that, and so is the one-arg
  ;; constructor's only argument — both raise rather than reading nil as ""
  (check "(File. parent nil-child) raises"
         (try (File. "/a" s-nil) false (catch NullPointerException _ true)) true)
  (check "(File. nil) raises"
         (try (File. s-nil) false (catch NullPointerException _ true)) true))

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

;; Coercions is extended to nil, so as-file and the one-arg io/file answer nil
;; rather than a File whose path is "" — which is the cwd, a different file
;; altogether. as-relative-path goes through as-file, so a nil child is an NPE
;; on the .isAbsolute rather than an empty child that quietly joins to nothing.
(check "(io/as-file nil)" (io/as-file nil) nil)
(check "(io/file nil)" (io/file nil) nil)
(check "(io/file parent nil-child) raises"
       (try (io/file "/a" nil) false (catch NullPointerException _ true)) true)
(check "(io/as-relative-path nil) raises"
       (try (io/as-relative-path nil) false (catch NullPointerException _ true)) true)

;; io/make-parents builds (apply io/file f more) on the JVM, so it carries the
;; same contract: an absolute child raises rather than quietly joining
(check "(io/make-parents parent absolute-child) raises"
       (raises-not-relative? #(io/make-parents "/a/b" "/c")) true)
;; and the nil, since (io/file nil) is nil and .getParentFile raises on it
(check "(io/make-parents nil) raises"
       (try (io/make-parents nil) false (catch NullPointerException _ true)) true)

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
