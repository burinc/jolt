;; fn-form-registry.ss — map unique anonymous-fn names (jfn$<ns>$<def>$<n>) back
;; to their source form, defining ns, and free local names, so a closure
;; captured in a state image can be reconstructed as code (the R2/R3 write/read
;; sides of the image work). Registered at load time by emitted code, one
;; (image-register-fn-form! …) sibling per anon literal in a non-system
;; namespace; re-registering the same name overwrites (a re-required file re-emits
;; the same deterministic names).

;; Registered by emitted code at load, one call per anon literal, and namespaces
;; now load in parallel — so this runs on several threads at once. A strong
;; hashtable does not corrupt under that, but concurrent inserts do LOSE each
;; other (var-table measured 8.6k of 240k dropped), and a lost registration is a
;; closure the image writer can no longer reconstruct as code. Writes take the
;; mutex; the single-key lookup below stays unlocked, which is safe here for the
;; reasons set out at var-table in rt.ss.
(define fn-form-tbl (make-hashtable string-hash string=?))
(define fn-form-tbl-mu (make-mutex))


;; LIVE-NAMES is the optional fifth argument, and only a SPLICED copy of a
;; literal has one. free-names are the names the source form uses, so they are
;; what the restore wrapper binds; in a copy the inline pass made, those names no
;; longer describe what the compiled closure holds — a binder was renamed, a
;; caller local was substituted, or a constant argument was folded in and there
;; is no capture left at all. live-names says, per free name and in the same
;; order, either the variable name to recover from the live closure (a string) or
;; a one-element vector holding the constant value. Defaults to free-names, which
;; is what every un-spliced registration means.
(define (image-register-fn-form! name form ns free-names . live-names)
  (jolt-with-mutex fn-form-tbl-mu
    (hashtable-set! fn-form-tbl name
                    (vector form ns free-names
                            (if (null? live-names) free-names (car live-names)))))
  jolt-nil)

;; The registration vector (form ns free-names live-names) or #f when unknown —
;; the R2 dump-side lookup.
(define (image-fn-form-lookup name)
  (hashtable-ref fn-form-tbl name #f))
