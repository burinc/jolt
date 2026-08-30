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
;; MAKER is the optional sixth argument: (lambda (free…) <the literal>), the one
;; code object every instance of that site comes from. The dump side calls it
;; once with distinct sentinels to learn which closure slot holds which free
;; name, because Chez hands the captures back by POSITION and the names that say
;; which is which are inspector information a release build does not generate.
;; Slot 5 caches that permutation once derived; #f until then, and 'none when the
;; site has no maker or the probe could not be read.
;;
;; A #f in the live-names position means "no live-names" — a caller passing a
;; maker has to fill the fifth argument to reach the sixth.
(define (image-register-fn-form! name form ns free-names . rest)
  (let* ((lv (if (null? rest) #f (car rest)))
         (mk (if (or (null? rest) (null? (cdr rest))) #f (cadr rest))))
    (jolt-with-mutex fn-form-tbl-mu
      (hashtable-set! fn-form-tbl name
                      (vector form ns free-names
                              (if (or (not lv) (jolt-nil? lv)) free-names lv)
                              mk
                              #f))))
  jolt-nil)

;; Attach a site's maker to its registration. Called from inside the form's own
;; cache-cell scope, after image-register-fn-form! has created the entry at the
;; top of the form — the maker closes over that scope's cells, so it cannot be
;; built where the registration is.
(define (image-fn-form-maker! name mk)
  (jolt-with-mutex fn-form-tbl-mu
    (let ((reg (hashtable-ref fn-form-tbl name #f)))
      (when (and reg (fx>? (vector-length reg) 4))
        (vector-set! reg 4 mk))))
  jolt-nil)

(define (image-fn-form-maker reg) (and (fx>? (vector-length reg) 4) (vector-ref reg 4)))
(define (image-fn-form-layout reg) (and (fx>? (vector-length reg) 5) (vector-ref reg 5)))
(define (image-fn-form-layout-set! reg v)
  (when (fx>? (vector-length reg) 5) (vector-set! reg 5 v)))

;; The registration vector (form ns free-names live-names) or #f when unknown —
;; the R2 dump-side lookup.
(define (image-fn-form-lookup name)
  (hashtable-ref fn-form-tbl name #f))
