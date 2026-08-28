;; run-case-isolation.ss — snapshot the world once, restore it between cases.
;;
;; A gate that evaluates many independent jolt expressions in one process needs
;; each one to start from the same world: a row that defs a var, requires a
;; namespace, derives into the global hierarchy or extends a host class must not
;; decide what the next row sees. Loaded AFTER the gate has done its own setup
;; (source roots, any preloaded namespace) — the snapshot is taken here, so
;; whatever the gate established beforehand is part of the stable base.
;;
;; Shared by run-unit.ss and run-documented.ss. run-corpus.ss keeps its own,
;; narrower copy: it deliberately does not roll back the loader dedup.
;; --- per-case isolation (snapshot the world after setup, restore each case) -------
(define zj-base (let ((h (make-hashtable string-hash string=?)))
  (vector-for-each (lambda (k) (hashtable-set! h k #t)) (hashtable-keys var-table)) h))
(define zj-roots '())
(vector-for-each (lambda (k) (let ((c (hashtable-ref var-table k #f)))
                   (when c (set! zj-roots (cons (cons c (var-cell-root c)) zj-roots)))))
                 (hashtable-keys var-table))
(define (zj-snap ht) (let ((h (make-hashtable string-hash string=?)))
  (vector-for-each (lambda (k) (hashtable-set! h k #t)) (hashtable-keys ht)) h))
(define (zj-prune! ht base) (vector-for-each
  (lambda (k) (unless (hashtable-ref base k #f) (hashtable-delete! ht k))) (hashtable-keys ht)))
(define zj-ns-base (zj-snap ns-registry))
(define zj-type-base (zj-snap type-registry))
(define zj-loaded-base (zj-snap loaded-ns))
(define zj-ghier (var-cell-lookup "clojure.core" "global-hierarchy"))
;; the #-dispatch reader macro table (reader.ss) is process-wide like the class
;; extensions below, and it decides how the NEXT case's source reads — a row that
;; registers #% and does not take it off would rewrite every later row's #%.
(define zj-dispatch-base rdr-dispatch-macros)
(define (zj-reset!)
  ;; a var-table mutation, so it takes var-table-mu like every other one (rt.ss).
  ;; This harness is single-threaded, but the invariant is easier to keep if it
  ;; has no exceptions.
  (jolt-with-mutex var-table-mu
    (vector-for-each (lambda (k) (unless (hashtable-ref zj-base k #f) (hashtable-delete! var-table k)))
                     (hashtable-keys var-table)))
  (rebuild-ns-cells-index!)   ; the prune bypassed the ns->cells buckets (rt.ss)
  (for-each (lambda (cr) (unless (eq? (var-cell-root (car cr)) (cdr cr))
                           (var-cell-root-set! (car cr) (cdr cr)))) zj-roots)
  (jolt-with-mutex ns-registry-mu (zj-prune! ns-registry zj-ns-base))  ; same rule as var-table (ns.ss)
  ; the protocol tree AND its by-method index, through the one entry
  ; point that keeps them in step (protocols.ss)
  (prune-type-registry! (lambda (k) (hashtable-ref zj-type-base k #f)))
  ;; roll back the loader dedup — a row's require must reload for the next row,
  ;; since the vars it defined were just pruned from var-table
  (vector-for-each (lambda (k) (unless (hashtable-ref zj-loaded-base k #f)
                                 (ldr-unmark-loaded! k)))
                   (hashtable-keys loaded-ns))
  (hashtable-clear! ns-alias-table)
  (hashtable-clear! ns-refer-table)
  (hashtable-clear! ns-refer-all-table)
  (hashtable-clear! ns-refer-all-exclude-table)
  (hashtable-clear! ns-core-exclude-table)
  ;; class extensions are process-wide by design (java/class-extensions.ss), so a
  ;; row that overrides java.io.File/getPath would otherwise decide what every
  ;; later row sees.
  (class-ext-reset!)
  (set! rdr-dispatch-macros zj-dispatch-base)
  (clear-thread-interrupt!)   ; a case that set the runner thread's interrupt flag mustn't leak
  (when zj-ghier (jolt-invoke (var-deref "clojure.core" "reset!")
                   (var-cell-root zj-ghier) (jolt-invoke (var-deref "clojure.core" "make-hierarchy"))))
  (set-chez-ns! "user"))
