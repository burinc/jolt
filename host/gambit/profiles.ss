;; profiles.ss — how much of the language a Gambit build carries.
;;
;; DATA, read by gen-boot.ss (on Chez) to write a boot file per profile. Not
;; loaded at runtime.
;;
;; boot.ss stays the single source of load ORDER. This file only says which of
;; its files belong to an OPTIONAL feature group, and which profile keeps which
;; groups. Anything boot.ss includes that is not named in a group here is the
;; kernel: always in, not selectable.
;;
;; Excluding a group does two things. Its files are left out of the generated
;; boot, and every clojure.core name those files define is bound to a raise that
;; says the group was excluded — DERIVED by scanning the files for def-var!
;; forms, so the error surface tracks the code instead of a hand-kept list. A
;; dropped feature reports itself; it never fails as an unbound global.
;;
;; Measured cost of each group in the js bundle (raw / gzipped, which is what a
;; web server ships):
;;
;;   regex      2.4 MB / 0.4 MB
;;   compiler   2.9 MB / 0.5 MB
;;   core       8.7 MB / 0.7 MB
;;   ---------------------------
;;   kernel    19.4 MB / 2.1 MB   floor: the Gambit runtime plus jolt's kernel
;;   full      31.0 MB / 3.3 MB
;;
;; The floor dominates, so profiles trade features for the last third of the
;; bundle. Adding a group is worth it when it is separable AND measurable; a
;; group worth kilobytes is churn.

(groups

  ;; Runtime regex: irregex plus the Java-pattern translation in front of it.
  ;; Without it re-pattern/re-find/re-seq/re-matches and #"..." literals raise.
  (regex
   "regex"
   ("../../vendor/irregex/irregex.scm"
    "../chez/java/regex-translate.ss"
    "../chez/regex.ss"))

  ;; clojure.core itself, as emitted by the cross-mint, plus the native
  ;; re-assertions over it. Excluding this leaves the kernel and no standard
  ;; library — an embedding, not a Clojure.
  (core
   "clojure.core"
   ("seed/prelude.ss"
    "../chez/post-prelude.ss"
    "host-vars.ss"))

  ;; The compiler image and the read-analyze-emit-eval path over it. Excluding
  ;; it gives a runtime that can hold and print jolt values but cannot compile
  ;; source, so there is no eval, no REPL, and no runtime macro expansion.
  (compiler
   "compiler"
   ("seed/image.ss"
    "../chez/compile-eval.ss")))

(profiles

  ;; Everything. What `make gambitcheck`, `gambitkernel` and `gambiteval` run
  ;; against, and the default for a bundle.
  (full    (regex core compiler))

  ;; The browser REPL: it must compile what a visitor types, and clojure.core is
  ;; the language, so both stay. Regex is the one feature a REPL demo can lose
  ;; and still be a REPL.
  (repl    (core compiler))

  ;; The floor, for measuring and for embedding: kernel only, no standard
  ;; library and no compiler.
  (kernel  ()))
