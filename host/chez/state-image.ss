;; state-image.ss — dump a running program's state to a file and read it back.
;;
;; This is a STATE image, not a process image. Chez removed save-heap, and
;; fasl-write rejects every procedure, continuation, port and thread, so nothing
;; here can capture in-flight execution. What travels is the value graph.
;;
;; The body is pure data by construction: a procedure is written as the NAME of
;; the var it is bound to, never as code. Because the stream then holds no code
;; objects, Chez stamps it machine-type 0 (machine-independent), which is what
;; makes restoring on another architecture work.
;;
;; File layout — three fasl objects written back-to-back on one port:
;;   1. header    : vector, version + compat fields
;;   2. externals : list of descriptors, one per object fasl-write refused
;;   3. body      : the graph, with each refused object replaced by a placeholder
;; Reading resolves the descriptors first and hands the resulting vector to
;; fasl-read, which fails loudly if the count disagrees with the body.
;;
;; Loaded LAST from rt.ss: needs the collections, the var table, the printers,
;; and proc-name-tbl (rt.ss) for the procedure -> "ns/name" direction.

(define jolt-image-format-version 1)

;; --- classification -----------------------------------------------------------
;; An eq hashtable is the ONE hashtable kind Chez can fasl; eqv/equal/string-hash
;; tables carry their hash and equivalence procedures, so they need descriptors.
(define (image-eq-hashtable? x)
  (and (hashtable? x) (eq? (hashtable-equivalence-function x) eq?)))

;; Objects that must not travel as raw fasl. Two distinct reasons:
;;
;;  - Chez REFUSES them (procedures, non-eq hashtables, ports, threads).
;;  - Chez would happily write them, but the copy that comes back is WRONG.
;;    Keywords are interned (values.ss) and jolt map lookup compares them by
;;    identity, so a fasl-copied keyword is a key nothing can ever find: the map
;;    prints and counts correctly but every (:k m) returns nil and = is false.
;;    They are re-interned through the externals path instead. Their cached
;;    khash is content-derived, so re-interning yields an equal hash and the
;;    restored trie stays valid.
;;
;; Symbols are deliberately NOT here: they are not interned and compare by
;; ns/name, so a copy behaves correctly as a map key.
(define (image-external? x)
  (or (procedure? x)
      (keyword? x)
      (and (hashtable? x) (not (image-eq-hashtable? x)))
      (port? x)
      (thread? x)))

;; --- path-tracking walker ------------------------------------------------------
;; fasl-write's externals-pred sees objects but not where they live, and an
;; "unserializable object" error with no path is close to useless on a real
;; application state graph. So the walk is ours: it classifies every reachable
;; object and, for anything it cannot encode, records the route to it.

(define (image-path->string path)
  ;; path is accumulated innermost-first
  (let loop ((p (reverse path)) (acc ""))
    (if (null? p)
        (if (string=? acc "") "<root>" acc)
        (loop (cdr p)
              (if (string=? acc "") (car p) (string-append acc " -> " (car p)))))))

(define (image-describe-obj x)
  (cond
    ((procedure? x) "#<procedure>")
    ((port? x) "#<port>")
    ((thread? x) "#<thread>")
    ((hashtable? x) "#<hashtable>")
    (else (call/cc (lambda (k)
            (with-exception-handler (lambda (e) (k "#<object>"))
              (lambda () (jolt-pr-readable x))))))))

;; Walk the graph. Calls (visit obj path) on every object; collects nothing
;; itself. Cycle-safe via an eq table of in-progress/seen nodes.
(define (image-walk root visit)
  (let ((seen (make-eq-hashtable)))
    (let walk ((x root) (path '()))
      (unless (or (null? x) (boolean? x) (number? x) (char? x)
                  (symbol? x) (string? x) (bytevector? x))
        (if (hashtable-ref seen x #f)
            #t
            (begin
              (hashtable-set! seen x #t)
              (visit x path)
              (cond
                ;; jolt collections first — their internal trie shape would make
                ;; useless paths, so walk them as maps/vectors/sets instead.
                ((pmap? x)
                 (pmap-fold-fwd x (lambda (k v acc)
                                    (walk k (cons "<key>" path))
                                    (walk v (cons (image-describe-obj k) path))
                                    acc)
                                #f))
                ((pset? x)
                 (pset-fold x (lambda (e acc) (walk e (cons (image-describe-obj e) path)) acc) #f))
                ((pvec? x)
                 (let ((n (pvec-count x)))
                   (let loop ((i 0))
                     (when (fx<? i n)
                       (walk (pvec-nth-d x i jolt-nil) (cons (number->string i) path))
                       (loop (fx+ i 1))))))
                ((var-cell? x)
                 (walk (var-cell-root x)
                       (cons (string-append "#'" (var-cell-ns x) "/" (var-cell-name x)) path)))
                ;; cover val + watches + validator — everything fasl-write sees
                ((jolt-atom? x)
                 (walk (jolt-atom-val x) (cons "@" path))
                 (for-each (lambda (w) (walk w (cons "@watch" path)))
                           (jolt-atom-watches x))
                 (walk (jolt-atom-validator x) (cons "@validator" path)))
                ((pair? x) (walk (car x) (cons "car" path)) (walk (cdr x) (cons "cdr" path)))
                ((vector? x)
                 (let ((n (vector-length x)))
                   (let loop ((i 0))
                     (when (fx<? i n)
                       (walk (vector-ref x i) (cons (number->string i) path))
                       (loop (fx+ i 1))))))
                ((and (hashtable? x) (hashtable-mutable? x))
                 (let-values (((ks vs) (hashtable-entries x)))
                   (let loop ((i 0))
                     (when (fx<? i (vector-length ks))
                       (walk (vector-ref vs i) (cons (image-describe-obj (vector-ref ks i)) path))
                       (loop (fx+ i 1))))))
                ;; generic record: walk declared fields by name. Covers user
                ;; defrecords, lazy seqs, refs, everything not special-cased.
                ((and (record? x) (record-rtd x))
                 (let* ((rtd (record-rtd x))
                        (names (record-type-field-names rtd))
                        (n (vector-length names)))
                   (let loop ((i 0))
                     (when (fx<? i n)
                       (let ((v (call/cc (lambda (k)
                                  (with-exception-handler (lambda (e) (k #f))
                                    (lambda () ((record-accessor rtd i) x)))))))
                         (walk v (cons (symbol->string (vector-ref names i)) path)))
                       (loop (fx+ i 1))))))
                (else #t)))))))
  jolt-nil)

;; --- externals: encode one refused object as data ------------------------------
;; Returns a descriptor (pure data) or #f when the object cannot be encoded.
;; Handlers registered from jolt get first refusal, so an application can teach
;; the encoder about its own resources.
(define image-handlers '())   ; list of (pred dump restore)

(define (jolt-image-register-handler! pred dump restore)
  (set! image-handlers (cons (list pred dump restore) image-handlers))
  jolt-nil)

(define (image-handler-for x)
  (let loop ((hs image-handlers))
    (cond ((null? hs) #f)
          ((jolt-truthy? (jolt-invoke (caar hs) x)) (car hs))
          (else (loop (cdr hs))))))

(define (image-encode-external x)
  (let ((h (image-handler-for x)))
    (cond
      (h (list 'handler (jolt-invoke (cadr h) x)))
      ((keyword? x) (list 'kw (keyword-t-ns x) (keyword-t-name x)))
      ((procedure? x)
       (let ((p (hashtable-ref proc-name-tbl x #f)))
         ;; A named fn travels as its var's name. A bare closure has no stable
         ;; identity to write, so it is refused here and reported with its path.
         (and p (list 'fn-ref (car p) (cdr p)))))
      ;; A non-eq hashtable is refused rather than described. Its contents would
      ;; have to ride in the descriptor stream, which is written WITHOUT an
      ;; externals-pred — so a table holding procedures would blow up there,
      ;; outside the mechanism that is supposed to catch it. Refusing keeps the
      ;; failure inside the path-reporting path. (A sorted coll never reaches
      ;; this arm: the transformer intercepts the wrapper upstream.)
      (else #f))))

(define (image-decode-external d)
  (case (car d)
    ;; back through the intern table, so the restored keyword IS the live one
    ((kw) (keyword (cadr d) (caddr d)))
    ((fn-ref)
     (let ((c (var-cell-lookup (cadr d) (caddr d))))
       (if (and c (not (jolt-var-unbound? (var-cell-root c))))
           (var-cell-root c)
           (jolt-throw (jolt-ex-info
                         (string-append "image: no var " (cadr d) "/" (caddr d)
                                        " in this build to restore a function reference")
                         jolt-nil)))))
    ((handler)
     (let loop ((hs image-handlers))
       (if (null? hs)
           (jolt-throw (jolt-ex-info "image: no handler registered to restore a resource" jolt-nil))
           ;; restore fns are tried in registration order; the first that accepts wins
           (let ((r (call/cc (lambda (k)
                      (with-exception-handler (lambda (e) (k 'image-no))
                        (lambda () (jolt-invoke (caddr (car hs)) (cadr d))))))))
             (if (eq? r 'image-no) (loop (cdr hs)) r)))))
    (else (jolt-throw (jolt-ex-info "image: unknown external descriptor" jolt-nil)))))

;; --- R2: substitution pre-pass --------------------------------------------------
;; A var root a handler claimed, replaced by the handler's plain-data payload.
;; Substituting through the transformer (not only at world var roots) is what
;; lets a handler claim a resource at ANY depth: the payload rides in the body,
;; so a function inside it becomes a fn-ref or an image-fnsrc and a keyword
;; inside it gets re-interned, exactly as if the application had stored that
;; data directly. Routing it through a descriptor instead would put it in the
;; one part of the file that cannot carry either.
(define-record-type image-handled (fields payload) (nongenerative image-handled-v1))

;; An anonymous closure a state image can rebuild from source (write side here;
;; R3 reconstructs). name is the unique jfn$<ns>$<def>$<n> the backend bound
;; the literal under — what Chez's inspector reports for the live closure;
;; form/ns/free-names come from the load-time registration (fn-form-registry.ss);
;; free-values are the LIVE captured values recovered by name through the
;; inspector and pushed back through this same pass, so a captured mutable cell
;; cycles into the written graph instead of pointing into the live one. Rides in
;; the BODY: its fields are walked by fasl, so a keyword inside re-interns, a
;; named fn goes fn-ref, and a nested anon closure was already substituted.
(define-record-type image-fnsrc
  (fields name form ns free-names (mutable free-values))
  (nongenerative image-fnsrc-v1))

;; A sorted map/set a state image rebuilds from the public constructors: kind
;; ('map | 'set), the ORIGINAL user comparator (jolt-nil for natural order), and
;; the entries in seq order — (key . val) pairs for a map, elements for a set.
;; The write-side arm on htable-sorted? intercepts the wrapper before the
;; externals path ever sees its internal comparator hashtable; cmp-fn composes
;; with the proc verdict (named fn -> fn-ref, registered literal -> image-fnsrc,
;; else refuse-with-path) and entries walk as plain data. Restore re-mints
;; through sorted-map(-by)/sorted-set(-by) and folds the entries in ordered.
(define-record-type image-sorted
  (fields kind cmp-fn entries)
  (nongenerative image-sorted-v1))

;; backend_scheme.clj's munge-name, exposed so the write side munges registered
;; free names with EXACTLY the mapping the emitter used. Deref'd at dump time,
;; when the compiler core is loaded; the stateimage gate pins agreement between
;; this seam and the backend.
(def-var! "jolt.host" "munge-name"
  (lambda (s) (jolt-invoke1 (var-deref "jolt.backend-scheme" "munge-name") s)))

(define (image-munge s) (jolt-invoke1 (var-deref "jolt.host" "munge-name") s))

(define (image-string-prefix? s pre)
  (let ((n (string-length s)) (m (string-length pre)))
    (and (fx>=? n m) (string=? (substring s 0 m) pre))))

;; Carry the meta side-table entry from a rebuilt object's original (the weak
;; table in natives-meta.ss), so image-collect-meta keys the SUBSTITUTED
;; objects — the ones fasl-write actually sees.
(define (image-meta-copy! orig new)
  (when (not (eq? orig new))
    (let ((m (call/cc (lambda (k)
              (with-exception-handler (lambda (e) (k jolt-nil))
                (lambda () (jolt-meta orig)))))))
      (unless (jolt-nil? m)
        (hashtable-set! meta-table new m)))))

;; A procedure's substitution decision, shared by both modes so scan and dump
;; cannot disagree. Returns the registration (name . (form ns free-names)) for
;; a registered jfn$ literal, or #f when the closure must refuse: no inspector
;; name, not jfn$-prefixed, or no registration (core-tier closures, bare
;; unregistered lambdas, no-inspector builds).
(define (image-fnsrc-probe x)
  (guard (e (#t #f))
    (let* ((io (inspect/object x))
           (code (io 'code))
           (nm (and code (code 'name))))
      (and (string? nm)
           (image-string-prefix? nm "jfn$")
           (let ((reg (image-fn-form-lookup nm)))
             (and reg (cons nm reg)))))))

;; The one procedure decision, consumed by BOTH modes so scan and dump cannot
;; disagree. Precedence: a handler is claimed in the walk's outer cond before
;; this arm ever runs; then a named var-root fn (fn-ref — restore as the live
;; fn); then a registered jfn$ literal (returns (name . registration)); else
;; 'refuse. scan and dump branch on the same verdict, never on their own copies
;; of the rules.
(define (image-proc-verdict x)
  (cond
    ((hashtable-ref proc-name-tbl x #f) 'fn-ref)
    (else (or (image-fnsrc-probe x) 'refuse))))

;; Recover the LIVE captured values, in REGISTERED free-name order, by munging
;; each original name and matching it against the inspector's munged names. A
;; registered name the inspector does not report (cp0 dropped a dead capture)
;; binds jolt-nil. Every recovered value runs back through the transformer so
;; the written graph never points into the live one. Any inspector/munge
;; failure returns 'image-no (the caller refuses) — never a crash, never a
;; silent partial; the free-value walk itself is unguarded so a refusal on a
;; nested free value keeps its own, more specific path.
(define (image-recover-free-values x frees walk path)
  (call/cc
    (lambda (refuse)
      (define (refuse-on-fail thunk)
        (guard (e (#t (refuse 'image-no))) (thunk)))
      (let* ((io (refuse-on-fail (lambda () (inspect/object x))))
             (n (refuse-on-fail (lambda () (io 'length))))
             (tbl (make-hashtable string-hash string=?)))
        (let loop ((i 0))
          (when (and n (fx<? i n))
            (let* ((vo (refuse-on-fail (lambda () (io 'ref i))))
                   (nm0 (refuse-on-fail (lambda () (vo 'name))))
                   (nm (if (symbol? nm0) (symbol->string nm0) nm0))
                   (v (refuse-on-fail (lambda () ((vo 'ref) 'value)))))
              (when (string? nm)
                (hashtable-set! tbl nm v)))
            (loop (fx+ i 1))))
        (let loop ((s (jolt-seq frees)) (acc '()))
          (if (jolt-nil? s)
              (list->vector (reverse acc))
              (let* ((orig (jolt-first s))
                     (val (hashtable-ref tbl
                                         (refuse-on-fail (lambda () (image-munge orig)))
                                         'image-missing)))
                ;; A name the source references but the compiled closure does not
                ;; carry: const-folding baked its value into the code (a let-bound
                ;; constant, a provably-dead branch), so the value is UNRECOVERABLE
                ;; here while the stored source still needs it. Binding nil instead
                ;; would restore a closure that silently computes with nil — refuse,
                ;; naming the capture, so the failure is at dump time and actionable.
                (if (eq? val 'image-missing)
                    (refuse (cons 'image-folded orig))
                    (loop (jolt-next s)
                          (cons (walk val (cons (string-append "free:" orig) path))
                                acc))))))))))

;; The image-fnsrc record is memoized BEFORE its free values are recovered, so
;; a capture cycle (closure -> atom -> closure) finds this record in the memo
;; instead of recursing forever; the free-values field is mutable for that fill.
(define (image-fnsrc-build x reg walk memo path)
  (let ((r (make-image-fnsrc (car reg) (vector-ref (cdr reg) 0)
                             (vector-ref (cdr reg) 1) (vector-ref (cdr reg) 2)
                             (vector))))
    (hashtable-set! memo x r)
    (let ((fvs (image-recover-free-values x (vector-ref (cdr reg) 2) walk path)))
      (cond
        ((vector? fvs)
         (image-fnsrc-free-values-set! r fvs)
         (image-meta-copy! x r)
         r)
        ((and (pair? fvs) (eq? (car fvs) 'image-folded))
         (jolt-throw (jolt-ex-info
                       (string-append "image: cannot write " (image-describe-obj x)
                                      " at " (image-path->string path)
                                      ": captured local '" (cdr fvs)
                                      "' was optimized into the compiled code, so its value"
                                      " cannot be recovered from the live closure —"
                                      " store a named fn, or the data to rebuild one")
                       jolt-nil)))
        (else
         (jolt-throw (jolt-ex-info
                       (string-append "image: cannot write " (image-describe-obj x)
                                      " at " (image-path->string path))
                       jolt-nil)))))))

;; A condition's human text, best effort — jolt ex-info and raw Chez
;; conditions both pass through here on the restore failure path.
(define (image-condition-text e)
  (cond
    ((and (jolt-ex-info-record? e) (string? (jolt-ex-info-record-message e)))
     (jolt-ex-info-record-message e))
    ((condition? e) (condition->message-string e))
    (else "error")))

;; The compile spine, reached through the top level at CALL time —
;; compile-eval.ss loads after this file, and a tree-shaken build that
;; dropped the compiler has no binding at all: refuse by name instead of
;; surfacing an unbound-variable error mid-restore.
(define (image-compile-eval-seam)
  (let ((ce (guard (e (#t #f)) (top-level-value 'jolt-compile-eval-form))))
    (and (procedure? ce) ce)))

;; Rebuild one fn source record into a live closure: compile
;; (fn* [free-names…] form) in the record's defining ns, then apply it to
;; the restored free values. The wrapper params SHADOW the outer-scope
;; names the body references — that is what reconstructs the lexical
;; environment the closure was compiled in.
(define (image-eval-fnsrc x tfvs)
  (let ((ce (image-compile-eval-seam)))
    (unless ce
      (jolt-throw (jolt-ex-info
                    (string-append "image: this build has no compiler; cannot rebuild fn "
                                   (image-fnsrc-name x) " from source"
                                   " (a tree-shaken build that dropped the compiler"
                                   " cannot restore images holding anonymous fns)")
                    jolt-nil)))
    (let* ((frees (image-fnsrc-free-names x))
           (params (let loop ((s (jolt-seq frees)) (acc '()))
                     (if (jolt-nil? s)
                         (reverse acc)
                         (loop (seq-more s) (cons (jolt-symbol #f (seq-first s)) acc)))))
           (wrapper (list->cseq (list (jolt-symbol #f "fn*")
                                      (apply jolt-vector params)
                                      (image-fnsrc-form x))))
           (wfn (guard (e (#t (jolt-throw (jolt-ex-info
                                            (string-append "image: cannot compile fn "
                                                           (image-fnsrc-name x) " in ns "
                                                           (image-fnsrc-ns x) ": "
                                                           (image-condition-text e))
                                            jolt-nil))))
                  (ce wrapper (image-fnsrc-ns x)))))
      (apply jolt-invoke wfn tfvs))))

;; Restore fns are tried in registration order; the first that accepts wins —
;; the same contract the externals handler path has always had.
(define (image-restore-handler payload)
  (let loop ((hs image-handlers))
    (if (null? hs)
        (jolt-throw (jolt-ex-info "image: no handler registered to restore a resource" jolt-nil))
        (let ((r (call/cc (lambda (k)
                   (with-exception-handler (lambda (e) (k 'image-no))
                     (lambda () (jolt-invoke (caddr (car hs)) payload)))))))
          (if (eq? r 'image-no) (loop (cdr hs)) r)))))

;; The one traversal skeleton in two modes, so scan and dump share the arms and
;; cannot disagree about what is writable. 'rebuild returns a substituted copy
;; of the graph — identity for any subtree that holds nothing to substitute,
;; dirtiness tracked bottom-up — and throws jolt-ex-info on the first object
;; the write path cannot encode, with the route to it; 'report performs the
;; same descent and decisions but records a finding via (report! obj path)
;; instead of building or throwing. The memo doubles as the cycle guard:
;; mutable cells (atoms, var cells, mutable hashtables, fnsrc records) are
;; memoized before their children fill in, so a cycle through them resolves.
;; The read side is 'rebuild plus fnsrc/handled reconstruction, so the two
;; modes share every container arm; only report diverges.
(define (image-rebuild-mode? mode)
  (or (eq? mode 'rebuild) (eq? mode 'restore)))

(define (image-graph-process root mode report!)
  (let ((memo (make-eq-hashtable)))
    (letrec ((walk
              (lambda (x path)
                (cond
                  ;; scalar leaves can never hold a procedure
                  ((or (null? x) (boolean? x) (number? x) (char? x)
                       (symbol? x) (string? x) (bytevector? x))
                   (if (image-rebuild-mode? mode) x #t))
                  ((hashtable-ref memo x #f) =>
                   (lambda (m) (if (image-rebuild-mode? mode) m #t)))
                  (else
                   (cond
                     ;; R3 read side: image-owned records rebuild first, before
                     ;; user handlers could claim them. A stored fn source record
                     ;; becomes a live closure; a stored handler payload is handed
                     ;; to the registered restore fn.
                     ((and (eq? mode 'restore) (image-fnsrc? x))
                      (walk-fnsrc-restore x path))
                     ((and (eq? mode 'restore) (image-handled? x))
                      (walk-handled-restore x path))
                     ((and (eq? mode 'restore) (image-sorted? x))
                      (walk-sorted-restore x path))
                     ;; handlers claim at any depth, before anything else
                     ((and (pair? image-handlers) (image-handler-for x)) =>
                      (lambda (h)
                        (if (image-rebuild-mode? mode)
                            (let ((r (make-image-handled (jolt-invoke (cadr h) x))))
                              (hashtable-set! memo x r)
                              r)
                            (begin (hashtable-set! memo x #t) #t))))
                     ;; a named fn stays in place: the fn-ref external restores
                     ;; it as the live fn (cheaper than source, no form needed).
                     ;; On the READ side a procedure IS an already-restored
                     ;; fn-ref external — force the fn-ref verdict (identity).
                     ((procedure? x)
                      (let ((v (if (eq? mode 'restore) 'fn-ref (image-proc-verdict x))))
                        (cond
                          ((eq? v 'fn-ref)
                           (if (image-rebuild-mode? mode)
                               (begin (hashtable-set! memo x x) x)
                               #t))
                          ((eq? v 'refuse)
                           (if (image-rebuild-mode? mode)
                               (jolt-throw
                                 (jolt-ex-info
                                   (string-append "image: cannot write " (image-describe-obj x)
                                                  " at " (image-path->string path))
                                   jolt-nil))
                               (begin (hashtable-set! memo x #t) (report! x path))))
                          (else
                           ;; v is a (name . registration) pair. Report mode must
                           ;; agree with what the build would do, so it prechecks
                           ;; recoverability (a const-folded capture refuses).
                           (if (image-rebuild-mode? mode)
                               (image-fnsrc-build x v walk memo path)
                               (let ((probe (image-recover-free-values
                                              x (vector-ref (cdr v) 2)
                                              (lambda (fv p) #t) path)))
                                 (hashtable-set! memo x #t)
                                 (if (vector? probe) #t (report! x path))))))))
                     (else
                       ;; non-procedure externals the descriptor machinery
                       ;; cannot encode (non-eq hashtables, ports, threads):
                       ;; report them in scan; rebuild leaves them for the
                       ;; externals stage, which refuses with the path. A
                       ;; keyword and a named fn's fn-ref encode fine.
                       (when (and (eq? mode 'report)
                                  (image-external? x)
                                  (not (image-encode-external x)))
                         (hashtable-set! memo x #t)
                         (report! x path))
                       (cond
                         ((pmap? x) (walk-pmap x path))
                         ((pset? x) (walk-pset x path))
                         ((pvec? x) (walk-pvec x path))
                         ((htable-sorted? x) (walk-sorted x path))
                         ((var-cell? x) (walk-var-cell x path))
                         ((jolt-atom? x) (walk-atom x path))
                         ((pair? x) (walk-pair x path))
                         ((vector? x) (walk-vector x path))
                         ((and (hashtable? x) (hashtable-mutable? x))
                          (walk-hashtable x path))
                         ((and (record? x) (record-rtd x))
                          (walk-record x path))
                         (else (if (image-rebuild-mode? mode) x #t)))))))))
             (walk-pmap
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    (let ((entries '()) (dirty #f))
                      (pmap-fold-fwd x
                        (lambda (k v acc)
                          (let* ((wk (walk k (cons "<key>" path)))
                                 (wv (walk v (cons (image-describe-obj k) path))))
                            (set! entries (cons (cons wk wv) entries))
                            (set! dirty (or dirty (not (eq? wk k)) (not (eq? wv v))))
                            acc))
                        #f)
                      (if (hashtable-ref memo x #f)
                          (hashtable-ref memo x #f)
                          (if dirty
                              (let ((nx (apply jolt-hash-map
                                               (apply append
                                                      (map (lambda (e) (list (car e) (cdr e)))
                                                           (reverse entries))))))
                                (hashtable-set! memo x nx)
                                (image-meta-copy! x nx)
                                nx)
                              (begin (hashtable-set! memo x x) x))))
                    (begin
                      (hashtable-set! memo x #t)
                      (pmap-fold-fwd x
                        (lambda (k v acc)
                          (walk k (cons "<key>" path))
                          (walk v (cons (image-describe-obj k) path))
                          acc)
                        #f)
                      #t))))
             (walk-pset
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    (let ((items '()) (dirty #f))
                      (pset-fold x
                        (lambda (e acc)
                          (let ((w (walk e (cons (image-describe-obj e) path))))
                            (set! items (cons w items))
                            (set! dirty (or dirty (not (eq? w e))))
                            acc))
                        #f)
                      (if (hashtable-ref memo x #f)
                          (hashtable-ref memo x #f)
                          (if dirty
                              (let ((nx (apply jolt-hash-set (reverse items))))
                                (hashtable-set! memo x nx)
                                (image-meta-copy! x nx)
                                nx)
                              (begin (hashtable-set! memo x x) x))))
                    (begin
                      (hashtable-set! memo x #t)
                      (pset-fold x (lambda (e acc) (walk e (cons (image-describe-obj e) path)) acc) #f)
                      #t))))
             (walk-sorted
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    ;; write side: substitute to an image-sorted record. The
                    ;; wrapper is immutable data, so there are no cycles to
                    ;; pre-memoize; cmp-fn routes through the shared proc
                    ;; verdict, entries walk as plain data.
                    (let ((map? (htable-sorted-map? x)))
                      (if map?
                          (let ((pairs '()))
                            (let loop ((s (jolt-seq x)))
                              (unless (jolt-nil? s)
                                (let* ((e (jolt-first s))
                                       (k (jolt-nth e 0))
                                       (v (jolt-nth e 1))
                                       (wk (walk k (cons "<key>" path)))
                                       (wv (walk v (cons (image-describe-obj k) path))))
                                  (set! pairs (cons (cons wk wv) pairs)))
                                (loop (jolt-next s))))
                            (let ((r (make-image-sorted 'map
                                       (walk (jolt-ref-get x kw-cmp-fn) (cons "cmp-fn" path))
                                       (list->vector (reverse pairs)))))
                              (hashtable-set! memo x r)
                              (image-meta-copy! x r)
                              r))
                          (let ((items '()))
                            (let loop ((s (jolt-seq x)))
                              (unless (jolt-nil? s)
                                (set! items (cons (walk (jolt-first s)
                                                        (cons (image-describe-obj (jolt-first s)) path))
                                                  items))
                                (loop (jolt-next s))))
                            (let ((r (make-image-sorted 'set
                                       (walk (jolt-ref-get x kw-cmp-fn) (cons "cmp-fn" path))
                                       (list->vector (reverse items)))))
                              (hashtable-set! memo x r)
                              (image-meta-copy! x r)
                              r))))
                    (begin
                      (hashtable-set! memo x #t)
                      (walk (jolt-ref-get x kw-cmp-fn) (cons "cmp-fn" path))
                      (let loop ((s (jolt-seq x)))
                        (unless (jolt-nil? s)
                          (let ((e (jolt-first s)))
                            (if (htable-sorted-map? x)
                                (begin
                                  (walk (jolt-nth e 0) (cons "<key>" path))
                                  (walk (jolt-nth e 1)
                                        (cons (image-describe-obj (jolt-nth e 0)) path)))
                                (walk e (cons (image-describe-obj e) path))))
                          (loop (jolt-next s))))
                      #t))))
             (walk-pvec
              (lambda (x path)
                (let ((n (pvec-count x)))
                  (if (image-rebuild-mode? mode)
                      (let ((items '()) (dirty #f))
                        (let loop ((i 0))
                          (if (fx<? i n)
                              (let* ((v (pvec-nth-d x i jolt-nil))
                                     (w (walk v (cons (number->string i) path))))
                                (set! items (cons w items))
                                (set! dirty (or dirty (not (eq? v w))))
                                (loop (fx+ i 1)))
                              (or (hashtable-ref memo x #f)
                                  (if dirty
                                      (let ((nx (apply jolt-vector (reverse items))))
                                        (hashtable-set! memo x nx)
                                        (image-meta-copy! x nx)
                                        nx)
                                      (begin (hashtable-set! memo x x) x))))))
                      (begin
                        (hashtable-set! memo x #t)
                        (let loop ((i 0))
                          (when (fx<? i n)
                            (walk (pvec-nth-d x i jolt-nil) (cons (number->string i) path))
                            (loop (fx+ i 1))))
                        #t)))))
             (walk-var-cell
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    (let ((nx (make-var-cell (var-cell-ns x) (var-cell-name x)
                                             jolt-nil (var-cell-defined? x))))
                      (hashtable-set! memo x nx)
                      (var-cell-root-set! nx
                        (walk (var-cell-root x)
                              (cons (string-append "#'" (var-cell-ns x) "/" (var-cell-name x)) path)))
                      nx)
                    (begin
                      (hashtable-set! memo x #t)
                      (walk (var-cell-root x)
                            (cons (string-append "#'" (var-cell-ns x) "/" (var-cell-name x)) path))
                      #t))))
             ;; cover val + watches + validator — everything fasl-write sees
             ;; (the scan/dump parity fix)
             (walk-atom
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    (let ((nx (make-jolt-atom jolt-nil '() jolt-nil (make-mutex))))
                      (hashtable-set! memo x nx)
                      (image-meta-copy! x nx)
                      (jolt-atom-val-set! nx (walk (jolt-atom-val x) (cons "@" path)))
                      (jolt-atom-watches-set! nx
                        (map (lambda (w) (walk w (cons "@watch" path)))
                             (jolt-atom-watches x)))
                      (jolt-atom-validator-set! nx
                        (walk (jolt-atom-validator x) (cons "@validator" path)))
                      nx)
                    (begin
                      (hashtable-set! memo x #t)
                      (walk (jolt-atom-val x) (cons "@" path))
                      (for-each (lambda (w) (walk w (cons "@watch" path)))
                                (jolt-atom-watches x))
                      (walk (jolt-atom-validator x) (cons "@validator" path))
                      #t))))
             (walk-pair
              (lambda (x path)
                (if (image-rebuild-mode? mode)
                    (let* ((a (walk (car x) (cons "car" path)))
                           (d (walk (cdr x) (cons "cdr" path))))
                      (or (hashtable-ref memo x #f)
                          (if (and (eq? a (car x)) (eq? d (cdr x)))
                              (begin (hashtable-set! memo x x) x)
                              (let ((nx (cons a d)))
                                (hashtable-set! memo x nx)
                                nx))))
                    (begin
                      (hashtable-set! memo x #t)
                      (walk (car x) (cons "car" path))
                      (walk (cdr x) (cons "cdr" path))
                      #t))))
             (walk-vector
              (lambda (x path)
                (let ((n (vector-length x)))
                  (if (image-rebuild-mode? mode)
                      (let ((out (make-vector n)) (dirty #f))
                        (let loop ((i 0))
                          (if (fx<? i n)
                              (let* ((v (vector-ref x i))
                                     (w (walk v (cons (number->string i) path))))
                                (vector-set! out i w)
                                (set! dirty (or dirty (not (eq? v w))))
                                (loop (fx+ i 1)))
                              (or (hashtable-ref memo x #f)
                                  (if dirty
                                      (begin
                                        (hashtable-set! memo x out)
                                        (image-meta-copy! x out)
                                        out)
                                      (begin (hashtable-set! memo x x) x))))))
                      (begin
                        (hashtable-set! memo x #t)
                        (let loop ((i 0))
                          (when (fx<? i n)
                            (walk (vector-ref x i) (cons (number->string i) path))
                            (loop (fx+ i 1))))
                        #t)))))
             (walk-hashtable
              (lambda (x path)
                (let-values (((ks vs) (hashtable-entries x)))
                  (if (image-rebuild-mode? mode)
                      (let ((nx (make-hashtable (hashtable-hash-function x)
                                                (hashtable-equivalence-function x))))
                        (hashtable-set! memo x nx)
                        (image-meta-copy! x nx)
                        (let loop ((i 0))
                          (when (fx<? i (vector-length ks))
                            (hashtable-set! nx
                              (walk (vector-ref ks i) (cons "<key>" path))
                              (walk (vector-ref vs i)
                                    (cons (image-describe-obj (vector-ref ks i)) path)))
                            (loop (fx+ i 1))))
                        nx)
                      (begin
                        (hashtable-set! memo x #t)
                        (let loop ((i 0))
                          (when (fx<? i (vector-length ks))
                            (walk (vector-ref ks i) (cons "<key>" path))
                            (walk (vector-ref vs i)
                                  (cons (image-describe-obj (vector-ref ks i)) path))
                            (loop (fx+ i 1))))
                        #t)))))
             ;; generic record: walk declared fields by name. Covers user
             ;; defrecords, lazy seqs, refs, image records, everything not
             ;; special-cased above.
             (walk-record
              (lambda (x path)
                (let* ((rtd (record-rtd x))
                       (names (record-type-field-names rtd))
                       (n (vector-length names)))
                  (if (image-rebuild-mode? mode)
                      (let ((vals (make-vector n)) (dirty #f))
                        (let loop ((i 0))
                          (if (fx<? i n)
                              (let* ((v (call/cc (lambda (k)
                                        (with-exception-handler (lambda (e) (k #f))
                                          (lambda () ((record-accessor rtd i) x))))))
                                     (w (walk v (cons (symbol->string (vector-ref names i)) path))))
                                (vector-set! vals i w)
                                (set! dirty (or dirty (not (eq? v w))))
                                (loop (fx+ i 1)))
                              (or (hashtable-ref memo x #f)
                                  (if dirty
                                      (let ((nx (apply (record-constructor rtd)
                                                       (vector->list vals))))
                                        (hashtable-set! memo x nx)
                                        (image-meta-copy! x nx)
                                        nx)
                                      (begin (hashtable-set! memo x x) x))))))
                      (begin
                        (hashtable-set! memo x #t)
                        (let loop ((i 0))
                          (when (fx<? i n)
                            (let ((v (call/cc (lambda (k)
                                      (with-exception-handler (lambda (e) (k #f))
                                        (lambda () ((record-accessor rtd i) x)))))))
                              (walk v (cons (symbol->string (vector-ref names i)) path)))
                            (loop (fx+ i 1))))
                        #t)))))
             ;; R3 read side: a stored fn source record rebuilds into a live
             ;; closure. Bottom-up: the record's free values transform first (a
             ;; captured value may itself be or contain a fnsrc record), then the
             ;; wrapper (fn* [free-names…] form) is compiled+eval'd in the
             ;; record's ns and APPLIED to the transformed values — the wrapper
             ;; params SHADOW the outer-scope names the body references. The
             ;; result is memoized keyed by the RECORD, so a record shared by two
             ;; slots evals once and both slots get the SAME closure; a cycle
             ;; through a mutable cell works because the cell is memoized before
             ;; its contents walk (the R2 order), so the closure's free value IS
             ;; the restored cell.
             (walk-fnsrc-restore
              (lambda (x path)
                (let* ((frees (image-fnsrc-free-names x))
                       (fvs (image-fnsrc-free-values x))
                       (n (vector-length fvs)))
                  (unless (fx=? n (pvec-count frees))
                    (jolt-throw (jolt-ex-info
                                  (string-append "image: malformed fn source record "
                                                 (image-fnsrc-name x) ": " (number->string n)
                                                 " free values for " (number->string (pvec-count frees))
                                                 " free names")
                                  jolt-nil)))
                  (let ((tfvs (map (lambda (v)
                                     (walk v (cons (string-append "free:" (image-fnsrc-name x)) path)))
                                   (vector->list fvs))))
                    (let ((cl (image-eval-fnsrc x tfvs)))
                      (hashtable-set! memo x cl)
                      (image-meta-copy! x cl)
                      cl)))))
             ;; R4 read side: a stored sorted coll rebuilds through the public
             ;; constructors. cmp-fn is walked first (jolt-nil -> natural ctor,
             ;; live fn -> fn-ref identity, stored fnsrc -> compiled closure);
             ;; the entries were written in sorted order, so folding them in via
             ;; jolt-assoc / jolt-conj (which dispatch sorted) is ordered input.
             (walk-sorted-restore
              (lambda (x path)
                (let* ((map? (eq? (image-sorted-kind x) 'map))
                       (cmp-fn (walk (image-sorted-cmp-fn x) (cons "cmp-fn" path)))
                       (entries (image-sorted-entries x))
                       (n (vector-length entries)))
                  (let ((coll (if (jolt-nil? cmp-fn)
                                  (jolt-invoke (var-deref "clojure.core"
                                                           (if map? "sorted-map" "sorted-set")))
                                  (jolt-invoke (var-deref "clojure.core"
                                                           (if map? "sorted-map-by" "sorted-set-by"))
                                               cmp-fn))))
                    (let loop ((i 0))
                      (when (fx<? i n)
                        (let ((e (walk (vector-ref entries i) (cons "entry" path))))
                          (if map?
                              (set! coll (jolt-assoc coll (car e) (cdr e)))
                              (set! coll (jolt-conj coll e)))
                          (loop (fx+ i 1)))))
                    (hashtable-set! memo x coll)
                    (image-meta-copy! x coll)
                    coll))))
             (walk-handled-restore
              (lambda (x path)
                (let ((tp (walk (image-handled-payload x) (cons "payload" path))))
                  (let ((r (image-restore-handler tp)))
                    (hashtable-set! memo x r)
                    r)))))
      (walk root '()))))

;; The write path's substitution entry: a copy of the graph where every anon
;; closure became an image-fnsrc record and every handler-claimed resource an
;; image-handled payload; throws (with the object's route) on the first thing
;; the write path cannot encode.
(define (image-substitute v)
  (image-graph-process v 'rebuild #f))

;; --- scan ----------------------------------------------------------------------
;; Dry run: every object that cannot be encoded, with the route to it. Returns a
;; jolt vector of maps so callers can render or assert on it.
(define (jolt-image-scan v)
  (let ((bad '()))
    (image-graph-process v 'report
      (lambda (x path)
        (set! bad (cons (cons (image-path->string path)
                              (image-describe-obj x))
                        bad))))
    (apply jolt-vector
           (map (lambda (p)
                  (jolt-hash-map (jolt-keyword "path") (car p)
                                 (jolt-keyword "object") (cdr p)))
                (reverse bad)))))

;; --- header --------------------------------------------------------------------
(define (image-header)
  (vector 'jolt-image
          jolt-image-format-version
          (jolt-image-runtime-version)
          (symbol->string (machine-type))))

(define (image-check-header! h path)
  (unless (and (vector? h) (fx=? (vector-length h) 4) (eq? (vector-ref h 0) 'jolt-image))
    (jolt-throw (jolt-ex-info (string-append "image: " path " is not a jolt image") jolt-nil)))
  (unless (equal? (vector-ref h 1) jolt-image-format-version)
    (jolt-throw (jolt-ex-info
                  (string-append "image: " path " has format version "
                                 (jolt-str-one (vector-ref h 1)) ", this build reads version "
                                 (number->string jolt-image-format-version))
                  jolt-nil)))
  ;; The fasl version moves with Chez, and a mismatch otherwise surfaces as an
  ;; opaque fasl-read error, so name it here instead.
  (unless (equal? (vector-ref h 2) (jolt-image-runtime-version))
    (jolt-throw (jolt-ex-info
                  (string-append "image: " path " was written by runtime "
                                 (jolt-str-one (vector-ref h 2)) ", this is "
                                 (jolt-image-runtime-version))
                  jolt-nil)))
  #t)

;; Runtime identity an image is pinned to. The fasl format moves with the Chez
;; release, so the Chez version is the honest key; the architecture deliberately
;; is NOT part of it.
(define (jolt-image-runtime-version)
  (string-append "chez-" (number->string (scheme-version-number*))))

(define (scheme-version-number*)
  ;; (scheme-version) is like "Chez Scheme Version 10.4.1"; reduce to an integer
  ;; so the check is a cheap equal? and prints readably.
  (let* ((s (scheme-version))
         (n (string-length s)))
    (let loop ((i 0) (acc 0) (seen #f))
      (if (fx>=? i n)
          acc
          (let ((c (string-ref s i)))
            (cond ((char-numeric? c) (loop (fx+ i 1) (+ (* acc 10) (- (char->integer c) 48)) #t))
                  ((and seen (char=? c #\.)) (loop (fx+ i 1) acc #t))
                  (seen acc)
                  (else (loop (fx+ i 1) acc seen))))))))

;; --- write / read --------------------------------------------------------------
;; Metadata lives in a weak side table keyed by object identity (natives-meta.ss),
;; so it cannot ride on the object itself. It rides in the SAME fasl stream
;; instead: fasl preserves sharing within one stream, so the objects in this
;; alist come back eq? to the ones in the graph and the meta can be re-attached.
(define (image-collect-meta v)
  (let ((acc '()))
    (image-walk v (lambda (x path)
                    (unless (var-cell? x)
                      (let ((m (call/cc (lambda (k)
                                 (with-exception-handler (lambda (e) (k jolt-nil))
                                   (lambda () (jolt-meta x)))))))
                        (unless (jolt-nil? m) (set! acc (cons (cons x m) acc)))))))
    acc))

(define (image-reattach-meta! pairs)
  (for-each (lambda (p) (hashtable-set! meta-table (car p) (cdr p))) pairs))

(define (jolt-image-write! path v)
  ;; R2: substitute first — anon closures become image-fnsrc records and handler
  ;; resources become image-handled payloads, so what fasl sees is exactly what
  ;; the transformer approved (any refusal has already thrown, with its path).
  (let* ((v* (image-substitute v))
         ;; externals are collected in encounter order; the eq table is only for
         ;; membership, since a keyword-dense graph makes a list scan quadratic.
         (externals '()) (ext-seen (make-eq-hashtable)) (ext-tail #f))
    ;; Body first: the externals list is discovered during fasl-write, so it
    ;; cannot be written ahead of the body.
    (let ((body (call-with-bytevector-output-port
                  (lambda (p)
                    (fasl-write (vector v* (image-collect-meta v*)) p
                      (lambda (x)
                        (and (image-external? x)
                             (begin
                               (unless (hashtable-ref ext-seen x #f)
                                 (hashtable-set! ext-seen x #t)
                                 (let ((cell (list x)))
                                   (if ext-tail
                                       (begin (set-cdr! ext-tail cell) (set! ext-tail cell))
                                       (begin (set! externals cell) (set! ext-tail cell)))))
                               #t))))))))
      (let ((descs (map (lambda (x)
                          (or (image-encode-external x)
                              ;; Re-walk for the path only on the failure branch,
                              ;; so the happy path pays nothing for it.
                              (let ((where "<unknown>"))
                                (image-walk v* (lambda (o p)
                                                 (when (eq? o x) (set! where (image-path->string p)))))
                                (jolt-throw (jolt-ex-info
                                              (string-append "image: cannot write "
                                                             (image-describe-obj x)
                                                             " at " where)
                                              jolt-nil)))))
                        externals)))
        ;; Descriptors are written WITHOUT an externals-pred, so a handler that
        ;; returns something non-data would fail here with a raw Chez error.
        ;; Check before opening the file, so a rejected dump never leaves a
        ;; half-written image behind.
        (let ((desc-bytes
                (call/cc (lambda (k)
                  (with-exception-handler
                    (lambda (e)
                      (k (jolt-throw (jolt-ex-info
                                       "image: a resource handler returned a value that is not plain data"
                                       jolt-nil))))
                    (lambda () (call-with-bytevector-output-port
                                 (lambda (p) (fasl-write descs p)))))))))
          (let ((port (open-file-output-port path (file-options no-fail))))
            (fasl-write (image-header) port)
            (put-bytevector port desc-bytes)
            (put-bytevector port body)
            (close-port port)))))
    jolt-nil))

(define (jolt-image-read path)
  (unless (file-exists? path)
    (jolt-throw (jolt-ex-info (string-append "image: no such file: " path) jolt-nil)))
  (let ((port (open-file-input-port path)))
    (let* ((h (fasl-read port))
           (_ (image-check-header! h path))
           (descs (fasl-read port))
           (exts (list->vector (map image-decode-external descs)))
           (b (fasl-read port 'load exts)))
      (close-port port)
      (unless (and (vector? b) (fx=? (vector-length b) 2))
        (jolt-throw (jolt-ex-info (string-append "image: malformed body in " path) jolt-nil)))
      (image-reattach-meta! (vector-ref b 1))
      ;; R3: rebuild what the write side substituted — fn source records become
      ;; live closures, handler payloads go back through their restore fns.
      ;; Runs after meta re-attachment so container rebuilds carry meta forward.
      (image-graph-process (vector-ref b 0) 'restore #f))))

;; --- whole-world image ----------------------------------------------------------
;; The Smalltalk/Common Lisp shape: don't ask which variable to save, save the
;; world. Walk the var table and write every var's root, so restoring brings the
;; program's whole state back rather than one value the caller remembered to name.
;;
;; What makes this affordable on Chez is that CODE does not have to travel. A var
;; whose root is a procedure is skipped outright: the restoring process is the
;; same build, so it already has that function: `defn` bodies, protocol impls and
;; multimethod tables are all present before the image is read. Only DATA moves.
;; That is also why an image is pinned to its build — see the header check.
;;
;; Namespaces owned by the language are skipped by default. clojure.core holds
;; mutable vars (*ns*, *warn-on-reflection*, printer state) that belong to the
;; process being restored INTO, not to the image; carrying them over would make a
;; restore quietly reconfigure the reader and printer.
;; `user` is deliberately NOT skipped: at a REPL it is where the work lives, and
;; an image that quietly dropped it would lose exactly what the user typed.
(define image-system-ns-prefixes '("clojure." "jolt."))

(define (image-system-ns? ns)
  (or (string=? ns "clojure.core")
      (let loop ((ps image-system-ns-prefixes))
        (and (pair? ps)
             (or (and (>= (string-length ns) (string-length (car ps)))
                      (string=? (substring ns 0 (string-length (car ps))) (car ps)))
                 (loop (cdr ps)))))))

;; Hooks, the *save-hooks* / *init-hooks* pair. An application quiesces in
;; before-dump (stop pools, park threads) and rebuilds whatever it could not
;; carry in after-restore (reopen resources, re-derive computed cells).
(define image-before-dump-hooks '())
(define image-after-restore-hooks '())
(define (jolt-image-add-before-dump-hook! f)
  (set! image-before-dump-hooks (append image-before-dump-hooks (list f))) jolt-nil)
(define (jolt-image-add-after-restore-hook! f)
  (set! image-after-restore-hooks (append image-after-restore-hooks (list f))) jolt-nil)
(define (image-run-hooks! hs) (for-each (lambda (f) (jolt-invoke f)) hs) jolt-nil)

;; ns-list is a jolt seq of namespace-name strings, or nil for "every namespace
;; that isn't the language's own".
(define (image-world-vars ns-list)
  (let ((want (if (jolt-nil? ns-list)
                  #f
                  (let loop ((s (jolt-seq ns-list)) (acc '()))
                    (if (jolt-nil? s) acc
                        (loop (jolt-next s) (cons (jolt-first s) acc))))))
        (out '()))
    (let-values (((ks vs) (hashtable-entries var-table)))
      (let loop ((i 0))
        (when (fx<? i (vector-length ks))
          (let* ((cell (vector-ref vs i))
                 (ns (var-cell-ns cell))
                 (nm (var-cell-name cell))
                 (root (var-cell-root cell)))
            (when (and (if want (member ns want) (not (image-system-ns? ns)))
                       ;; code is already in the restoring build; only data moves
                       (not (procedure? root))
                       (not (jolt-var-unbound? root)))
              (let ((h (image-handler-for root)))
                (set! out (cons (cons (string-append ns "/" nm)
                                      (if h
                                          (make-image-handled (jolt-invoke (cadr h) root))
                                          root))
                                out)))))
          (loop (fx+ i 1)))))
    out))

(define (jolt-image-dump-world! path ns-list)
  (image-run-hooks! image-before-dump-hooks)
  (jolt-image-write! path (vector 'jolt-world (image-world-vars ns-list))))

(define (jolt-image-scan-world ns-list)
  (jolt-image-scan (vector 'jolt-world (image-world-vars ns-list))))

(define (jolt-image-restore-world! path)
  (let ((w (jolt-image-read path)))
    (unless (and (vector? w) (fx=? (vector-length w) 2) (eq? (vector-ref w 0) 'jolt-world))
      (jolt-throw (jolt-ex-info
                    (string-append "image: " path
                                   " is a value image, not a world image — read it with read-image")
                    jolt-nil)))
    (let ((n 0))
      (for-each
        (lambda (p)
          (let* ((k (car p))
                 (slash (let scan ((i 0))
                          (cond ((fx>=? i (string-length k)) #f)
                                ((char=? (string-ref k i) #\/) i)
                                (else (scan (fx+ i 1))))))
                 (ns (substring k 0 slash))
                 (nm (substring k (fx+ slash 1) (string-length k))))
            (let ((cell (jolt-var ns nm))
                  (v (cdr p)))
              ;; handled payloads and fn source records were already rebuilt by
              ;; the read transform; the root binds as-is
              (var-cell-root-set! cell v)
              (var-cell-defined?-set! cell #t)
              (set! n (fx+ n 1)))))
        (vector-ref w 1))
      (image-run-hooks! image-after-restore-hooks)
      n)))

(def-var! "jolt.host" "image-dump-world!" jolt-image-dump-world!)
(def-var! "jolt.host" "image-restore-world!" jolt-image-restore-world!)
(def-var! "jolt.host" "image-scan-world" jolt-image-scan-world)
(def-var! "jolt.host" "image-add-before-dump-hook!" jolt-image-add-before-dump-hook!)
(def-var! "jolt.host" "image-add-after-restore-hook!" jolt-image-add-after-restore-hook!)
(def-var! "jolt.host" "image-write!" jolt-image-write!)
(def-var! "jolt.host" "image-read" jolt-image-read)
(def-var! "jolt.host" "image-scan" jolt-image-scan)
(def-var! "jolt.host" "image-register-handler!" jolt-image-register-handler!)
(def-var! "jolt.host" "image-runtime-version" jolt-image-runtime-version)
