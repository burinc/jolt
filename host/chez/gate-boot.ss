;; gate-boot.ss — the runtime boot preamble every gate script shares.
;;
;;   (import (chezscheme))
;;   (load "host/chez/gate-boot.ss")
;;   … gate-specific code …
;;
;; Loading the runtime's six preamble files from Chez source costs ~1.3s of a
;; pass gate's ~1.5s runtime, paid two dozen times over in `make ci` and on every
;; single-gate run while iterating. `make gateboot` precompiles exactly this
;; preamble to target/dev/gate.so, which loads in ~0.2s; when that image is
;; present and newer than every file that went into it, load it instead.
;;
;; Purely an optimization. With no image, or a stale one, the literal loads below
;; run and the gate behaves identically — verified byte-identical output across
;; all 24 gates both ways. Nothing takes gateboot as a prerequisite, so CI is
;; unaffected unless someone builds it.
;;
;; It cannot reuse target/dev/flat.so (the bin/jolt dev boot cache): that image
;; also loads loader.ss, which turns `require` into real file loading, and the
;; gates deliberately stop at compile-eval.ss so their alias-only `require` keeps
;; working. See loader.ss's header.
;;
;; The literal loads are bld-runtime-manifest's prefix through 'compile-eval, and
;; manifest-check.sh pins them against it — make-gateboot.ss generates the image
;; from that same manifest prefix, so the two cannot drift. They stay literal
;; here for the reason cli.ss's do: loading the runtime through a loop changes
;; the visibility of the loaded files' top-level defines.

(load "host/chez/gate-boot-fresh.ss")

;; JOLT_GATEBOOT=1 announces which path was taken, mirroring JOLT_DEVCACHE for
;; the bin/jolt image — the only way to tell from the outside, since both paths
;; produce identical behavior.
(if (gate-boot-image-fresh? "target/dev/gate.so" "target/dev/gate.inputs")
    (begin
      (when (let ((m (getenv "JOLT_GATEBOOT"))) (and m (not (string=? m ""))))
        (display "gateboot: using target/dev/gate.so\n" (current-error-port)))
      (load "target/dev/gate.so"))
    (begin
      (load "host/chez/scheme-adapter-runtime.ss")  ; before rt.ss: macros + top-levels in rt.ss/java/*.ss call sa-*
      (load "host/chez/rt.ss")
      (set-chez-ns! "clojure.core")
      (load "host/chez/seed/prelude.ss")
      (load "host/chez/post-prelude.ss")
      (set-chez-ns! "user")
      (load "host/chez/host-contract.ss")
      (load "host/chez/seed/image.ss")
      (load "host/chez/compile-eval.ss")))  ; manifest prefix ends here
