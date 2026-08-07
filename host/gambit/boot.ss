;; boot.ss — the G2 boot: the curated jolt runtime subset loads on native gsi
;; (Gambit 4.9.7). jolt-mj95.3.
;;
;; ONE compilation unit: everything is ##include-spliced (NOT load'd) so the
;; shim macros from prelude-shims.ss (define-record-type, fx aliases,
;; with-mutex, ...) expand in the SAME unit as every manifest file — the
;; "compile the boot files together" flow (see gambitcheck.ss's splice note).
;;
;; LOAD SHIM: rt.ss orchestrates its own loads ((load "host/chez/...") for the
;; whole manifest plus the excluded java tail). Under this boot every manifest
;; file is spliced in here and the excluded ones are deliberately skipped, so
;; a runtime (load "host/chez/...") must be a no-op — re-loading the Chez
;; copies would clobber the gambit sa-runtime/hasheq and pull in Chez-only
;; java interop. vendor/irregex is NOT under host/chez and loads normally.
(define %gambit-load load)
(define (load path . rest)
  (if (and (string? path) (string-prefix? "host/chez/" path))
      #f
      (apply %gambit-load path rest)))

(##include "prelude-shims.ss")
(##include "scheme-adapter-runtime.ss")

;; ---- manifest, in rt.ss load order (findings doc, curated) ----------------
;;
;; G2-booted: values, hasheq(gambit), collections, seq, then rt-core (the gambit
;; kernel — the rt.ss port; its port-log is in the file header). STOPS at the
;; first file whose blocker is class (c) (a genuine Chez-only construct with no
;; gambit seam) — see REPORT.

;; lazy-bridge forward-shared flags: seq.ss's force path reads jolt-mt? and
;; seq-more dispatches on it, but lazy-bridge.ss (loaded much later) is what
;; defines them. Pre-declare so seq.ss's references are bound; lazy-bridge.ss
;; REDEFINES them with its real implementation (the #f default and the
;; mark-mt! flip are identical, so the redefinition is a no-op in practice).
(define jolt-mt? #f)
(define (jolt-mark-mt!) (set! jolt-mt? #t))

(##include "../chez/values.ss")
(##include "hasheq.ss")
(##include "../chez/collections.ss")
(##include "../chez/seq.ss")
(##include "rt-core.ss")

;; regex needs regex-translate.ss (pure; rt.ss used to preload it from java/).
(##include "../chez/java/regex-translate.ss")
(##include "../chez/regex.ss")
(##include "../chez/atoms.ss")
(##include "../chez/refs.ss")
(##include "../chez/predicates.ss")
(##include "../chez/converters.ss")
(##include "../chez/transients.ss")
(##include "../chez/natives-seq.ss")
(##include "../chez/printing.ss")
(##include "../chez/natives-coll.ss")
(##include "../chez/natives-num.ss")
(##include "../chez/multimethods.ss")
(##include "../chez/java/class-hierarchy.ss")
(##include "records-gambit.ss")  ;; GENERATED from records.ss (make gambitgen) — phase wall, see gen-records.ss
(##include "../chez/java/records-interop.ss")
(##include "../chez/natives-meta.ss")
(##include "../chez/java/host-class.ss")
(##include "../chez/dynamic-var-defaults.ss")
(##include "../chez/host-table.ss")
(##include "../chez/lazy-bridge.ss")
(##include "../chez/natives-transduce.ss")
(##include "../chez/vars.ss")

;; ---- smoke ---------------------------------------------------------------
;; Must exercise a LAZY seq (jolt-concat / jolt-map), not just jolt-first on a
;; vector — the lazy force path is where jolt-mt? and the cseq tail thunks live.

(write (jolt-vector 1 2 3))
(newline)
(write (jolt-hash-map 'a 1 'b 2))
(newline)
(write (jolt-hash-set 1 2 3))
(newline)
(write (jolt= (jolt-vector 1 2) (jolt-vector 1 2)))
(newline)
(write (jolt-first (jolt-vector 10 20 30)))
(newline)
;; lazy: a string seq is built from cseq-lazy tail thunks (str->seq); forcing
;; it walks seq-more's (not jolt-mt?) path. jolt-concat/map wrap everything in
;; jolt-make-lazy-seq (lazy-bridge.ss) and land in the kernel-test once that
;; file boots.
(write (jolt-count (jolt-seq "abcde")))
(newline)
(write (jolt-seq (jolt-seq "abcde")))
(newline)
(display "boot: values+hasheq+collections+seq+rt-core OK\n")
