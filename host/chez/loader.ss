;; loader.ss — file-based namespace loading + a shell primitive.
;;
;; The corpus/CLI spine compiles one program at a time; namespaces declared in
;; that program see each other because a top-level (do …) unrolls. A real project
;; spans many FILES, so `require` must locate a namespace's source on the search
;; roots and load it — transitively, once each.
;;
;; Loaded by cli.ss AFTER compile-eval.ss (it calls jolt-compile-eval-form). The
;; gates load compile-eval.ss but NOT this file, so the corpus/unit/sci runners
;; keep their alias-only `require` and are unaffected.

;; --- search roots -----------------------------------------------------------
;; An ordered list of directory strings. `require` searches them left to right.
;; The CLI seeds this with the project's resolved deps roots (jolt.deps) plus the
;; jolt-core roots so jolt.main/jolt.deps themselves load.
(define source-roots '("."))
(define (set-source-roots! roots)
  (set! source-roots roots)
  (load-data-readers!))   ; scan every entry point (cli startup + jolt.host wrapper)
;; Roots setter that does NOT re-scan data_readers — for an emitted binary's
;; prologue/launcher, where *data-readers* and the reader namespaces are already
;; baked (bld-emit-data-readers + the app ns walk). Re-scanning would eagerly
;; reload each reader namespace via load-jolt-file/jolt-compile-eval-form, which a
;; tree-shaken no-eval binary has dropped, crashing startup. jolt/build entry
;; points keep the scanning set-source-roots!.
(define (set-source-roots!* roots) (set! source-roots roots))
(define (get-source-roots) source-roots)

;; jolt's answer to (System/getProperty "java.class.path") is these roots — the
;; loader owns them, the runtime's system-property table renders them. Tooling
;; ported from the JVM (orchard's / compliment's classpath scans, cider-nrepl's
;; classpath op) discovers project sources through that property.
(set-class-path-provider! get-source-roots)

;; Install roots — the directories that ship with Jolt (compiler + stdlib + vendored
;; deps). Shared by cli.ss, build-jolt.ss, and the bld-require-closure filter so the
;; literal list stays in one place. ORDER IS PRECEDENCE: the first root holding a
;; namespace wins, on disk (resolve-on-roots) and in a built binary (build-jolt.ss
;; bakes first-wins to match). Grenadine ships host adapters alongside its portable
;; core, one of them named jolt.deps, so jolt-core has to precede it.
(define ldr-install-roots
  '("jolt-core" "stdlib" "vendor/fs/src" "vendor/process/src" "vendor/grenadine/src"
    ;; the four namespaces grenadine generates instead of committing — see
    ;; vendor/grenadine-generated/README.md
    "vendor/grenadine-generated"))

;; True when `f` is a file owned by the Jolt runtime (compiler + stdlib) — either
;; an embedded-resource key (string or bytevector value) or a path under one of
;; ldr-install-roots.
(define (ldr-install-file? f)
  (let ((v (hashtable-ref embedded-resources f #f)))
    (or (string? v) (bytevector? v)
        (let loop ((roots ldr-install-roots))
          (and (pair? roots)
               (or (let ((root (car roots)))
                     (and (>= (string-length f) (+ (string-length root) 1))
                          (string=? (substring f 0 (string-length root)) root)
                          (char=? (string-ref f (string-length root)) #\/)))
                   (loop (cdr roots))))))))

;; A Chez source string for the install roots list — "(list \"jolt-core\" \"stdlib\" \"vendor/fs/src\")".
;; Used by build templates so the literal stays in one place.
(define (ldr-install-roots-str)
  (string-append "(list"
    (fold-left (lambda (s r) (string-append s " \"" r "\"")) "" ldr-install-roots)
    ")"))

;; --- data readers (#tag literals) -------------------------------------------
;; A project's data_readers.{jolt,clj,cljc} at a source root maps a tag symbol to a
;; qualified reader fn (e.g. {time/date time-literals.data-readers/date}). We
;; merge those into clojure.core/*data-readers* and require each reader's
;; namespace, then while loading source rewrite a registered #tag form into a
;; call (reader-fn 'inner-form) so the value is built at runtime. #inst/#uuid and
;; #"regex" stay built-in (the analyzer lowers them); only tags present in
;; *data-readers* are rewritten. data-readers-active gates the per-form walk so
;; projects without data readers (the common case) pay nothing.
(define data-readers-active #f)
(define (data-readers-table) (var-deref "clojure.core" "*data-readers*"))
;; tag keyword (:#time/date) -> its registered reader symbol, or #f.
(define (data-reader-symbol tag)
  (and (keyword? tag)
       (let ((nm (keyword-t-name tag)))
         (and (> (string-length nm) 0) (char=? (string-ref nm 0) #\#)
              (let* ((bare (substring nm 1 (string-length nm)))
                     (slash (let loop ((i 0))
                              (cond ((>= i (string-length bare)) #f)
                                    ((char=? (string-ref bare i) #\/) i)
                                    (else (loop (+ i 1))))))
                     (sym (if slash
                              (jolt-symbol (substring bare 0 slash) (substring bare (+ slash 1) (string-length bare)))
                              (jolt-symbol #f bare)))
                     (t (data-readers-table))
                     (v (and (pmap? t) (jolt-get t sym))))
                 (and v (not (jolt-nil? v)) v))))))
;; Invoke a resolved data-reader fn at load time, letting a throw surface as an
;; ex-info naming the tag (with the reader's own error as the cause) instead of
;; silently degrading to the runtime-call fallback.
(define (ldr-invoke-reader tag-kw rfn inner)
  (guard (e (else
              (let* ((orig (jolt-unwrap-throw e))
                     (orig-msg (guard (_ (#t #f))
                                 (let ((m ((var-deref "jolt.host" "condition-message") e)))
                                   (and (string? m) m))))
                     (msg (string-append "data reader " (keyword-t-name tag-kw) " threw"
                                         (if orig-msg (string-append ": " orig-msg) ""))))
                (jolt-throw
                  (jolt-ex-info msg (jolt-hash-map (keyword #f "tag") tag-kw) orig)))))
    (jolt-invoke rfn inner)))
;; change-tracking walk: rewrite registered #tag forms, keep everything else
;; (and its identity/metadata) intact. Mirrors reader.ss rdr-form->data but keeps
;; set FORMS for the compiler spine instead of building real sets.
(define (ldr-conv-each xs)
  (let loop ((xs xs) (acc '()) (changed #f))
    (if (null? xs) (values (reverse acc) changed)
        (let ((c (ldr-apply-readers (car xs))))
          (loop (cdr xs) (cons c acc) (or changed (not (eq? c (car xs)))))))))
(define (ldr-apply-readers x)
  (cond
    ((and (pmap? x) (eq? (jolt-get x rdr-kw-jolt-type) rdr-kw-jolt-tagged))
     (let ((rdr (data-reader-symbol (jolt-get x rdr-kw-tag)))
           (inner (ldr-apply-readers (jolt-get x rdr-kw-form))))
       (cond
          (rdr
           ;; Clojure applies a data reader at read time and substitutes its result
           ;; as code. A reader that returns a FORM (a list — e.g. borkdude.html's
           ;; #html expands to (->Html (str …))) must be compiled, so splice it in.
           ;; A reader that returns a VALUE (time-literals #time/date -> a Date) is
           ;; left as a runtime call (reader-fn 'inner): the value rebuilds at
           ;; startup, which also keeps a non-serializable constant out of an AOT
           ;; build. The reader runs at load time only when its var RESOLVES — a
           ;; reader whose ns isn't loaded yet falls back to the runtime call. A
           ;; resolved reader that throws surfaces (the prior catch-all guard
           ;; silently downgraded every reader bug to a runtime call).
           (let ((rfn (and (symbol-t? rdr) (not (jolt-nil? (symbol-t-ns rdr)))
                           (let ((v (var-deref (symbol-t-ns rdr) (symbol-t-name rdr))))
                             (and (procedure? v) v)))))
             (if rfn
                 (let ((result (ldr-invoke-reader (jolt-get x rdr-kw-tag) rfn inner)))
                   (if (cseq? result)
                       result
                       (jolt-list rdr (jolt-list (jolt-symbol #f "quote") inner))))
                 ;; unresolved reader (ns not loaded yet): runtime-call fallback
                 (jolt-list rdr (jolt-list (jolt-symbol #f "quote") inner)))))
         ((eq? inner (jolt-get x rdr-kw-form)) x)
         (else (rdr-make-tagged (jolt-get x rdr-kw-tag) inner)))))
    ((rdr-set-form? x)
     (let-values (((items changed) (ldr-conv-each (seq->list (jolt-get x rdr-kw-value)))))
       (if changed (rdr-carry-meta x (rdr-make-set items)) x)))
    ((pvec? x)
     (let-values (((items changed) (ldr-conv-each (vector->list (pvec-v x)))))
       (if changed (rdr-carry-meta x (apply jolt-vector items)) x)))
    ((pmap? x)
     (let ((order (rdr-map-order-ref x)))
       (if order
           (let-values (((kvs changed) (ldr-conv-each order)))
             (if changed (rdr-carry-meta x (rdr-make-map kvs)) x))
           (let-values (((kvs changed) (ldr-conv-each (pmap-fold x (lambda (k v a) (cons k (cons v a))) '()))))
             (if changed (rdr-carry-meta x (apply jolt-hash-map kvs)) x)))))
    ((cseq? x)
     (let-values (((items changed) (ldr-conv-each (seq->list x))))
       (if changed (rdr-carry-meta x (apply jolt-list items)) x)))
    (else x)))

;; read+merge one data_readers file: a literal {tag-sym reader-sym …} map.
(define (merge-data-readers-file path)
  (let* ((src (read-file-string path)))
    (let-values (((m j) (rdr-read-form src 0 (string-length src))))
    (when (and (not (rdr-eof? m)) (pmap? m))
      (let ((cur (data-readers-table)))
        (def-dynvar! "clojure.core" "*data-readers*"
          (apply jolt-assoc (if (pmap? cur) cur empty-pmap)
                 (pmap-fold m (lambda (k v a) (cons k (cons v a))) '()))))
      (set! data-readers-active #t)
      ;; eagerly load each reader fn's namespace so the rewritten call resolves.
      (pmap-fold m (lambda (k v a)
                     (when (and (symbol-t? v) (symbol-t-ns v) (not (jolt-nil? (symbol-t-ns v))))
                       ;; tolerant — a data_readers entry must not kill the project
                       ;; load — but say WHICH reader ns failed and why, or the
                       ;; miss surfaces later as an unrelated unresolved-var error
                       ;; at first #tag read.
                       (guard (e (#t (display
                                      (string-append "jolt: warning: data-reader namespace "
                                                     (symbol-t-ns v) " failed to load: "
                                                     (guard (_ (#t "(unprintable error)"))
                                                       ((var-deref "jolt.host" "condition-message") e))
                                                     "\n")
                                      (current-error-port))))
                         (load-namespace (symbol-t-ns v))))
                     a)
                 #f)))))
(define (load-data-readers!)
  (for-each
    (lambda (root)
      ;; data_readers.{jolt,clj,cljc}, in the same precedence as a namespace's
      ;; source (ldr-source-exts below) — first one found on this root wins.
      (let loop ((es ldr-source-exts))
        (when (pair? es)
          (let ((f (string-append root "/data_readers" (car es))))
            (if (file-exists? f)
                (merge-data-readers-file f)
                (loop (cdr es)))))))
    source-roots))

;; --- namespace -> file path -------------------------------------------------
;; "app.commonmark-test" -> "app/commonmark_test": split on '.', munge '-'->'_'
;; per segment, join with '/'. Matches Clojure's ns->file munging.
(define (ns-seg-munge seg) (jch-munge-segments seg)) ; shared with the class graph
(define (ns-name->rel name)
  (let loop ((cs (string->list name)) (seg '()) (segs '()))
    (cond
      ((null? cs)
       (let ((all (reverse (cons (list->string (reverse seg)) segs))))
         (let join ((xs all) (acc ""))
           (cond ((null? xs) acc)
                 ((string=? acc "") (join (cdr xs) (ns-seg-munge (car xs))))
                 (else (join (cdr xs) (string-append acc "/" (ns-seg-munge (car xs)))))))))
      ((char=? (car cs) #\.)
       (loop (cdr cs) '() (cons (list->string (reverse seg)) segs)))
      (else (loop (cdr cs) (cons (car cs) seg) segs)))))

;; The extensions a namespace's source can carry, in resolution order. .jolt is
;; the same language as .clj — the reader, analyzer, and emitter never look at the
;; extension — and only marks intent: the file uses jolt-specific interop and is
;; not portable Clojure. It resolves FIRST so a library can ship a portable
;; foo.cljc/foo.clj alongside a foo.jolt that wins here, the way .clj wins over
;; .cljc on the JVM.
(define ldr-source-exts '(".jolt" ".clj" ".cljc"))

(define (ldr-source-path? p)
  (let loop ((es ldr-source-exts))
    (and (pair? es)
         (let* ((suf (car es)) (n (string-length p)) (m (string-length suf)))
           (or (and (>= n m) (string=? (substring p (- n m) n) suf))
               (loop (cdr es)))))))

;; First existing <root>/rel.<ext> on the search roots, else #f.
;; A self-contained jolt binary embeds jolt-core + stdlib source keyed by their
;; root-relative path ("clojure/string.clj"); those are checked first, so a
;; `require` resolves with no source on disk. The dev bin/jolt has an empty
;; source store, so the hashtable probes miss and it falls straight to disk.
(define (resolve-on-roots rel)
  (define (embedded-key? k)
    (let ((v (hashtable-ref embedded-resources k #f)))
      (or (string? v) (bytevector? v))))
  (or (let loop ((es ldr-source-exts))
        (and (pair? es)
             (let ((k (string-append rel (car es))))
               (if (embedded-key? k) k (loop (cdr es))))))
      (let loop ((roots source-roots))
        (and (pair? roots)
             (or (let ext ((es ldr-source-exts))
                   (and (pair? es)
                        (let ((f (string-append (car roots) "/" rel (car es))))
                          (if (file-exists? f) f (ext (cdr es))))))
                 (loop (cdr roots)))))))

;; Read a namespace source. An embedded key (resolve-on-roots above, or the
;; build driver's app-order entries) reads its baked string; everything else is
;; a real path read off disk. Bytevector entries (the bundled boots/stub, and
;; source embeds stored as bytevectors to save heap) decode via utf8->string.
(define (ldr-read-source path)
  (let ((emb (hashtable-ref embedded-resources path #f)))
    (cond ((string? emb) emb)
          ((bytevector? emb) (utf8->string emb))
          (else (read-file-string path)))))

(define (find-ns-file name) (resolve-on-roots (ns-name->rel name)))

;; --- the loaded set ---------------------------------------------------------
;; Seeded with every namespace that already has vars at load time — the baked
;; prelude/image (clojure.core, clojure.string, jolt.analyzer, …). A `require` of
;; one of those then no-ops instead of hunting for a (nonexistent) source file.
;; ldr-tbl-mu covers every MUTATION of loaded-ns and of the AOT memos below, and
;; every WHOLE-TABLE scan of them. Single-key reads stay unlocked (strong general
;; hashtables — see rt.ss's var-table note for why that is sound).
(define ldr-tbl-mu (make-mutex))
(define loaded-ns (make-hashtable string-hash string=?))
(vector-for-each (lambda (c) (hashtable-set! loaded-ns (var-cell-ns c) #t))
                 (var-table-cells))

;; clojure.core.async ships native channel primitives (async.ss) AND a Clojure
;; overlay (stdlib/clojure/core/async.clj) with the higher-level dataflow API
;; (alts!, pipe, mult, mix, pub/sub, map, merge, …). The primitives pre-seed the
;; namespace above, which would make a `require` no-op and skip the overlay. Drop
;; it from the loaded set so a require pulls the overlay from the source roots
;; (like clojure.test); the primitives stay defined either way.
(hashtable-delete! loaded-ns "clojure.core.async")

;; *loaded-libs* is the other half of the loaded set: a clojure.lang.Ref that
;; tools.namespace and core.typed conj/disj on, and that ns-dedup-loaded? below
;; reads alongside loaded-ns. A bare read-modify-write of the ref field lost marks
;; outright once two loads could overlap: both threads read the old set and the
;; second store dropped the first's symbol, so a
;; namespace that HAD loaded read as unloaded and ran its top level again on the
;; next require — the very bug the load protocol below exists to stop, reached
;; through the other table.
;;
;; A LOAD MUST NEVER ACQUIRE stm-lock. jolt-sync holds stm-lock across the whole
;; body of a transaction (refs.ss), so (dosync (require 'x)) is inside require while
;; holding it — and if that require parks in step 2, condition-wait releases
;; ldr-load-mu and NOTHING else, so it sits there holding stm-lock until the load it
;; is waiting for completes. A loading thread that then needed stm-lock could not
;; complete, and the two would wait on each other forever:
;;
;;   stm-lock -> ns_load   the parked dosync cannot release stm-lock until the load
;;                         it is waiting for finishes
;;   ns_load  -> stm-lock  the loader cannot finish without stm-lock
;;
;; That is not hypothetical. It reproduces on the rollback path, where a failed load
;; re-takes this lock to unmark before releasing its claim, and in the window between
;; claiming a namespace and marking it. So the mark goes through a leaf mutex of our
;; own that no transaction ever waits on, and the edge ns_load -> stm-lock does not
;; exist.
;;
;; NOT through the ambient transaction's log when there is one, which is what this
;; did first. It looks like the better answer — transactional, and it takes no lock
;; at all — and it is wrong twice, because the mark is not the transaction's to own.
;; A load either happened or it did not, and the file's defs are in the image either
;; way; an abort that rolls the mark back leaves loaded-ns marked and *loaded-libs*
;; not, which reads as unloaded and re-runs the whole namespace. And a buffered write
;; is invisible to ns-dedup-loaded? until commit, so
;; (dosync (require 'x) (require 'x)) ran x's top level twice.
;;
;; What the direct write leaves open is a mark landing while a user transaction that
;; also writes *loaded-libs* is committing, which costs that namespace one extra
;; reload. Narrow, one-directional, and the alternatives are a hang or the two bugs
;; above.
;;
;; Call with NO loader mutex held either. A (dosync (require ...)) reaches ldr-tbl-mu
;; while holding stm-lock, so the loader taking these in the other order would be the
;; same cycle by another route. Sequential, never nested, is what keeps them apart.
(define ldr-libs-mu (make-mutex))
(define (ldr-libs-update! f)
  (let* ((libs-cell (var-cell-lookup "clojure.core" "*loaded-libs*"))
         (libs-ref (and libs-cell (var-cell-root libs-cell))))
    (when (and libs-ref (jolt-ref? libs-ref))
      (jolt-with-mutex ldr-libs-mu
        (jolt-ref-val-set! libs-ref (f (jolt-ref-val libs-ref)))))))

;; Seed *loaded-libs* ref from the initial loaded-ns set (for tools.namespace
;; and core.typed which conj/disj on it).  Must happen after the async deletion.
(let ((ks (jolt-with-mutex ldr-tbl-mu (hashtable-keys loaded-ns))))
  (ldr-libs-update!
    (lambda (s)
      (let loop ((i 0) (s s))
        (if (fx=? i (vector-length ks))
            s
            (loop (fx+ i 1) (pset-conj s (jolt-symbol #f (vector-ref ks i)))))))))

;; ns-has-vars? (ns.ss) answers whether a namespace baked into the image after
;; the snapshot above — an AOT'd app namespace in a `jolt build` binary — exists
;; in memory with no source file; a later `require` of it must no-op rather than
;; hunt the (absent) source.

;; Called after a file-backed namespace finishes loading, with (name file). The
;; build driver sets this to record app namespaces in dependency order for AOT
;; emission; a no-op for normal runs.
(define ns-loaded-hook (lambda (name file) #f))
(define (set-ns-loaded-hook! f) (set! ns-loaded-hook f))

;; Read every form from a file and compile+eval it in turn. The first form is
;; normally (ns …), which expands to (in-ns …) and switches the current ns, so
;; later forms compile in that namespace — (chez-current-ns) is re-read each step.
;;
;; Reads by POSITION rather than via __parse-next: a top-level form that reads as
;; nothing — a :cljs-only #? with no matching branch, a #_ discard, a trailing
;; comment — yields rdr-eof but still advances. parse-next collapses that to "no
;; more forms", which would silently drop the entire rest of the file; here we
;; skip the no-op form and continue to true end-of-string.
;; A file load binds *file* to the path and *source-path* to the bare file
;; name around its forms (the reference binds both in Compiler.load), so loaded
;; code can read its own location. It also rebinds the compiler-flag vars
;; *warn-on-reflection*, *assert* and *unchecked-math* to their current roots, so
;; a file's top-level (set! *unchecked-math* …) is legal and its effect ends with
;; the file rather than leaking into the root. Cells resolve lazily — the vars'
;; defaults load after this file.
(define ldr-file-cell #f)
(define ldr-spath-cell #f)
(define ldr-warn-cell #f)
(define ldr-assert-cell #f)
(define ldr-unchecked-cell #f)
(define ldr-allow-cells (make-hashtable string-hash string=?))
(define (ldr-with-file-vars path thunk)
  (unless ldr-file-cell
    (set! ldr-file-cell (var-cell-lookup "clojure.core" "*file*"))
    (set! ldr-spath-cell (var-cell-lookup "clojure.core" "*source-path*"))
    (set! ldr-warn-cell (var-cell-lookup "clojure.core" "*warn-on-reflection*"))
    (set! ldr-assert-cell (var-cell-lookup "clojure.core" "*assert*"))
    (set! ldr-unchecked-cell (var-cell-lookup "clojure.core" "*unchecked-math*")))
  (if (not (and ldr-file-cell ldr-spath-cell ldr-warn-cell ldr-assert-cell
                ldr-unchecked-cell))
      (thunk)
      (let ((name (let loop ((i (- (string-length path) 1)))
                    (cond ((< i 0) path)
                          ((char=? (string-ref path i) #\/)
                           (substring path (+ i 1) (string-length path)))
                          (else (loop (- i 1)))))))
        (dyn-with-frame
          (list (cons ldr-file-cell path)
                (cons ldr-spath-cell name)
                (cons ldr-warn-cell (var-cell-root ldr-warn-cell))
                (cons ldr-assert-cell (var-cell-root ldr-assert-cell))
                (cons ldr-unchecked-cell (var-cell-root ldr-unchecked-cell)))
          thunk))))

(define (load-jolt-file path)
  (load-jolt-file* path (ldr-read-source path)))

;; load-jolt-file* — the read/compile/eval loop over a PRE-READ source string.
;; Split out so the AOT cache (below) reads source once for both keying and the
;; capture load, instead of re-reading inside the loop.
(define (load-jolt-file* path src)
  (let* ((end (string-length src))
         ;; Restore the current-source position on NORMAL return only. Loading a
         ;; required file advances the position per form; without restoring it, a
         ;; later error in the requiring file (e.g. a second, missing require in
         ;; the same ns form) would be blamed on the last form of the dependency
         ;; that just loaded. On a throw we intentionally do NOT restore, so the
         ;; error keeps the failing form's own position instead of unwinding to
         ;; the requiring form — the report then points at the file that failed.
         (saved-source (jolt-current-source)))
    ;; parameterize (not a bare set!) so a require nested in this file's ns form
    ;; restores path when control returns to the rest of this file.
    (parameterize ((rdr-source-file path)    ; list forms read here carry :file = path
                   ;; Tee into the AOT capture only while loading the file that
                   ;; capture was opened for. A nested load must not append its
                   ;; forms to the requiring namespace's artifact: that artifact
                   ;; already re-runs the require which loads the nested namespace,
                   ;; so the copy is a SECOND definition of it, replayed after the
                   ;; require — and a top-level registration in it then lands on
                   ;; top of whatever the requiring namespace layered over it.
                   ;; jolt.time (a 14-line ns form) baked in eight install-owned
                   ;; jolt/time/*.clj namespaces this way; on a cache hit
                   ;; jolt.time.local's ISO-only java.time.LocalDate/parse replayed
                   ;; after jolt.time.fmt's pattern-aware override and undid it, so
                   ;; a warm cache silently ignored a DateTimeFormatter. Only
                   ;; install-owned namespaces leaked: a cacheable one opens its own
                   ;; capture (aot-capture-load) and so already redirected.
                   (jolt-aot-capture (and (equal? path (jolt-aot-capture-file))
                                          (jolt-aot-capture))))
      (ldr-with-file-vars path
        (lambda ()
          ;; rdr-read-top, not rdr-read-form: a stray close delimiter is a READ
          ;; ERROR at a file's top level, and only the top-level entry says so.
          ;; rdr-read-form leaves the position where it found the `)`, and the
          ;; (> j i) guard below reads no progress as end of input — so one extra
          ;; paren silently DROPPED the rest of the file and the run exited 0.
          ;; A test file that lost its whole body that way still looked like a
          ;; pass. The JVM raises "Unmatched delimiter: )" here (jolt-3amm).
          (let loop ((i 0))
            (when (< i end)
              (let-values (((form j) (rdr-read-top src i end)))
                (when (> j i)
                  (unless (rdr-eof? form)
                    (when (getenv "JOLT_TRACE_LOAD")
                      (display "  [load-form] " (current-error-port))
                      (display (jolt-pr-str form) (current-error-port)) (newline (current-error-port)))
                    (jolt-compile-eval-form (if data-readers-active (ldr-apply-readers form) form)
                                            (chez-current-ns)))
                  (loop j))))))))
    (jolt-current-source saved-source)))

;; --- AOT / compile cache for required namespaces ----------------------------
;; A disk-backed namespace is recompiled from source on EVERY run (load-jolt-file
;; → analyze+emit+eval per form). This cache fasls the emitted Scheme on the first
;; load of a namespace and `load`s the .so on subsequent loads, recovering most of
;; that per-run compile cost. The cache FILENAME embeds a content hash of the
;; source, so any edit (same path, different bytes) misses automatically — no
;; mtime tracking needed. Gated by JOLT_AOT_CACHE; OFF for install-owned source
;; (embedded in the binary) and bypassed on :reload / :reload-all (live editing).
(define (aot-cache-dir)
  (or (getenv "JOLT_CACHE_DIR")
      (string-append (or (getenv "HOME") ".") "/.jolt/aot-cache")))
;; Default ON — a built jolt benefits every run (ys-style startup pulling many
;; library namespaces). JOLT_AOT_CACHE=0/false/no/off opts out. The dev bin/jolt
;; script exports JOLT_AOT_CACHE=0, so source-mode dev (a volatile compiler whose
;; "dev" version tag would NOT invalidate the cache across edits, and whose
;; startup is already covered by the devboot cache) stays OFF by default.
(define (aot-cache-enabled?)
  (let ((e (getenv "JOLT_AOT_CACHE")))
    (if (and (string? e) (fx>? (string-length e) 0))
        (not (or (string=? e "0") (string-ci=? e "false")
                 (string-ci=? e "no") (string-ci=? e "off")))
        #t)))   ; unset/empty → default ON
;; A cached fasl is only valid for the runtime that emitted it, and the version
;; string alone does not pin one: `git describe` reports the same "…-dirty" for
;; every edit in a working tree, so successive builds out of one checkout all
;; share a key and each happily loads the previous runtime's output. Mix in a
;; fingerprint of the runtime itself. A binary bakes one over its whole emitted
;; image (build-jolt.ss); running from a checkout there is none, so hash the
;; runtime sources on disk instead. #f means we could not identify the runtime —
;; the cache stays off rather than key on something that doesn't distinguish it.
(define aot-runtime-source-dirs '("host/chez" "host/chez/java" "host/chez/seed"))
(define (aot-ss-file? f)
  (let ((n (string-length f)))
    (and (> n 3) (string=? (substring f (- n 3) n) ".ss"))))
;; 32-bit multiply-accumulate over each file's length and content hash, folded in
;; sorted path order so the result is reproducible across runs and machines.
(define (aot-hash-mix a b) (bitwise-and (+ (* a 1000003) b) #xFFFFFFFF))
;; FNV-1a 32-bit — every byte contributes. equal-hash on a string is a
;; bounded-sample hash (~26 bytes regardless of length), so a same-length edit
;; away from the sampled offsets produces a cache collision.  This replaces it.
(define (aot-content-hash s)
  (let ((n (string-length s)))
    (let loop ((i 0) (h 2166136261))
      (if (fx=? i n)
          h
          (loop (fx+ i 1)
                (fxlogand (fx* (fxlogxor h (char->integer (string-ref s i)))
                               16777619)
                          #xFFFFFFFF))))))
;; The same hash over BYTES. A file a compile read is whatever the program said it
;; was — a .sql migration, an .edn config, a PNG — so it cannot be decoded as text
;; first; the third would raise.
(define (aot-bytes-hash bv)
  (let ((n (bytevector-length bv)))
    (let loop ((i 0) (h 2166136261))
      (if (fx=? i n)
          h
          (loop (fx+ i 1)
                (fxlogand (fx* (fxlogxor h (bytevector-u8-ref bv i))
                               16777619)
                          #xFFFFFFFF))))))
(define (aot-source-fingerprint)
  (let loop ((dirs aot-runtime-source-dirs) (h 17) (n 0))
    (if (null? dirs)
        (and (fx>? n 0) (string-append (number->string n 16) "-" (number->string h 16)))
        (let ((files (sort string<?
                           (filter aot-ss-file?
                                   (if (file-directory? (car dirs))
                                       (directory-list (car dirs))
                                       '())))))
          (let inner ((fs files) (h h) (n n))
            (if (null? fs)
                (loop (cdr dirs) h n)
                (let* ((p (string-append (car dirs) "/" (car fs)))
                       ;; an unreadable file just doesn't contribute; a real
                       ;; runtime change still moves some other file's hash.
                       (s (guard (e (else #f)) (read-file-string p))))
                  (if s
                      (inner (cdr fs)
                             (aot-hash-mix (aot-hash-mix h (string-length s)) (aot-content-hash s))
                             (fx+ n 1))
                      (inner (cdr fs) h n)))))))))
;; Computed at most once per process, and only when the cache is consulted, so
;; the source-tree walk never costs a run with the cache off (the default in the
;; dev bin/jolt) or a binary, which reads its baked value.
(define aot-fingerprint-memo 'unset)
(define (aot-runtime-fingerprint)
  (when (eq? aot-fingerprint-memo 'unset)
    (set! aot-fingerprint-memo
      (or (sa-baked-global 'jolt-baked-runtime-fingerprint)
          (aot-source-fingerprint))))
  aot-fingerprint-memo)
;; …-tr when the tail-frame history is on. Whether tracing is enabled changes the
;; CODE the emitter produces — an entry prologue per fn, plus a ring save/restore
;; around every non-tail call that can reach one — so a fasl is only valid for the
;; mode it was compiled under, and the generation has to say which. It did not, so
;; the two modes shared a generation and each was served the other's artifacts. Both
;; directions were wrong, and the frame-losing one is the worse: a traced run after
;; an untraced one reported NO history frames, the feature silently turned off by a
;; cache hit. (The reverse merely paid tracing's cost with tracing nominally off,
;; which is how it surfaced.) Read from the runtime flag rather than from JOLT_TRACE
;; directly, so a REPL that calls jolt.host/enable-trace! with the env var unset is
;; keyed correctly too. trace-smoke.sh gates both directions.
(define (aot-trace-tag) (if jolt-trace-on? "-tr" ""))
;; <dir>/<jolt-version>-<runtime fingerprint>[-tr]/v1 — the version names the release
;; a fasl came from, the fingerprint pins the exact runtime that emitted it. One
;; such GENERATION per runtime; rebuilding jolt starts a new one and strands the
;; last, so the first consult in a process also collects the superseded ones.
(define (aot-generation-dir)
  (string-append (aot-cache-dir) "/" (jolt-version-string)
                 "-" (aot-runtime-fingerprint) (aot-trace-tag)))
;; Generations are kept by LAST USE, not by age: a marker file refreshed once per
;; process is the only evidence a generation is still someone's, since a run that
;; hits on everything never writes to it.
(define aot-generations-kept 3)
(define aot-prune-grace-seconds 60)
(define (aot-used-marker gen) (string-append gen "/.used"))
(define (aot-touch-used! gen)
  (guard (e (else #f))
    (let ((out (open-output-file (aot-used-marker gen) 'replace)))
      (put-string out "jolt aot cache generation\n")
      (close-port out))))
(define (aot-file-seconds path)
  (guard (e (else 0))
    (div (sa-file-mtime-ms path) 1000)))
(define (aot-delete-tree path)
  (guard (e (else #f))
    (if (and (file-directory? path) (not (file-symbolic-link? path)))
        (begin
          (for-each (lambda (f) (aot-delete-tree (string-append path "/" f)))
                    (directory-list path))
          (delete-directory path))
        (delete-file path #f))))
;; Drop every generation that is neither the current one nor among the few most
;; recently used. The grace period keeps a generation another live process may be
;; midway through: worst case that process misses and recompiles (mkdir -p and the
;; corrupt-fasl guard both recover), so this is a throughput risk, never a crash.
(define (aot-prune-generations! current)
  (guard (e (else #f))
    (let* ((root (aot-cache-dir))
           (now (aot-file-seconds (aot-used-marker current)))
           (gens (filter (lambda (p)
                           (and (not (string=? (cdr p) current))
                                (file-directory? (cdr p))
                                (fx>? (- now (car p)) aot-prune-grace-seconds)))
                         (map (lambda (d)
                                (let ((p (string-append root "/" d)))
                                  (cons (aot-file-seconds (aot-used-marker p)) p)))
                              (if (file-directory? root) (directory-list root) '()))))
           ;; newest first; the current generation holds one of the kept slots
           (ordered (sort (lambda (a b) (> (car a) (car b))) gens))
           (doomed (if (fx>? (length ordered) (fx- aot-generations-kept 1))
                       (list-tail ordered (fx- aot-generations-kept 1))
                       '())))
      (for-each (lambda (p)
                  (aot-info (string-append "pruning superseded generation " (cdr p)))
                  (aot-delete-tree (cdr p)))
                doomed))))
;; The generation is stamped and swept once per process, on the first consult.
(define aot-generation-memo #f)
(define (aot-cache-subdir)
  (unless aot-generation-memo
    (let ((gen (aot-generation-dir)))
      (aot-mkdir-p gen)
      (aot-touch-used! gen)
      (aot-prune-generations! gen)
      (set! aot-generation-memo (string-append gen "/v1"))))
  aot-generation-memo)
(define (aot-cache-sanitize s)
  (list->string
    (map (lambda (c)
           (let ((n (char->integer c)))
             (if (or (and (>= n 48) (<= n 57))    ; 0-9
                     (and (>= n 65) (<= n 90))    ; A-Z
                     (and (>= n 97) (<= n 122))   ; a-z
                     (char=? c #\-) (char=? c #\.) (char=? c #\_))
                 c #\_)))
         (string->list s))))
;; length (hex) + full-content FNV-1a 32-bit hash (hex). FNV-1a is process-STABLE
;; (no randomized seed), so the key is reproducible across runs and machines —
;; required for the cache to hit at all. The length prefix stays as a cheap second
;; factor: a false share needs a genuine 32-bit collision BETWEEN SOURCES OF EQUAL
;; LENGTH, which is remote enough to sit below other failure modes here.
;;
;; This was equal-hash, which is NOT a content hash: Chez samples a bounded ~26
;; characters (first 6, ~15 strided, last 5) no matter how long the string is, so
;; for any real source ~99% of the bytes were invisible to the key. Length was
;; doing all the invalidation work, and any length-preserving edit — 42→99, <→>,
;; inc→dec, a rename to an equal-length name — kept the key and silently served
;; the previous fasl. Do not "optimize" this back to a sampling hash: the whole
;; cost is one linear pass over source jolt is about to compile anyway.
(define (aot-cache-key src)
  (string-append (number->string (string-length src) 16) "-"
                 (number->string (aot-content-hash src) 16)))
(define (aot-info msg)
  (when (getenv "JOLT_DEBUG")
    (display (string-append "[jolt.aot] " msg "\n") (current-error-port))))

;; --- dependency closure ------------------------------------------------------
;; A namespace's fasl bakes in what its dependencies contributed at compile time —
;; macro expansions, inlined defs, record shapes — so its own source hash does not
;; describe it. Editing a macro namespace left every consumer serving expansions of
;; a definition that no longer existed. The key therefore folds in the key of each
;; namespace this one required, which makes it transitive by construction: a change
;; three namespaces down moves each key on the path.
;;
;; The requires are learned by RECORDING them during the compile that produced the
;; fasl, not by re-parsing ns forms: the loader funnels every require/use through
;; ldr-load+register, so the record covers a top-level (require …) and a :require
;; clause alike. They are written beside the fasl, in a sidecar named by the
;; namespace's own hash alone — the one key derivable before its deps are known.
(define aot-dep-sink (make-thread-parameter #f))
(define (aot-new-dep-sink) (vector '()))
;; Called from ldr-load+register for every require target, whether or not the
;; target was already loaded — a dedup'd require is still a dependency.
(define (aot-record-dep! name)
  (let ((sink (aot-dep-sink)))
    (when (and (vector? sink) (not (member name (vector-ref sink 0))))
      (vector-set! sink 0 (cons name (vector-ref sink 0))))))

(define (aot-dep-sidecar base) (string-append base ".deps"))
(define (aot-write-dep-list! path names)
  (guard (e (else #f))
    (let ((out (open-output-file path 'replace)))
      (for-each (lambda (n) (put-string out n) (put-string out "\n")) names)
      (close-port out))))
(define (aot-read-dep-list path)
  (if (file-exists? path)
      (guard (e (else '()))
        (filter (lambda (s) (fx>? (string-length s) 0))
                (bld-string-lines-like (read-file-string path))))
      '()))
;; --- files read at compile time ----------------------------------------------
;; The same argument as the dependency closure, for the other thing a compile can
;; bake in. A macro that slurps a SQL migration embeds that file's CONTENTS in the
;; artifact; keying on the .clj alone left every consumer serving the previous
;; build's statements out of the cache, with nothing to notice — the .clj is
;; untouched, so its hash still matches (jolt#576).
;;
;; The reads are RECORDED during the compile, the way the requires are: io.ss's
;; io-file-read-sink is bound around the capture load and every user-facing read
;; (slurp, io/reader, io/input-stream, io/resource, Files/read*) announces its
;; path. That covers a path spelled any of the ways a program can spell one,
;; without the loader having to know which.
;;
;; The sidecar is written only when the namespace actually read something, so the
;; ordinary namespace carries no extra file — and it is DELETED when a recompile
;; reads nothing, since it is named by the own hash and a stale one would
;; otherwise still be found under an unchanged source.
(define (aot-res-sidecar base) (string-append base ".res"))
(define (aot-write-res-list! path paths)
  (if (null? paths)
      (guard (e (else #f)) (delete-file path #f))
      (aot-write-dep-list! path paths)))
;; What one recorded file contributes: its length and content, or 0 when it isn't
;; there. ABSENT has to be a value of its own rather than "no contribution":
;; (io/resource "003.sql") answering nil is a compile-time answer, and adding the
;; file has to move the key. An empty file hashes to something else (the fold of a
;; zero length with FNV's basis), so the two never collide.
(define (aot-file-digest path)
  (guard (e (else 0))
    (if (file-exists? path)
        (let ((bv (read-file-bytes path)))
          (aot-hash-mix (bytevector-length bv) (aot-bytes-hash bv)))
        0)))
;; The PATH is folded alongside its content, so gaining or losing an entry moves
;; the digest even when the contents happen to coincide. Sorted, like the deps, so
;; the result doesn't depend on the order the reads happened to be recorded in.
(define (aot-res-fold paths)
  (fold-left (lambda (h p)
               (aot-hash-mix (aot-hash-mix h (aot-content-hash p)) (aot-file-digest p)))
             17 (sort string<? paths)))
;; A dependency's recorded reads, for the transitive fold. Memoized per process
;; like the dep digest — a namespace required from several places is hashed once.
(define aot-res-digest-memo (make-hashtable string-hash string=?))
(define (aot-res-digest name own)
  (or (hashtable-ref aot-res-digest-memo name #f)
      (let ((d (aot-res-fold (aot-read-dep-list
                               (aot-res-sidecar (aot-base-for-own name own))))))
        (jolt-with-mutex ldr-tbl-mu (hashtable-set! aot-res-digest-memo name d))
        d)))

;; local line splitter — build.ss's is not loaded on the run path.
(define (bld-string-lines-like s)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((fx>=? i n) (reverse (if (fx>? i start) (cons (substring s start i) acc) acc)))
            ((char=? (string-ref s i) #\newline)
             (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc)))
            (else (loop (fx+ i 1) start acc))))))

;; A namespace contributes to a key only if it is cacheable: install-owned source
;; (stdlib, jolt-core) is part of the runtime and already covered by the runtime
;; fingerprint, so it is skipped — which keeps the walk to project and library
;; namespaces instead of the whole prelude.
(define (aot-cacheable-file name)
  (let ((f (find-ns-file name)))
    (and f (not (ldr-install-file? f)) f)))
(define aot-own-key-memo (make-hashtable string-hash string=?))
(define (aot-own-key name)
  (or (hashtable-ref aot-own-key-memo name #f)
      (let ((f (aot-cacheable-file name)))
        (and f (let ((k (aot-cache-key (ldr-read-source f))))
                 (jolt-with-mutex ldr-tbl-mu (hashtable-set! aot-own-key-memo name k))
                 k)))))
(define (aot-base-for-own name own) (string-append (aot-cache-subdir) "/"
                                                   (aot-cache-sanitize name) "-" own))
;; Fold the dep keys into one integer. Sorted, so the digest doesn't depend on the
;; order requires happened to be recorded in.
(define aot-dep-digest-memo (make-hashtable string-hash string=?))
;; The in-flight set is one walk's recursion stack — it exists only to stop
;; aot-dep-digest recursing forever on a require cycle — so it is keyed by THREAD
;; as well as namespace. Shared across threads it got the question wrong in both
;; directions once unrelated namespaces could load in parallel: another thread's
;; mark read here as a cycle and truncated this namespace's digest to its own
;; hash, which is a different and wrong cache key (an edit two deps down no longer
;; moves it, so a stale .so hits), and another thread's delete cleared the guard
;; out from under a walk that really was cyclic, which then recursed until the
;; stack gave out. Nothing is shared between the walks, so there is nothing here
;; two threads need to agree on.
(define aot-dep-inflight (make-hashtable string-hash string=?))
(define (aot-inflight-key name)
  (string-append (number->string (get-thread-id)) "\x0;" name))
(define (aot-ns-digest name)
  ;; a namespace's whole contribution: its own hash, the files its compile read,
  ;; and its deps'. All three so a change anywhere below reaches every consumer.
  (let ((own (aot-own-key name)))
    (if (not own)
        0
        (aot-hash-mix (aot-hash-mix (equal-hash own) (aot-res-digest name own))
                      (aot-dep-digest name own)))))
(define (aot-dep-digest name own)
  (or (hashtable-ref aot-dep-digest-memo name #f)
      (let ((ik (aot-inflight-key name)))
        (if (hashtable-ref aot-dep-inflight ik #f)
            ;; a require cycle: stop at the namespace's own hash. Every namespace on
            ;; the cycle still contributes it, so an edit anywhere still moves the key.
            (equal-hash own)
            (begin
              (jolt-with-mutex ldr-tbl-mu (hashtable-set! aot-dep-inflight ik #t))
              (let* ((deps (sort string<? (aot-read-dep-list
                                            (aot-dep-sidecar (aot-base-for-own name own)))))
                     (d (fold-left (lambda (h dep) (aot-hash-mix h (aot-ns-digest dep))) 17 deps)))
                (jolt-with-mutex ldr-tbl-mu
                  (hashtable-delete! aot-dep-inflight ik)
                  (hashtable-set! aot-dep-digest-memo name d))
                d))))))
;; The full cache base: own hash, then the dep digest folded with the digest of
;; the files this compile read. A namespace with no recorded deps or reads (or
;; none cacheable) folds to the digest of the empty list, so the suffix is
;; constant for the whole leaf case rather than absent.
(define (aot-base-full name own deps res)
  (string-append (aot-base-for-own name own) "-"
                 (number->string
                   (aot-hash-mix
                     (fold-left (lambda (h dep) (aot-hash-mix h (aot-ns-digest dep))) 17
                                (sort string<? deps))
                     (aot-res-fold res))
                   16)))
;; Tee the per-form emitted Scheme (compile-eval.ss jolt-aot-capture) while running
;; the normal load loop, so a cache miss reproduces the EXACT interleaved analyze
;; →eval semantics (forward macro refs and same-file requires expand correctly).
;; The captured Scheme, loaded in order, reproduces every top-level effect — the
;; same property `jolt build` / the seed mint rely on.
;; parameterize (not a bare set!) so a require fired by this ns's forms — which
;; itself triggers a nested aot-capture-load — restores OUR capture port on
;; return. A bare thread-parameter set would be clobbered by the nested capture
;; and reset to #f, dropping this ns's forms AFTER the require (the require's
;; target would cache, but the requiring ns's own defs would vanish from its .so).
(define (aot-capture-load file src)
  (let ((cap (open-output-string)))
    (parameterize ((jolt-aot-capture cap) (jolt-aot-capture-file file))
      (load-jolt-file* file src)
      (get-output-string cap))))
;; On a miss: run the capture load (which also evals the ns into the running
;; image), then fasl the captured Scheme. A compile-file failure is non-fatal —
;; the ns is already loaded; we just skip caching this run and miss again next.
;; mkdir -p without a subprocess. The built Windows jolt runs jolt-sh via
;; cmd.exe, where `mkdir -p <forward/slash/path>` is invalid syntax, so the
;; cache dir was never created and open-output-file failed. Native mkdir +
;; path-parent recursion is portable (mirrors build.ss bld-mkdir-p).
(define (aot-mkdir-p dir)
  (unless (or (string=? dir "") (string=? dir "/") (string=? dir ".") (file-exists? dir))
    (aot-mkdir-p (path-parent dir))
    ;; tolerate the benign race (created concurrently); re-raise a real failure.
    (guard (e (#t (unless (file-exists? dir) (raise e))))
      (mkdir dir))))
;; Publish the cached .scm/.so atomically. Parallel jolt processes (e.g. the cts
;; gate's workers) share one cache dir and can compile the SAME namespace at once;
;; writing straight to base.so let a reader's (file-exists? so)+load see a fasl
;; another process was mid-write, loading a truncated image that defined nothing
;; ("No namespace: X found"). So each process compiles to a pid-unique temp and
;; rename(2)s it into place — atomic within a filesystem, so the .so appears
;; complete-or-not-at-all. The .so (the cache-hit signal) is published LAST.
;; The .scm is also published via temp + rename, landing at its FINAL name BEFORE
;; the compile: compile-file bakes the name of the file it read into the frame
;; source objects, so compiling the temp would leave every cached frame pointing
;; at a path deleted by the rename. Temp+rename keeps a concurrent compiler from
;; ever seeing a half-written .scm (two processes race on base.scm; each sees a
;; complete file, and the content is a pure function of the key, so both write
;; the same bytes anyway).
;; The final base is only known AFTER the capture load: it folds in the deps, and
;; the deps are what that load records. Writing under the pre-load base instead
;; would strand the fasl — the next run computes the key WITH deps and misses it,
;; paying a second compile for every namespace that requires anything.
(define (aot-compile-and-cache name file src own)
  (let ((sink (aot-new-dep-sink))
        ;; the files this compile reads, collected the same way and for the same
        ;; reason (io.ss io-file-read-sink). A nested require binds its own, so a
        ;; dependency's reads are recorded against the dependency.
        (res-sink (vector '())))
    (let ((captured (parameterize ((aot-dep-sink sink) (io-file-read-sink res-sink))
                      (aot-capture-load file src))))
      (unless (and (string? captured) (fx>? (string-length captured) 0))
        (aot-info (string-append "nothing captured for " name ", not caching")))
      (when (and (string? captured) (fx>? (string-length captured) 0))
        (let* ((deps (filter aot-cacheable-file (vector-ref sink 0)))
               (res (vector-ref res-sink 0))
               (base (aot-base-full name own deps res))
               (scm (string-append base ".scm"))
               (so  (string-append base ".so"))
               (pid (number->string (get-process-id)))
               (tmp-scm (string-append base ".tmp" pid ".scm"))
               (tmp-so  (string-append base ".tmp" pid ".so")))
          (aot-mkdir-p (path-parent base))
          ;; the sidecars are named by the own hash alone, so the next run can read
          ;; them back before it is able to compute the full key.
          (aot-write-dep-list! (aot-dep-sidecar (aot-base-for-own name own)) deps)
          (aot-write-res-list! (aot-res-sidecar (aot-base-for-own name own)) res)
          ;; this run already computed digests for `name` from the OLD sidecars;
          ;; drop them so a later require in the same process sees the new ones.
          (jolt-with-mutex ldr-tbl-mu
            (hashtable-delete! aot-dep-digest-memo name)
            (hashtable-delete! aot-res-digest-memo name))
          (guard (e (else (aot-info (string-append "compile failed for " name))
                          (delete-file tmp-scm #f) (delete-file tmp-so #f) #f))
            (let ((out (open-output-file tmp-scm 'replace)))
              (put-string out captured) (close-output-port out))
            (rename-file tmp-scm scm)
            ;; compile-file prints "compiling X with output to Y" per file to
            ;; current-output-port by default — swallow it so a cache miss can't
            ;; corrupt the running program's stdout.
            (parameterize ((current-output-port (open-output-string)))
              (sa-compile-file scm tmp-so #f))
            (rename-file tmp-so so))
          (unless (file-exists? so)
            (aot-info (string-append "no .so produced for " name))))))))
;; A truncated/corrupt .so (a killed process left a partial write, or a concurrent
;; jolt is mid-write) would make `load` throw. Fall back to recompile: delete the
;; bad files so the miss path rebuilds them. Safe because a truncated fasl fails at
;; its header before any top-level define runs, so the image carries no half-loaded
;; state from the failed load. Non-fatal — a repeated failure just misses every run.
(define (aot-safe-load-or-recompile name file src own base)
  (let ((so (string-append base ".so")))
    (guard (e (else
                (aot-info (string-append "corrupt cache for " name ", recompiling"))
                (delete-file so #f)           ; best-effort; ignore if already gone
                (let ((scm (string-append base ".scm")))
                  (delete-file scm #f))
                (aot-compile-and-cache name file src own)))
      (load so))))
;; Dispatch for load-namespace*: cache hit (load .so) / miss (compile+cache) /
;; bypass (plain load). `file` is the resolved on-disk path. force? (:reload) and
;; ldr-reload-all? bypass entirely — live editing must win over a stale cache.
(define (aot-load-or-compile name file force?)
  (if (and (aot-cache-enabled?) (not force?) (not (ldr-reload-all?))
           (not (ldr-install-file? file))
           ;; no fingerprint = we can't tell this runtime from another one, so
           ;; there is no key that would be safe to reuse.
           (aot-runtime-fingerprint))
      ;; the deps and reads this ns's own load records belong to IT, not to
      ;; whoever is requiring it — bind fresh sinks so a nested load can't append
      ;; to the enclosing one. A hit binds #f on both: the fasl it loads re-runs
      ;; the requires and re-does the reads, and those are already described by
      ;; this namespace's own sidecars.
      (let* ((src (ldr-read-source file))
             (own (aot-cache-key src))
             (obase (aot-base-for-own name own))
             (base (aot-base-full name own
                                  (aot-read-dep-list (aot-dep-sidecar obase))
                                  (aot-read-dep-list (aot-res-sidecar obase))))
             (so (string-append base ".so")))
        (if (file-exists? so)
            (begin (aot-info (string-append "hit " name))
                   (parameterize ((aot-dep-sink #f) (io-file-read-sink #f))
                     (aot-safe-load-or-recompile name file src own base)))
            (begin (aot-info (string-append "miss " name))
                   (aot-compile-and-cache name file src own))))
      (parameterize ((aot-dep-sink #f) (io-file-read-sink #f)) (load-jolt-file file))))

;; Mark a namespace as loaded in both the host hashtable and the *loaded-libs* ref.
(define (ldr-mark-loaded! name)
  (jolt-with-mutex ldr-tbl-mu (hashtable-set! loaded-ns name #t))
  (ldr-libs-update! (lambda (s) (pset-conj s (jolt-symbol #f name)))))

;; Undo ldr-mark-loaded! — a failed load rolls its mark back so a retry loads.
(define (ldr-unmark-loaded! name)
  (jolt-with-mutex ldr-tbl-mu (hashtable-delete! loaded-ns name))
  (ldr-libs-update! (lambda (s) (pset-disj s (jolt-symbol #f name)))))

;; Has `name` cleared the loaded-ns / *loaded-libs* dedup? A tools.namespace disj
;; from *loaded-libs* forces a reload even though loaded-ns still holds.
;;
;; txn-read and not jolt-ref-val, because the disj this is here to honour is a USER
;; write and a user writes a ref through the STM. tools.namespace disj'ing inside a
;; (dosync …) should force the reload from the next form onward, not from the
;; commit. Outside a transaction txn-read IS jolt-ref-val, so the ordinary path is
;; unchanged, and it acquires nothing, so this stays safe to call under ldr-load-mu
;; (see ldr-libs-update!'s "a load must never take stm-lock"). The loader's own
;; marks are not in any log — ldr-libs-update! writes the ref directly, for the
;; reasons set out there — so this sees them whether a transaction is open or not.
(define (ns-dedup-loaded? name)
  (let* ((libs-cell (var-cell-lookup "clojure.core" "*loaded-libs*"))
         (libs-ref (and libs-cell (var-cell-root libs-cell))))
    (and (hashtable-ref loaded-ns name #f)
         (or (not libs-ref)
             (not (jolt-ref? libs-ref))
             (jolt-contains? (txn-read libs-ref) (jolt-symbol #f name))))))

;; --- clojure.core/compile + *compile-path* -----------------------------------
;; Clojure's `compile` writes a namespace's compiled form under *compile-path* so a
;; later load takes that instead of re-reading the source, and that directory has to
;; be on the classpath for the load side to find it (core.clj's docstring says so
;; outright). jolt keeps the shape and swaps two substrate details: the artifact is
;; a Chez fasl of the emitted Scheme — what the AOT cache above already produces —
;; rather than .class files, and the load side searches the source roots, which are
;; jolt's classpath.
;;
;;   <dir>/<ns-rel>.so     the fasl; published last, so its presence is the signal
;;   <dir>/<ns-rel>.scm    the emitted Scheme it was compiled from
;;   <dir>/<ns-rel>.meta   what it was compiled against (below)
;;
;; RT.load picks a .class over a .clj on mtime alone. A fasl is much less forgiving
;; than a class file — one emitted by a different jolt calls runtime helpers that
;; may not exist any more — so .meta pins the jolt version and the runtime
;; fingerprint, and a mismatch means the artifact is ignored rather than loaded in
;; hope. Staleness against the source is a content hash, not an mtime: same intent
;; as the JVM's comparison, immune to a bare touch, and the same rule the AOT cache
;; decides by. Like the JVM this does NOT walk the whole dependency graph — .meta
;; records the direct requires and their source hashes, so editing a namespace this
;; one requires invalidates it, but a change further down does not. Recompile
;; dependents, the same discipline an edited macro namespace needs under JVM AOT.
(define (cpath-so-file base) (string-append base ".so"))
(define (cpath-scm-file base) (string-append base ".scm"))
(define (cpath-meta-file base) (string-append base ".meta"))

;; The source content key an artifact for `name` can go stale against, or "" when
;; there is none to track: a namespace with no source file (only the artifact was
;; shipped), and install-owned source, which is part of the runtime and already
;; covered by the runtime fingerprint.
(define (cpath-source-key name)
  (let ((f (aot-cacheable-file name)))
    (if f (aot-cache-key (ldr-read-source f)) "")))

;; Does `name` still hash to what the artifact recorded for it? An empty key now
;; means there is no source to be stale against — the artifact-only deploy, where
;; RT.load takes the .class because there is no .clj beside it — so nothing to
;; check. A key that appeared where none was recorded (source shadowing an
;; install-owned namespace) does not match, and the artifact loses.
(define (cpath-key-current? recorded name)
  (let ((now (cpath-source-key name)))
    (or (string=? now "") (string=? now recorded))))

;; jolt version / runtime fingerprint / own source key, then one "name key" line
;; per direct require that has a key worth tracking.
(define (cpath-meta-lines name deps)
  (cons* (jolt-version-string)
         (or (aot-runtime-fingerprint) "")
         (cpath-source-key name)
         (map (lambda (d) (string-append d " " (cpath-source-key d)))
              (sort string<? deps))))

(define (cpath-write-meta! path lines)
  (let ((out (open-output-file path 'replace)))
    (for-each (lambda (l) (put-string out l) (put-string out "\n")) lines)
    (close-port out)))

;; "name key" -> ("name" . "key"); a dep with no key trails a bare space.
(define (cpath-split-dep-line s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond ((fx>=? i n) #f)
            ((char=? (string-ref s i) #\space)
             (cons (substring s 0 i) (substring s (fx+ i 1) n)))
            (else (loop (fx+ i 1)))))))

(define (cpath-meta-matches? name base)
  (let ((mf (cpath-meta-file base))
        (fp (aot-runtime-fingerprint)))
    (and fp                        ; no fingerprint = can't tell this runtime apart
         (file-exists? mf)
         (let ((lines (guard (e (else '())) (bld-string-lines-like (read-file-string mf)))))
           (and (fx>=? (length lines) 3)
                (string=? (list-ref lines 0) (jolt-version-string))
                (string=? (list-ref lines 1) fp)
                (cpath-key-current? (list-ref lines 2) name)
                (let loop ((ds (list-tail lines 3)))
                  (or (null? ds)
                      (let ((dep (cpath-split-dep-line (car ds))))
                        (and dep
                             (cpath-key-current? (cdr dep) (car dep))
                             (loop (cdr ds)))))))))))

(define (cpath-artifact-valid? name base)
  (and (file-exists? (cpath-so-file base))
       (cpath-meta-matches? name base)))

;; Set while a build driver walks an app's namespaces. `jolt build` emits each
;; namespace from its source, and it learns the load order (and the path to emit
;; from) through ns-loaded-hook — so a compiled artifact standing in for the source
;; would hand it a path with no source behind it. Compiled output is a load
;; shortcut; a build wants the real thing.
(define ldr-source-only? (make-thread-parameter #f))

;; The base path of the first usable artifact for `name` on the source roots, or
;; #f. This is the load side: the JVM finds compiled output through the classpath,
;; never through *compile-path* itself, so a compile-path takes effect on load only
;; once it is also a root.
(define (cpath-find-artifact name)
  (and (not (ldr-source-only?))
       (let ((rel (ns-name->rel name)))
         (let loop ((roots source-roots))
           (and (pair? roots)
                (let ((base (string-append (car roots) "/" rel)))
                  (if (cpath-artifact-valid? name base) base (loop (cdr roots)))))))))

;; The first artifact on the roots whatever its state, for the error path: an
;; artifact-only deployment that a jolt upgrade invalidated otherwise reports only
;; that the SOURCE is missing, which says nothing about the .so sitting right there.
(define (cpath-any-artifact name)
  (let ((rel (ns-name->rel name)))
    (let loop ((roots source-roots))
      (and (pair? roots)
           (let ((base (string-append (car roots) "/" rel)))
             (if (file-exists? (cpath-so-file base)) base (loop (cdr roots))))))))

;; *compile-path* as a directory string, or #f when it is nil — the case
;; Compiler.compile reports as "*compile-path* not set".
(define (cpath-dir)
  (let ((v (guard (e (#t jolt-nil)) (var-deref "clojure.core" "*compile-path*"))))
    (and (string? v) v)))

;; *compile-files* is true for the extent of a compile, as core.clj's compile binds
;; it — both so library code can read it and because load-namespace* branches on it
;; (cpath-compiling-dir) to carry the compile through the load closure.
(define (cpath-with-compile-files thunk)
  (let ((cell (var-cell-lookup "clojure.core" "*compile-files*")))
    (if (not cell)
        (thunk)
        (dyn-with-frame (list (cons cell #t)) thunk))))

;; Publish under `dir`, borrowing the AOT cache's discipline: compile to a
;; pid-unique temp and rename(2) each file into place, .so last, so a concurrent
;; reader sees a complete artifact or none. The stale .so goes first for the same
;; reason — until the new one lands there must be no signal pointing at old .meta.
;; The .scm lands at its FINAL name before the compile: compile-file bakes the
;; name of the file it read into the frame source objects, so compiling the temp
;; would leave every frame loaded from this artifact pointing at a path deleted
;; by the rename (same bug as the AOT cache's, fixed alongside it).
(define (cpath-publish! name dir captured deps)
  (let* ((base (string-append dir "/" (ns-name->rel name)))
         (pid (number->string (get-process-id)))
         (tmp-scm (string-append base ".tmp" pid ".scm"))
         (tmp-so  (string-append base ".tmp" pid ".so")))
    (aot-mkdir-p (path-parent base))
    (guard (e (else (delete-file tmp-scm #f) (delete-file tmp-so #f) (raise e)))
      (let ((out (open-output-file tmp-scm 'replace)))
        (put-string out captured) (close-output-port out))
      (rename-file tmp-scm (cpath-scm-file base))
      ;; compile-file narrates to current-output-port by default — swallow it so a
      ;; compile can't corrupt the running program's stdout.
      (parameterize ((current-output-port (open-output-string)))
        (sa-compile-file (cpath-scm-file base) tmp-so #f))
      (delete-file (cpath-so-file base) #f)
      (cpath-write-meta! (cpath-meta-file base) (cpath-meta-lines name deps))
      (rename-file tmp-so (cpath-so-file base)))
    base))

;; The compiling load: evaluate the namespace while capturing its emitted Scheme,
;; then publish that under `dir`. Returns the artifact base, or #f when the file
;; emitted nothing to compile.
;;
;; load-namespace* takes this branch instead of the plain load whenever
;; *compile-files* is set, which is how the JVM's `(compile 'lib)` ends up emitting
;; classes for lib's whole load closure rather than lib alone (RT.load: when
;; COMPILE_FILES is true and the class wasn't already loaded, compile the .clj).
;; Without it a compiled namespace is undeployable — its artifact still re-runs its
;; requires, and those would find nothing.
(define (cpath-compile-load name file dir)
  (let* ((src (ldr-read-source file))
         (sink (aot-new-dep-sink))
         (captured (parameterize ((aot-dep-sink sink)) (aot-capture-load file src))))
    (and (string? captured) (fx>? (string-length captured) 0)
         (cpath-publish! name dir captured (filter aot-cacheable-file (vector-ref sink 0))))))

;; Is a compile in progress and pointed somewhere? Install-owned source is exempt:
;; it is part of the runtime (already covered by the runtime fingerprint), and
;; emitting a copy of the stdlib into the user's output directory would shadow the
;; runtime's own on every later load.
(define (cpath-compiling-dir file)
  (and (jolt-truthy? (guard (e (#t #f)) (var-deref "clojure.core" "*compile-files*")))
       (not (ldr-install-file? file))
       (cpath-dir)))

;; clojure.core/compile — core.clj's (binding [*compile-files* true] (load-one lib
;; true true)) wrapped in Compiler.compile's *compile-path* check. Like load-one it
;; loads the namespace into the running image (ignoring the already-loaded dedup,
;; so a compile always recompiles), verifies the file actually produced the
;; namespace, marks it loaded, and returns the lib.
(define (jolt-compile lib)
  (let* ((name (cond ((symbol-t? lib) (symbol-t-name lib))
                     ((string? lib) lib)
                     (else (throw-jvm 'java.lang.IllegalArgumentException
                                      (string-append "compile expects a namespace symbol, got "
                                                     (jolt-pr-str lib))))))
         (dir (or (cpath-dir)
                  (throw-jvm 'java.lang.RuntimeException "*compile-path* not set")))
         (file (or (find-ns-file name)
                   (throw-jvm 'java.io.FileNotFoundException
                              (string-append "Could not locate " (ns-name->rel name)
                                             ".jolt (or .clj/.cljc) on the source roots"))))
         (saved (chez-current-ns))
         (base (guard (e (else (set-chez-ns! saved) (raise e)))
                 (cpath-with-compile-files
                   (lambda () (cpath-compile-load name file dir))))))
    (set-chez-ns! saved)
    (unless (or (ns-has-vars? name) (hashtable-ref ns-registry name #f))
      (throw-jvm 'java.lang.Exception
                 (string-append "namespace '" name "' not found after loading '" file "'")))
    (unless base
      (throw-jvm 'java.lang.RuntimeException
                 (string-append "compile produced no code for " name)))
    (ldr-mark-loaded! name)
    (ns-loaded-hook name file)
    lib))
(def-var! "clojure.core" "compile" jolt-compile)

;; :reload-all forces the dedup off for the whole dynamic extent of a load (the
;; loader learns dependencies only as it loads them), so every namespace pulled in
;; reloads too — mirroring clojure.core. :verbose prints each load to stderr.
(define ldr-reload-all? (make-thread-parameter #f))
(define ldr-verbose? (make-thread-parameter #f))

;; --- the load protocol (concurrent require) ---------------------------------
;; Two threads requiring one namespace at once both used to pass the loaded-ns
;; check and both run its top-level forms, double-running every def and side
;; effect in the file. The mark-before-load below terminates a require CYCLE, but
;; only re-entry on ONE thread — to another thread the mark just says "loaded"
;; while the namespace is still half-built, which is worse than no dedup at all.
;;
;; This is JLS 12.4.2, the JVM's class-initialization procedure, over namespaces
;; instead of classes. It is the design that fits: initialization here is
;; dynamic, re-entrant, and allowed to be cyclic, which is exactly the shape the
;; JLS procedure exists for. Its step 3 IS jolt's existing mark-before-load
;; semantics, so nothing that works today changes; step 2 is the part that was
;; missing. The steps, and where each one lives:
;;
;;   1. acquire the lock                          -> ldr-load-mu
;;   2. in progress by ANOTHER thread: release,   -> condition-wait, then re-loop
;;      block until notified, repeat
;;   3. in progress by THIS thread: release and   -> 'recursive (a require cycle;
;;      complete normally (recursive request)        the caller sees a partially
;;                                                   loaded ns, as on the JVM)
;;   4. already initialized: release, return      -> 'loaded
;;   6. record in-progress-by-this-thread,        -> 'claimed, and the load then
;;      release, and initialize WITHOUT the lock     runs unlocked
;;  11. on success acquire, mark done, NOTIFY ALL -> ldr-end-load!
;;  12. on failure jolt rolls the mark back so a  -> the guard in load-namespace*
;;      retry can load, where the JVM marks the      (Clojure's behavior, and the
;;      class permanently erroneous                  file's existing behavior)
;;
;; Per namespace and not one global lock, so unrelated namespaces load in parallel
;; and a load that blocks only blocks threads wanting THAT namespace. Clojure went
;; the other way — serialized-require is (locking RT/REQUIRE_LOCK (apply require
;; args)) — but it is private and its own docstring calls it an "Interim function",
;; and it serializes every load in the process. Go avoids the question entirely
;; (package init is one goroutine, sequential, one package at a time, and import
;; cycles are a compile error); none of that is available here.
;;
;; Loading in parallel means COMPILING in parallel, which the compiler had to be
;; made safe for first: its emit-session scratch (the per-def cache cells and the
;; hoisted constant pool) lived on one process-global unit and was swapped in and
;; out around each def, so two threads emitting at once traded collectors and a
;; namespace that compiled cleanly alone died with "variable _kc$81 is not bound".
;; Those are thread-bound vars in backend_scheme now, the analyzer's position box is
;; per compilation, and its gensym counter reads and bumps in one swap!. See
;; test/chez/concurrent-require.clj, which loads distinct namespaces in parallel for
;; exactly this reason.
;;
;; The JVM's own hazard is that two threads entering a genuine require cycle from
;; opposite ends deadlock — spec-conformant, and OpenJDK closed JDK-8037567 and
;; two earlier reports as won't fix. We do not have to inherit the hang: the
;; owner of each in-flight load is already recorded, so ldr-wait-cycle walks the
;; wait-for graph and we raise instead. That changes nothing for a program that
;; works today; it only turns an undiagnosable hang into an error that names both
;; namespaces and both threads.
;;
;; Ownership is by EXECUTION CONTEXT — the fiber when a fiber is loading, the
;; thread id otherwise (ldr-load-ctx) — which is what makes step 3 a cycle break
;; rather than a self-deadlock, and it survives a park: a fiber is pinned to its
;; carrier for life (R0(d)), so a load that parks resumes as the same context and
;; load-namespace* deliberately keeps the claim across the park rather than
;; treating the escape as an exit.
;;
;; A load CAN park. (require 'x) from a go block on the :fiber backend, where x's
;; top level does a blocking channel op, is the shape, and it is the only way one
;; context ever observes another's claim on one carrier — same-carrier fibers do
;; not run concurrently. Everyone else wanting x then waits in step 2 until the
;; fiber comes back and finishes, which is the right answer and better than the
;; pre-protocol behaviour (they read the mark-before-load and returned with x
;; half-built).
;;
;; Thread id alone was not enough for that, because two fibers on one carrier share
;; one: a sibling fiber read the parked load's claim as its own, took step 3, and
;; returned with x half-loaded and no error. Nor is it enough to make a sibling
;; wait, because the wait itself has to be a PARK — a condition-wait would block the
;; carrier the parked load needs in order to finish. ldr-wait-for-load! picks the
;; mechanism from the waiter, and the cycle walk keys on the context, so two fibers
;; deadlocking over each other's loads is reported like any other cycle instead of
;; hanging.
;;
;; One behaviour improves as a side effect: :reload-all over a require cycle used
;; to recurse forever, because it turns the dedup off for the whole extent and
;; the mark was then no longer a stopping condition. Step 3 stops it.
;;
;; WHAT IS ACTUALLY PROVED, and what each proof rests on. Every transition below
;; happens under ldr-load-mu, which is what makes single-step reasoning sound: no
;; other thread can change ldr-loading or ldr-waiting between a check and the write
;; that follows it.
;;
;;   Mutual exclusion   pc = in-body implies you own the claim. Inductive over every
;;                      transition (claim, wait, recursive, end, escape, re-enter).
;;                      This is why ldr-assert-claim! refuses re-entry instead of
;;                      re-taking the claim: re-taking it is a single step that
;;                      breaks the invariant, putting two threads in one load body.
;;   No lost wakeup     a blocked waiter always has an owner left to wake it. Rests
;;                      on the wait committing before the lock drops — condition-wait
;;                      releases ldr-load-mu atomically with blocking, and a fiber
;;                      registers itself and sets its own state to 'parked while the
;;                      lock is still held (its SWITCH is outside the lock, which is
;;                      a separate matter and jolt-lock-wait's; what this property
;;                      needs is the commit, not the switch) — so no ldr-end-load!
;;                      fits between the owner check and the wait, and on
;;                      ldr-end-load! broadcasting
;;                      AND resuming from dynamic-wind's after thunk, which runs on
;;                      every exit. The LOADER's own park is not an exit and is
;;                      skipped there, which keeps the property rather than weakening
;;                      it: the owner is still recorded, still the same context, and
;;                      still on its way back to finish the load and wake everyone.
;;   Cycle detection    ldr-wait-cycle fires on exactly the waits that would
;;                      deadlock: it never misses a cycle and never raises on a
;;                      graph that would still have made progress. Rests on the
;;                      wait-for graph being FUNCTIONAL (one namespace per blocked
;;                      context, one owner per namespace) and on the pre-state being
;;                      acyclic, which holds because every earlier wait was checked.
;;   No deadlock        the lock graph is acyclic, and the edge that is hardest to
;;                      see is the one a park used to add: a fiber parked inside this
;;                      critical section left a blocking re-acquire of ldr-load-mu on
;;                      its resume, which runs in the scheduler and puts every fiber
;;                      on that carrier behind it. That edge is gone rather than
;;                      argued about — the switch happens with the lock released, and
;;                      locks.ss checks it at both switch points (jolt-04ee). The one
;;                      edge that is not the loader's to remove is stm-lock -> the load a parked
;;                      transaction is waiting for, because jolt-sync holds
;;                      stm-lock across a whole dosync body. So no load may acquire
;;                      stm-lock — see ldr-libs-update!, where that cycle was real
;;                      and hung.
(define ldr-load-mu (make-mutex))
(define ldr-load-cv (make-condition))
(define ldr-loading (make-hashtable string-hash string=?))  ; ns -> the context loading it
(define ldr-waiting (make-eqv-hashtable))                   ; context -> ns it waits on
(define ldr-fiber-waiters (make-hashtable string-hash string=?))  ; ns -> parked fibers

;; --- who a load belongs to ---------------------------------------------------
;; The FIBER when a fiber is loading, and the thread id otherwise. Thread id alone
;; was wrong in both directions once a load could park, because two fibers on one
;; carrier share one. Fiber A's load parks; fiber B on the same carrier requires the
;; same namespace, reads A's claim as its own, takes step 3 and returns with the
;; namespace half-loaded, silently. A fiber is the finer identity and it is the right
;; one: step 3 asks "am I already inside this load", and the answer is per execution,
;; not per OS thread. It is only ever compared and used as a table key, never
;; dereferenced, so nothing here depends on the fiber record's shape.
;;
;; Same-carrier fibers never run concurrently, so B can only ever observe A's claim
;; while A is PARKED — this is the parked-load case and nothing else.
(define (ldr-load-ctx) (or (jolt-current-fiber) (get-thread-id)))
(define (ldr-ctx-str ctx)
  (if (jolt-fiber? ctx) "a fiber" (string-append "thread " (number->string ctx))))

;; Wait for the load of `name` to end. Runs inside jolt-lock-wait's decision, so
;; ldr-load-mu is HELD. Answers #f when the wait is over and the caller should
;; re-check under the lock, or jolt-lock-parked when this fiber has committed to a
;; park that jolt-lock-wait will perform once it has released the lock. A wakeup is
;; "something changed", never "the namespace is yours", either way.
;;
;; A fiber must not use the condition variable. condition-wait blocks the CARRIER
;; thread, and the load it is waiting for is very likely parked on that same carrier
;; (see above), so blocking there is a deadlock, and even when the owner is on
;; another thread it stalls every unrelated fiber the carrier is running. It parks
;; instead, and ldr-end-load! resumes it.
;;
;; NO WAKEUP IS LOST, and the reason is the registration and the 'parked commit both
;; happening under ldr-load-mu, which ldr-end-load! must take: a release either lands
;; before them and is seen by the re-check, or after them and finds a fiber to resume.
;; The SWITCH is the one part that happens outside the lock (jolt-04ee). It used to
;; happen right here, inside the critical section, leaning on jolt-with-mutex being a
;; dynamic-wind to release the lock on the way out and re-acquire it on the resume.
;; That is not safe, for the reason host/chez/locks.ss now states as a rule: the
;; re-acquire runs from Chez's rewind, on the carrier thread, at the interrupt depth
;; the fiber parked at, and the carrier can do nothing else until it succeeds — so the
;; park attaches a blocking acquire to a point in the scheduler, and every fiber on
;; that carrier is behind it. Every fiber and thread requiring any namespace passes
;; through this same region, so the precondition that would have licensed it does not
;; hold here any more than it held for the object monitor (jolt-3a87, jolt-dfuo).
;;
;; Committing here and switching there is also what keeps load-namespace*'s after
;; thunk honest: the escape is still a park and still not an exit, so that one still
;; asks jolt-park-unwinding? and keeps the claim across it.
(define (ldr-wait-for-load! name)
  (let ((f (jolt-current-fiber)))
    (if f
        (begin
          (hashtable-set! ldr-fiber-waiters name
                          (cons f (hashtable-ref ldr-fiber-waiters name '())))
          (jolt-fiber-state-set! f 'parked)
          jolt-lock-parked)
        (begin (jolt-condition-wait ldr-load-cv ldr-load-mu) #f))))

;; Call with ldr-load-mu HELD. Would `me` waiting on `name` (owned by `owner`) close
;; a cycle? Follow owner -> what it waits on -> who owns that -> …; if the chain
;; reaches `me`, everyone in it is waiting on everyone else. Returns the chain as a
;; list of (context . ns-it-waits-on) in wait order, or #f if there is no cycle — the
;; error names every context in it, because a cycle of three reported as two sends
;; you looking for a two-namespace cycle that isn't there. Bounded so a table
;; mutated under us can never spin.
;;
;; Contexts and not thread ids, which is what extends this to fibers: two fibers on
;; one carrier that park mid-load waiting on each other are a genuine cycle, and
;; keyed by thread id they collided in ldr-waiting and the walk could not see it.
(define (ldr-wait-cycle owner me)
  (let loop ((t owner) (n 0) (acc '()))
    (and (fx< n 256)
         (let ((w (hashtable-ref ldr-waiting t #f)))
           (and w
                (let ((o (hashtable-ref ldr-loading w #f))
                      (acc (cons (cons t w) acc)))
                  (and o (if (eqv? o me) (reverse acc) (loop o (fx+ n 1) acc)))))))))

;; "thread 3 waits on a/b (held by thread 5), thread 5 waits on …" — the wait-for
;; chain the caller is about to close, rendered in the order it was walked. Fibers
;; render as "a fiber" rather than being numbered; the namespaces are what names the
;; cycle, and a fiber has no id to print.
(define (ldr-wait-chain-str chain)
  (let loop ((c chain) (out ""))
    (if (null? c)
        out
        (loop (cdr c)
              (string-append out (if (string=? out "") "" ", ")
                             (ldr-ctx-str (caar c))
                             " waits on " (cdar c))))))

;; Every way out of the decision below leaves the wait-for graph as it found it.
;; Deleting on the way out rather than immediately after each wait is what lets the
;; entry STAND while this context is parked, which is the point of recording it: a
;; cycle is only visible to another context's walk if the waits in it are all on the
;; table at once. A delete with nothing to delete is a no-op, so the first-iteration
;; exits (steps 3 and 4) cost one lookup and say what they mean.
(define (ldr-decided! me v) (hashtable-delete! ldr-waiting me) v)

;; -> 'loaded | 'recursive | 'claimed. Steps 1-6.
;;
;; The whole decision is jolt-lock-wait's `decide`: it runs under ldr-load-mu, and a
;; fiber that has to wait answers jolt-lock-parked, is switched out with the lock
;; RELEASED, and then runs this again from the top. Retaking it rather than resuming
;; into the middle of it is the same thing step 2 always did on a thread's wakeup —
;; the loop below — and it is now the same code path for both contenders.
(define (ldr-begin-load! name force?)
  (let ((me (ldr-load-ctx)))
    (jolt-lock-wait ldr-load-mu
      (lambda ()
        (let loop ()
          (let ((owner (hashtable-ref ldr-loading name #f)))
            (cond
              ((and owner (eqv? owner me))                    ; step 3
               (ldr-decided! me 'recursive))
              (owner                                          ; step 2
               (let ((chain (ldr-wait-cycle owner me)))
                 (when chain
                   (throw-jvm (quote IllegalStateException)
                     (string-append
                       "Deadlocked require: " (ldr-ctx-str me)
                       " is about to wait on " name " (held by "
                       (ldr-ctx-str owner) "), and " (ldr-wait-chain-str chain)
                       ", which closes back on " (ldr-ctx-str me) ". "
                       (number->string (fx+ 1 (length chain)))
                       " loads entered a require cycle from different ends; break"
                       " the cycle or require these namespaces from one thread."))))
               (hashtable-set! ldr-waiting me name)
               ;; a thread's wait ends under this lock, so it loops HERE; a fiber
               ;; answers jolt-lock-parked and comes back in at the top.
               (or (ldr-wait-for-load! name) (loop)))
              ((and (not force?) (not (ldr-reload-all?)) (ns-dedup-loaded? name))
               (ldr-decided! me 'loaded))                     ; step 4
              (else (hashtable-set! ldr-loading name me)      ; step 6
                    (ldr-decided! me 'claimed)))))))))

;; Step 11: drop the claim and wake everyone waiting on this namespace. Broadcast
;; and not signal — the waiters re-check a condition that may not be true for all
;; of them (a failed load leaves the namespace unloaded, and exactly one of them
;; should go on to claim it). Parked fibers are woken the same way and for the same
;; reason: resume them all and let them re-check.
;;
;; Both under the lock, so a waiter that has registered but not yet parked cannot be
;; missed — it registered with the lock held and stays committed to the park until
;; the escape drops it. The list is cleared as it is drained, so a fiber that goes
;; on to wait again registers itself afresh and no resume is ever delivered twice.
;; sa-fiber-resume takes only its carrier's run-queue mutex, which is the last lock
;; in the order, so calling it from here closes no cycle.
(define (ldr-end-load! name)
  (jolt-with-mutex ldr-load-mu
    (hashtable-delete! ldr-loading name)
    (let ((fs (hashtable-ref ldr-fiber-waiters name '())))
      (unless (null? fs)
        (hashtable-delete! ldr-fiber-waiters name)
        (for-each sa-fiber-resume fs)))
    (condition-broadcast ldr-load-cv)))

;; The dynamic-wind before thunk below: the claim must be ours. On first entry it is,
;; because ldr-begin-load! has just set it, so this is a check and nothing more.
;;
;; It re-runs if a continuation captured inside a load escapes and is then re-entered.
;; A PARK is that, and it is not an exit — the after thunk below keeps the claim
;; across one, so the resumed load still owns it and this passes.
;;
;; Any OTHER re-entry is refused. Re-taking the claim unconditionally looks like the
;; natural mirror of dropping it on the way out, and it is wrong: the load has ended
;; by then and another thread can own the namespace, so the re-entering thread would
;; take the claim out from under a thread that is running the body, and both would be
;; in it at once. There is no version of that re-entry that keeps "in the body implies
;; you hold the claim" true, so it is refused rather than papered over.
(define (ldr-assert-claim! name)
  (let ((me (ldr-load-ctx)))
    (jolt-with-mutex ldr-load-mu
      (let ((owner (hashtable-ref ldr-loading name #f)))
        (unless (eqv? owner me)
          (throw-jvm (quote IllegalStateException)
            (string-append
              "Re-entered the load of " name " on " (ldr-ctx-str me)
              ", which no longer holds its claim ("
              (if owner (string-append (ldr-ctx-str owner) " does")
                  "the load has already ended")
              "). A continuation captured inside a load cannot be resumed; the"
              " namespace would be loaded twice at once.")))))))

;; load-namespace: load `name`'s source once. Marked loaded BEFORE eval so a
;; dependency cycle terminates (Clojure's behavior). force? (a :reload of the
;; named lib) bypasses the dedup for THIS load only; ldr-reload-all? bypasses it
;; for this load and every nested one in its extent. On a throw the mark is rolled
;; back IF this call made it (a retry then loads) and the caller's ns is restored —
;; matching Clojure, which marks a lib loaded only after success.
(define (load-namespace name) (load-namespace* name #f))
(define (load-namespace* name force?)
  ;; steps 1-6 above: 'loaded and 'recursive are both "complete normally, do
  ;; nothing"; only 'claimed means this thread owns the load and must run it.
  (when (eq? 'claimed (ldr-begin-load! name force?))
    ;; read AFTER claiming, not before: while this thread was waiting in step 2
    ;; another may have loaded the namespace and then had its own load fail, and
    ;; a stale #t here would make the guard below skip the rollback.
    (let ((was-loaded? (ns-dedup-loaded? name))
          (finished? #f))
      ;; step 11/12: drop the claim and wake the waiters on EVERY exit. dynamic-wind
      ;; and not a guard: a guard only sees a raise, and any other way out of the
      ;; body — a continuation escaping the load — would leave the claim standing,
      ;; which is a namespace no other thread can ever load and no error to say why.
      ;; The inner guard in ldr-load-body still rolls the mark back and re-raises, so
      ;; the throw path is unchanged.
      ;;
      ;; A PARK is the one escape that is not an exit, and it has to be told apart
      ;; from the others. A fiber whose load parks — a top-level (<!! ch) in a
      ;; namespace required from a go block on the :fiber backend — comes back and
      ;; carries the load on from the park point, on the SAME thread, because R0(d)
      ;; pins a fiber to its carrier for life. Treating that as an exit dropped the
      ;; claim, woke the waiters onto a half-built namespace, and then made the
      ;; resume die in ldr-assert-claim! with the mark still standing and the
      ;; rollback stranded in the abandoned guard — so the namespace was wedged
      ;; loaded-but-empty for the life of the process and every later require of it
      ;; no-op'd. jolt-park-unwinding? answers that question: cleanup belonging to
      ;; the real exit does not run on a park.
      ;;
      ;; jolt's own try/finally used to consult the same flag and no longer does.
      ;; The back end now emits a shared marker (values.ss jolt-finally-in) as
      ;; every finally's before-thunk and the scheduler drops those winders off
      ;; the chain before it escapes, so a finally never runs on a park in the
      ;; first place. That trick is not available here, because THIS wind needs a
      ;; before-thunk of its own: ldr-assert-claim! has to re-run when the fiber
      ;; resumes. A winder that must rewind cannot be dropped, so it stays on the
      ;; chain and asks instead. It is the only such site left.
      ;;
      ;; And when it IS the real exit, a body that neither finished nor raised
      ;; (a continuation escaping the load for good) never reached ldr-load-body's
      ;; guard, so the mark is rolled back here instead. Idempotent against the
      ;; guard's own rollback on the throw path.
      (dynamic-wind
        (lambda () (ldr-assert-claim! name))
        (lambda () (ldr-load-body name force? was-loaded?) (set! finished? #t))
        (lambda ()
          (unless (jolt-park-unwinding?)
            (unless (or finished? was-loaded?) (ldr-unmark-loaded! name))
            (ldr-end-load! name)))))))

;; The load itself, run by the one thread that claimed it (never concurrently for
;; a given name, and never re-entered for it on this thread).
(define (ldr-load-body name force? was-loaded?)
  ;; A compiled artifact on the roots wins over the source, like RT.load
  ;; preferring a .class to its .clj. :reload does NOT bypass it, also like the
  ;; JVM: the artifact is only offered here when it still matches the source it
  ;; was built from, so there is nothing stale for a reload to get past.
  (let* ((file (find-ns-file name))
         (art (cpath-find-artifact name)))
    (cond
      ((or art file)
       (when (ldr-verbose?)
         (display (string-append "Loading " name " from " (or art file) "\n")
                  (current-error-port)))
       (ldr-mark-loaded! name)            ; mark before load so a cycle terminates
       (let ((saved (chez-current-ns)))
         ;; the ns restore is on the way out, not written twice on the two paths
         ;; that used to reach it — a load leaving *ns* pointing at the file it was
         ;; part way through is the kind of damage that surfaces three forms later
         ;; somewhere else, so it happens however the body exits.
         (dynamic-wind
           (lambda () #f)
           (lambda ()
             (guard (e (else
                         (unless was-loaded? (ldr-unmark-loaded! name)) ; roll the mark back
                         (raise e)))
               (cond
                 (art (load (cpath-so-file art)))
                 ;; inside a compile, loading from source also emits the artifact
                 ;; — RT.load's COMPILE_FILES branch, which is what carries a
                 ;; compile through to the whole load closure.
                 ((cpath-compiling-dir file)
                  => (lambda (dir) (cpath-compile-load name file dir)))
                 (else (aot-load-or-compile name file force?)))))
           (lambda () (set-chez-ns! saved)))   ; the current ns is thread-local
         ;; the hook feeds `jolt build`, which needs the SOURCE path; an
         ;; artifact-only namespace has none to give.
         (ns-loaded-hook name (or file art))))
      ;; No source file but the namespace exists in memory (AOT'd into a built
      ;; binary): it's already defined — mark loaded and move on.
      ((ns-has-vars? name)
       (ldr-mark-loaded! name))
      ;; Same-file namespace (inlined ns form in a Jolt file): registered via
      ;; intern-ns! in the runtime registry even if no vars bear its ns name yet.
      ((hashtable-ref ns-registry name #f)
       (ldr-mark-loaded! name))
      (else
        (let ((art (cpath-any-artifact name)))
          (throw-jvm (quote java.io.FileNotFoundException)
            (string-append "Could not locate " (ns-name->rel name)
                           ".jolt (or .clj/.cljc) on the source roots"
                           (cond
                             ((not art) "")
                             ;; a build asked for source and there is only an
                             ;; artifact — say that, rather than blame the artifact
                             ((ldr-source-only?)
                              (string-append "; only the compiled " (cpath-so-file art)
                                             " is there, and a build emits from source"))
                             (else
                               (string-append "; " (cpath-so-file art)
                                              " was compiled by a different jolt build, or"
                                              " a namespace it requires has changed — recompile it"))))))))))

;; load-file: load an explicit path (a `run FILE`), in the current ns.
(define (jolt-load-file path)
  (load-jolt-file path)
  jolt-nil)

;; A libspec under a prefix joins onto it: a bare symbol `string` -> `prefix.string`,
;; a vector `[string :as s]` -> `[prefix.string :as s]` (opts preserved).
(define (prefix-join prefix lib)
  (cond
    ((symbol-t? lib) (jolt-symbol #f (string-append prefix "." (symbol-t-name lib))))
    ((pvec? lib)
     (let ((items (seq->list lib)))
       (if (and (pair? items) (symbol-t? (car items)))
           (apply jolt-vector (jolt-symbol #f (string-append prefix "." (symbol-t-name (car items)))) (cdr items))
           lib)))
    (else lib)))

;; The prefix-list form of a require/use spec: a LIST `(prefix lib …)` expands to
;; one spec per lib (prefix.lib), so (:require (clojure [string :as str])) means
;; clojure.string :as str. A list with a KEYWORD second element is a single
;; libspec (the jolt superset — see parse-libspec in ns.ss), not a prefix list;
;; a vector / symbol spec is already a single lib.
(define (expand-spec s)
  (if (or (cseq? s) (empty-list-t? s))
      (let ((items (seq->list s)))
        (if (prefix-list-items? items)
            (map (lambda (lib) (prefix-join (symbol-t-name (car items)) lib)) (cdr items))
            (list s)))
      (list s)))

;; --- require/use that LOAD ---------------------------------------------------
;; Override the alias-only versions from natives-str.ss. Load each spec's target
;; (no-op if baked/already loaded), THEN register its :as/:refer under the caller
;; ns (chez-register-spec! reads the current ns, restored by load-namespace).
;;
;; keyword flags (clojure.core load-libs) are collected from the arg list before
;; the libspecs: :reload forces the named libs past the dedup, :reload-all forces
;; it off for the whole load (so transitively-required libs reload too), :verbose
;; prints each load.
(define (ldr-flag-names specs)
  (let loop ((xs specs) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((keyword? (car xs)) (loop (cdr xs) (cons (keyword-t-name (car xs)) acc)))
          (else (loop (cdr xs) acc)))))

;; Load each expanded libspec's target (no-op if baked/already loaded), register
;; its :as/:refer under the caller ns, and — for `use` (use? #t) — refer every
;; public var when the spec has no :only/:refer filter. Target + opts both come
;; from the shared parse-libspec (ns.ss): the single spec->target+opts parser
;; routed through by loader-require / loader-use / chez-register-spec! /
;; ce-scan-requires!.
(define (ldr-load+register specs force-named? use?)
  (for-each
    (lambda (s0)
      (for-each
        (lambda (s)
          (let* ((parsed (parse-libspec s))
                 (target (and parsed (car parsed)))
                 (opt-names (if parsed (map car (cdr parsed)) '()))
                 ;; :as-alias establishes the alias WITHOUT loading the target — for
                 ;; a namespace that may not exist yet, or exists only to qualify
                 ;; keywords. clojure.core's load-lib picks the loader with
                 ;; `need-ns (or as use)`, falling to (create-ns lib) when the spec
                 ;; is :as-alias and neither — so a spec that also carries :as, or
                 ;; that arrives through `use`, still loads.
                 (alias-only? (and target
                                   (member "as-alias" opt-names)
                                   (not (member "as" opt-names))
                                   (not use?))))
            ;; record BEFORE loading: a target already loaded is still a
            ;; dependency of whoever is being compiled, and load-namespace*
            ;; would dedup it away. An alias-only spec loads nothing, so it is
            ;; a dependency of nothing.
            (when (and target (not alias-only?)) (aot-record-dep! target))
            (cond
              ((not target) #f)
              (alias-only? (intern-ns! target))   ; create-ns, without loading
              (else (load-namespace* target force-named?)))
            (chez-register-spec! (chez-current-ns) s)
            (when (and use? target
                       (not (or (member "only" opt-names) (member "refer" opt-names))))
              (chez-register-refer-all! (chez-current-ns) target)
              ;; [ns :exclude [names]] — the excluded names stay OUT of the
              ;; refer-all set (load-lib applies the same filter to its refer).
              (let ((excl (assoc "exclude" (cdr parsed))))
                (when excl
                  (chez-register-refer-all-excludes!
                    (chez-current-ns) target
                    (map symbol-t-name (filter symbol-t? (seq->list (cdr excl))))))))))
        (expand-spec s0)))
    specs))

(define (loader-require . specs)
  (let* ((flags (ldr-flag-names specs))
         (real (filter (lambda (s) (not (keyword? s))) specs))
         (reload-all? (member "reload-all" flags))
         (reload? (and (not reload-all?) (member "reload" flags)))
         (verbose? (member "verbose" flags)))
    (if reload-all?
        (parameterize ((ldr-reload-all? #t) (ldr-verbose? verbose?))
          (ldr-load+register real #f #f))
        (parameterize ((ldr-verbose? verbose?))
          (ldr-load+register real (and reload? #t) #f))))
  jolt-nil)
(def-var! "clojure.core" "require" loader-require)

(define (loader-use . specs0)
  (let* ((flags (ldr-flag-names specs0))
         (real (filter (lambda (s) (not (keyword? s))) specs0))
         (reload-all? (member "reload-all" flags))
         (reload? (and (not reload-all?) (member "reload" flags)))
         (verbose? (member "verbose" flags)))
    (if reload-all?
        (parameterize ((ldr-reload-all? #t) (ldr-verbose? verbose?))
          (ldr-load+register real #f #t))
        (parameterize ((ldr-verbose? verbose?))
          (ldr-load+register real (and reload? #t) #t))))
  jolt-nil)
(def-var! "clojure.core" "use" loader-use)

(def-var! "clojure.core" "load-file" jolt-load-file)

;; The directory of a namespace's resource path: "clojure.tools.reader-test" ->
;; "clojure/tools" (drop the last segment of ns-name->rel). "" for a top-level ns.
(define (ns-rel-dir name)
  (let* ((r (ns-name->rel name)))
    (let loop ((k (fx- (string-length r) 1)))
      (cond ((fx<? k 0) "")
            ((char=? (string-ref r k) #\/) (substring r 0 k))
            (else (loop (fx- k 1)))))))

;; load: an arg starting with "/" is a root-relative resource path ("/app/extra");
;; otherwise it is resolved against the CURRENT namespace's directory, matching
;; Clojure — (load "common_tests") from clojure.tools.reader-test loads
;; clojure/tools/common_tests.clj. Strip the leading slash / try each of
;; ldr-source-exts.
(define (jolt-load . paths)
  (for-each
    (lambda (p)
      (let* ((rel (cond
                    ((and (> (string-length p) 0) (char=? (string-ref p 0) #\/))
                     (substring p 1 (string-length p)))
                    (else (let ((dir (ns-rel-dir (chez-current-ns))))
                            (if (string=? dir "") p (string-append dir "/" p))))))
             (f (resolve-on-roots rel)))
        (if f (load-jolt-file f)
            (throw-jvm (quote java.io.FileNotFoundException) (string-append "Could not locate resource on source roots: " p)))))
    paths)
  jolt-nil)
(def-var! "clojure.core" "load" jolt-load)

;; --- shell primitive (jolt.host/sh, sh-out) ---------------------------------
;; `sh` runs `sh -c CMD`, inheriting stdout/stderr (so git progress shows), and
;; returns the exit code. `sh-out` captures stdout to a string (exit ignored) for
;; commands whose output we parse (git rev-parse). Used by jolt.deps for git.
(define (jolt-sh cmd) (system cmd))
(def-var! "jolt.host" "sh" jolt-sh)

(define (jolt-sh-out cmd)
  (call-with-values
    (lambda () (sa-run-process (string-append "exec sh -c " (sh-quote cmd))
                               (native-transcoder)))
    (lambda (stdin stdout stderr pid)
      (close-port stdin)
      (let ((out (get-string-all stdout)))
        (close-port stdout) (close-port stderr)
        (if (eof-object? out) "" out)))))
(define (sh-quote s)   ; single-quote for the outer sh -c
  (string-append "'"
    (apply string-append
      (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s)))
    "'"))
(def-var! "jolt.host" "sh-out" jolt-sh-out)

;; Expose source-root control + ns loading to Clojure (jolt.main / jolt.deps).
(def-var! "jolt.host" "set-source-roots!"
  (lambda (roots) (set-source-roots! (seq->list roots)) jolt-nil))
(def-var! "jolt.host" "source-roots" (lambda () (list->cseq source-roots)))
(def-var! "jolt.host" "load-namespace" (lambda (n) (load-namespace n) jolt-nil))
(def-var! "jolt.host" "file-exists?" (lambda (p) (if (file-exists? p) #t #f)))
;; …and whether it is a DIRECTORY, which file-exists? also answers #t for. A bare
;; argv token is dispatched as a file to run before a :tasks lookup (main.clj's
;; run-file-arg?), so `jolt test` in any project with a test/ dir — which is every
;; jolt library — took the file path and died decoding a directory.
(def-var! "jolt.host" "directory?" (lambda (p) (if (file-directory? p) #t #f)))
(def-var! "jolt.host" "getenv" (lambda (n) (let ((v (getenv n))) (if v v jolt-nil))))

;; jolt version string — one source (jolt-version-string, rt.ss): the baked
;; release tag in a binary, $JOLT_VERSION under bin/jolt, else "dev".
(def-var! "jolt.host" "jolt-version" (lambda () (jolt-version-string)))
