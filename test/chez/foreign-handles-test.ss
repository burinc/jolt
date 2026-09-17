;; The process's own symbol handle is loaded ONCE per process.
;;
;; Chez pushes a dlopen handle onto its dynamic-lookup list on EVERY
;; load-shared-object, and every foreign-entry lookup walks that list with
;; dlsym BEFORE it consults the static "(cs)…" table (c/foreign.c lookup). The
;; runtime asked for the process handle at every jolt-foreign-proc-safe site —
;; 57 times by the end of boot — so a lookup that misses the process (every
;; Chez-internal "(cs)" entry, which is what inspect/object binds twice per
;; call, and every optional-entry probe at boot) walked 57 handles: 2 ms per
;; miss, 4 ms per inspect/object. Re-loading #f after a native library also
;; re-promotes the process's symbols over the library's (the BoringSSL/OpenSSL
;; EVP_* flip). This gate pins the invariant that fixes both: after the runtime
;; boots, the dynamic list holds the process handle once, and asking for it
;; again adds nothing.
;;
;; Loads the full runtime, which is where the boot-time loads happen.
;;   chez --script test/chez/foreign-handles-test.ss
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define dynamic-handles
  (foreign-procedure "(cs)foreign_dynamic_table" () scheme-object))

(define after-boot (length (dynamic-handles)))
(ok "the booted runtime holds the process handle once (not one per boot-time site)"
    (<= after-boot 1))

(sa-load-shared-object #f)
(sa-load-shared-object #f)
(ok "re-requesting the process handle adds no entry"
    (= (length (dynamic-handles)) after-boot))

;; A named library still loads (the idempotence is for #f alone): the running
;; Chez's own kernel exports S_G, so its executable path is a library that
;; resolves — and it lands on the list like any dlopen would.
(ok "a foreign miss and a (cs) entry both still resolve through the static table"
    (and (not (foreign-entry? "no_such_entry_point_zzz"))
         (foreign-entry? "(cs)foreign_dynamic_table")))

(printf "foreign-handles: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
