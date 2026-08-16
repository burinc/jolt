;; post-prelude-str.ss — Chez-only native overrides over clojure.string.
;; Loaded right after post-prelude.ss on the CHEZ boot (cli.ss / bootstrap /
;; build prologues) but NOT part of the Gambit cross-mint boot: these bind
;; natives from java/natives-str.ss, which the Gambit boot excludes along with
;; the rest of the java/ tail. Gambit keeps the overlay versions.

;; --- hot-path natives over prelude-baked Clojure wrappers --------------------
;; clojure.string's wrappers are compiled into the seed prelude as chained
;; overlay calls (to-str -> count -> subs -> =, ~400-500ns/call, allocating a
;; substring per invocation) over the ~40ns natives. Replace the vars with
;; single-proc natives (natives-str.ss) carrying the same semantics. Calls
;; already compiled against these vars pick the new values up through the var
;; cells, so no remint is needed.
(def-var! "clojure.string" "starts-with?" str-starts-with?)
(def-var! "clojure.string" "ends-with?" str-ends-with?)
(def-var! "clojure.string" "includes?" str-includes?)
(def-var! "clojure.string" "index-of" str-index-of*)
(def-var! "clojure.string" "upper-case" str-upper-c)
(def-var! "clojure.string" "lower-case" str-lower-c)
;; clojure.string/replace with a STRING pattern and STRING replacement is a
;; literal replace-all (JVM semantics) — the common "-" -> "_" / quoting case.
;; The overlay replace routes through to-str + str-replace-all's pattern-type
;; dispatch (~400ns); route the literal case straight to the native scan.
(let ((ov-replace (var-deref "clojure.string" "replace")))
  (def-var! "clojure.string" "replace"
    (case-lambda
      ((s match replacement)
       (if (and (string? match) (string? replacement))
           (str-replace-literal (str-coerce s) match replacement)
           (jolt-invoke ov-replace s match replacement)))
      ((s match f) (jolt-invoke ov-replace s match f)))))
