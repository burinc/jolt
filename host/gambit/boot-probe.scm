;; boot-probe.scm — `make gambitboot` includes the generated full-profile boot
;; and prints BOOT-OK. Every ##include'd chez file runs its top level here, so a
;; Chez-only name reaching a shared file fails in this gate instead of hanging
;; the shipped web REPL at boot (values.ss taking the keyword-table lock at the
;; first keyword intern did exactly that to jolt-web.js, and nothing caught it:
;; gambitcheck exercises the adapter, not the boot).
(##include "boot-full.ss")
(display "BOOT-OK\n")
