;; Jolt value model on Chez Scheme.
;;
;; The irreducible value layer the self-hosted RT rests on. Maps Clojure's value
;; types onto Chez natives where possible, and adds records only where Chez lacks
;; a distinct type (nil sentinel, keywords, ns-bearing symbols). Loaded into an
;; env that has already (import (chezscheme)).
;;
;; Design notes:
;; - nil is a UNIQUE sentinel, distinct from #f and '() (the classic Lisp-on-Lisp
;;   trap). jolt false -> Chez #f, jolt true -> #t.
;; - Chez's numeric tower IS Clojure's: long->exact integer, double->flonum,
;;   ratio->exact rational, bigint->bignum. Clojure `=` is exactness-aware:
;;   (= 1 1.0) is FALSE.

;; --- nil ---------------------------------------------------------------------
(define-record-type jolt-nil-t (fields) (nongenerative jolt-nil-v1))
(define jolt-nil (make-jolt-nil-t))
(define (jolt-nil? x) (jolt-nil-t? x))
(define (jolt-some? x) (not (jolt-nil-t? x)))

;; --- the exit-only-cleanup marker --------------------------------------------
;; A fiber park is a continuation escape that is NOT an exit — the computation
;; resumes where it left off. try/finally lowers to dynamic-wind, so its
;; after-thunk fires on that escape and would run the cleanup mid-operation: a
;; with-open closing a file that is still in use, a lock released while still
;; held.
;;
;; This procedure is the MARK that says so. The back end emits it as the `in`
;; thunk of every finally's dynamic-wind (backend_scheme.clj emit-try), and a
;; park drops exactly the winders whose `in` is eq? to it before escaping
;; (fibers.ss jolt-park-winders), so those after-thunks never run on a park.
;; The identity is the whole mechanism, so it must stay ONE shared top-level
;; procedure: a fresh (lambda () #f) per site would compare unequal and the
;; finally would run mid-park again.
;;
;; It has to be a marker and not a record-type test, because Chez tags every
;; dynamic-wind alike: with-mutex is a plain `winder` too, and loader.ss's
;; ldr-wait-for-load! deliberately relies on with-mutex releasing its lock on a
;; park and re-acquiring it on resume. Dropping winders by type would leave a
;; parked fiber holding the loader mutex.
;;
;; The body is never reached for its value — a finally has no before-thunk — so
;; #f is arbitrary.
(define jolt-finally-in (lambda () #f))

;; The older seam, still used by HOST dynamic-winds that want exit-only cleanup
;; but cannot use the marker because they need a real before-thunk of their own
;; (loader.ss load-namespace*). Emitted code no longer consults it. The Chez
;; fiber scheduler installs the real one (per-carrier, off a virtual register);
;; on a host with no fibers it stays #f. It must NOT be true for any escape
;; other than a park — an interrupt abort is a real exit and its cleanup has to
;; run.
(define jolt-park-unwinding?-hook (lambda () #f))
(define (jolt-park-unwinding?) (jolt-park-unwinding?-hook))

(define (jolt-truthy? x) (not (or (jolt-nil? x) (eq? x #f))))

;; --- keywords: interned so identity works; optional namespace ----------------
(define-record-type keyword-t (fields ns name khash) (nongenerative keyword-v1))
(define keyword-table (make-hashtable string-hash string=?))
;; The common no-ns keyword is interned in a table keyed by NAME directly, so a
;; lookup of an already-interned :kw (the hot case — every (:kw x), map literal,
;; keyword arg) is one hashtable-ref with NO allocation. The ns table keeps the
;; combined key. Both share the keyword-t khash (equal-hash of the combined key),
;; so hash values are unchanged.
(define keyword-table-bare (make-hashtable string-hash string=?))
;; NUL separator can't occur in a keyword ns/name, so the intern key is
;; unambiguous (a "/" separator would collide ns="a" name="b/c" with ns="a/b").
(define (keyword-intern-key ns name) (string-append (or ns "") "\x0;" name))
;; Interning has to be ATOMIC, and for a harder reason than the other side-tables
;; in the runtime: keyword equality IS identity (jolt=2-base answers keywords with
;; eq?, which is what makes (:k m) a pointer compare). Two threads racing the same
;; NEW name each got their own keyword-t, and from then on (= :foo :foo) was false
;; between them — with the hashes still agreeing, since khash is derived from
;; ns/name, so a map lookup found the right bucket and then failed the equality
;; check and answered nil. 8 threads interning 4000 fresh names split 64 of them,
;; and (get {:kw-0 42} :kw-0) across the split came back nil.
;;
;; Double-checked, exactly like rt.ss's jolt-var and for the same reasons. These
;; are STRONG hashtables, so an unlocked single-key read walks consistent
;; structure and the worst it can observe is a stale miss; the miss re-checks
;; under the lock. So the hot path — every keyword after the first — is the same
;; bare hashtable-ref it was, and only a first-ever intern pays the mutex.
;; The lock is a leaf: compute-keyword-hasheq is pure arithmetic.
(define keyword-table-mu (make-mutex))
(define (keyword ns name)
  (if ns
      (let ((k (keyword-intern-key ns name)))
        (or (hashtable-ref keyword-table k #f)
            (jolt-with-mutex keyword-table-mu
              (or (hashtable-ref keyword-table k #f)
                  (let ((kw (make-keyword-t ns name (compute-keyword-hasheq ns name))))
                    (hashtable-set! keyword-table k kw)
                    kw)))))
      (or (hashtable-ref keyword-table-bare name #f)
          (jolt-with-mutex keyword-table-mu
            (or (hashtable-ref keyword-table-bare name #f)
                (let ((kw (make-keyword-t #f name (compute-keyword-hasheq #f name))))
                  (hashtable-set! keyword-table-bare name kw)
                  kw))))))
(define (keyword? x) (keyword-t? x))

;; --- symbols: ns + name + meta; NOT interned (meta varies), = by ns/name ------
;; The ns/name STRINGS are pooled (like JVM Symbol.intern, which .intern()s them):
;; two separately-read `?a` symbols share one name-string object, so code that
;; compares symbol names by identity (core.logic's non-unique lvar equality, via
;; (str sym)) behaves like the JVM.
;; Same double-check as the keyword tables above. A lost update here is milder —
;; the pool is about STRING identity, and two objects for one name only means the
;; JVM-parity property this exists for stops holding for that name — but it is the
;; same unlocked check-then-set on the same kind of table, reached from every
;; thread that reads a symbol, and the miss path is just as cold.
;;
;;
;; The pool's VALUE is a 2-slot CELL — the canonical string plus a memo slot for
;; its murmur hash — rather than the string itself, and each symbol keeps a pointer
;; to its name's cell (symbol-t-ncell below). That is what makes a freshly built
;; symbol cheap to hash: the murmur over a given name happens once per process, not
;; once per symbol built from it. See symbol-t's comment for why per-object caching
;; alone left the hot shape slow.
;;
;; The memo slot is MUTABLE and starts #f, because hasheq.ss loads after this file
;; and there is no murmur to call while values.ss is still loading. symstr-mhash!
;; (hasheq.ss) is its only writer. Two threads racing compute the same value from
;; the same immutable string, so the loser's store is a no-op — the same benign-race
;; argument as khash below, and the reason the memo needs no lock while the
;; identity-conferring string slot does.
(define symbol-string-pool (make-hashtable string-hash string=?))
(define symbol-string-pool-mu (make-mutex))
(define (make-symstr s) (cons s #f))
(define (symstr-str c) (car c))
(define (symstr-mhash c) (cdr c))                   ; murmur3-hash-unencoded-chars
(define (symstr-mhash-set! c h) (set-cdr! c h))
;; Identity front cache over the pool probe. The pool is keyed by CONTENT
;; (string-hash + string=? per probe), but the hot caller hands over the SAME
;; string object every time: (symbol (name k)) — honeysql's format-dsl does it
;; 92 times per format call — reads the keyword's stored name string, and
;; keywords are interned, so that object is immortal and repeats forever. An
;; eq table turns those probes into a pointer lookup.
;;
;; PER-THREAD (a thread parameter), because a Chez hashtable does not survive
;; concurrent writers; each thread's cache converges on the same cells since
;; the pool underneath is the single source of truth — the values-test
;; cross-thread row pins that.
;;
;; BOUNDED and STRONG, cleared on overflow — deliberately NOT a weak table. A
;; weak entry per one-shot string is scanned by every collection, and a
;; fresh-name workload builds exactly that: the thread-safety gate's 16x40k
;; unique names put ~640k weak entries across the per-thread tables and the
;; GC ground to a halt (measured: the 120s gate at 59 CPU-minutes and
;; climbing). A strong table capped at 2048 entries pins at most 2048 short
;; strings per thread, and clear-on-overflow makes churn amortized O(1) with
;; nothing for the collector to scan. The hot population (keyword-name
;; objects, ~100 per workload) never reaches the cap.
;;
;; The per-thread slot is a VIRTUAL REGISTER, not a thread parameter: a forked
;; thread INHERITS a thread parameter's value, so workers would share the
;; creating thread's table object and corrupt it (vector-ref crash in the
;; thread-safety gate, section 9); a fresh thread starts every vreg at fixnum
;; 0, so each thread builds its own table — the same reason the hasheq caches
;; live in a vreg (hasheq.ss slot 5). Slot 8 is registered in rt.ss's slot
;; table.
(define symcell-front-cap 2048)
(define jolt-vreg-symcell-cache 8)
(define (intern-symbol-cell-slow s)
  (or (hashtable-ref symbol-string-pool s #f)
      (jolt-with-mutex symbol-string-pool-mu
        (or (hashtable-ref symbol-string-pool s #f)
            (let ((c (make-symstr s)))
              (hashtable-set! symbol-string-pool s c)
              c)))))
(define (intern-symbol-cell s)
  (let ((cache (let ((c (virtual-register jolt-vreg-symcell-cache)))
                 (if (eq? c 0)
                     (let ((t (make-eq-hashtable symcell-front-cap)))
                       (set-virtual-register! jolt-vreg-symcell-cache t)
                       t)
                     c))))
    (or (hashtable-ref cache s #f)
        (let ((c (intern-symbol-cell-slow s)))
          (when (fx>=? (hashtable-size cache) symcell-front-cap)
            (hashtable-clear! cache))
          (hashtable-set! cache s c)
          c))))
(define (intern-symbol-string s)
  (if (string? s) (symstr-str (intern-symbol-cell s)) s))
;; khash caches this symbol's hasheq, the way keyword-t-khash does for keywords,
;; and ncell is the NAME's pool cell — the same one the pool holds, kept here so
;; hashing this symbol never has to look the name up again.
;;
;; khash is MUTABLE and lazily filled (#f until first hashed) rather than computed
;; in the constructor: symbols are built during boot and by the reader, before
;; hasheq.ss is loaded at all, so there is no hash function to call here yet.
;; Filled by symbol-hasheq (hasheq.ss), which is the only writer. Filling it
;; eagerly instead was measured and was WORSE: it turns the load-order problem into
;; an indirect call through a hook that Chez cannot inline, and it charges every
;; symbol for a hash whether or not anything hashes it — (kw->sym k) x92 with the
;; symbols discarded got 12.1 -> 13.5 us. Lazy plus ncell beats both, because ncell
;; is what made the lazy path cheap (47 ns -> 10 ns).
;;
;; ncell is where the per-NAME memoization lives, and it is the point of this
;; whole arrangement. khash alone caches per SYMBOL OBJECT, which does nothing for
;; the shape that matters most — (get m (symbol (name k))), a symbol built for one
;; lookup and dropped — because each call gets a fresh object and re-murmurs a name
;; the process has already hashed thousands of times. The name STRING is the thing
;; that repeats, so that is what the hash hangs off.
;;
;; There is deliberately no cell for the ns. Its contribution is a
;; java-string-hashcode (14.7 ns, not the 45.8 ns murmur), it is paid once per
;; symbol object because khash then covers it, and unqualified symbols — the whole
;; hot population here — skip it entirely. A sixth field on every symbol in the
;; image is not worth that.
;;
;; Two threads hashing one shared symbol both compute the same value from the same
;; immutable ns/name and write it, so the race is benign — the same argument
;; keyword interning cannot make (where identity is the equality) and the reason
;; this can be a plain field instead of a lock. What it replaces is a per-thread
;; weak-eq hashtable keyed by the symbol object, which for the common
;; freshly-allocated-symbol-used-once pattern missed AND inserted on every single
;; lookup: (get m (symbol "x")) grew that table once per call.
(define-record-type symbol-t (fields ns name meta (mutable khash) ncell)
  (nongenerative symbol-v3))

(define (make-symbol-t/pooled ns name meta)
  (if (string? name)
      (let ((nc (intern-symbol-cell name)))
        (make-symbol-t (intern-symbol-string ns) (symstr-str nc) meta #f nc))
      ;; a non-string name cannot be pooled, so it has no cell and hashes the slow
      ;; way through compute-symbol-hasheq.
      (make-symbol-t (intern-symbol-string ns) name meta #f #f)))
(define (jolt-symbol ns name) (make-symbol-t/pooled ns name jolt-nil))
(define (jolt-symbol/meta ns name meta) (make-symbol-t/pooled ns name meta))

;; ns/name identical means the hasheq is identical, so a symbol rebuilt only to
;; change its metadata inherits the cache instead of recomputing it. with-meta on
;; a symbol used as a map key is otherwise a guaranteed miss.
(define (symbol-t-with-meta s m)
  (make-symbol-t (symbol-t-ns s) (symbol-t-name s) m
                 (symbol-t-khash s) (symbol-t-ncell s)))
(define (jolt-symbol? x) (symbol-t? x))

;; chars/strings: Chez natives (strings treated immutable).

;; --- fast-path invariant for the arm registries ------------------------------
;; jolt=2, jolt-hash and the printers all answer their commonest types before
;; walking their arms. The correctness condition is that NO registered arm may
;; claim one of those, or the fast path would silently skip it. That is enforced
;; here at registration rather than left to a comment, so a shim registering a
;; too-broad predicate fails loudly at the point of registration instead of
;; being quietly ignored at some later call.
;;
;; Each registry passes its OWN probes: the fast paths are not the same set, and
;; a guard wider than the fast path it protects would reject arms that are
;; perfectly legal. jolt-hash, for one, walks the arms for chars, symbols,
;; flonums and bignums, all of which the printer answers directly.
;; A probe whose type is not constructible yet, as a 0-or-1 element list to
;; splice in. Registries load in rt.ss order but so do the types they probe —
;; transients.ss registers a get arm before records.ss defines make-jrec — and a
;; probe that cannot be built is simply one this registration is not checked
;; against, which is strictly better than failing to boot.
(define (probe-if-available thunk)
  (guard (e (#t '())) (list (thunk))))

(define (reject-fast-type-claim! who claims? probes what)
  (for-each
   (lambda (probe)
     ;; A predicate that throws on an unexpected type is not claiming it.
     (when (guard (e (#t #f)) (and (claims? probe) #t))
       (error who
              (string-append
               "arm predicate matches a runtime-owned value type, which " what
               " answers without consulting the arms. Narrow the predicate to "
               "the type this arm actually owns.")
              probe)))
   probes))

;; --- jolt equality (Clojure =) — scalars + collections ----------------------
;; A host shim registers a type's equality via register-eq-arm! instead of
;; set!-wrapping jolt=2 (cf. register-hash-arm!). An arm is (pred . handler), both
;; (a b): the arm applies when pred holds (typically either arg is the type), and
;; handler returns the #t/#f result. Arms are checked before the base scalar/coll
;; cases; the entry is stable.
;;
;; The pairs a fast path answers without consulting the arms are subject to the
;; invariant: jolt=2's fixnum/flonum clauses, and pmap-fast-get's (collections.ss)
;; direct eq?/string=? compares on keyword and string keys — an arm claiming those
;; types would be silently skipped by map lookups (hash-fast-probes already guards
;; the same types for the jolt-hash fast path). jolt=2's third fast clause —
;; (eq? a b) on a non-number — legitimately short-circuits every type including
;; records, so the usual either-arg-is-my-type predicate stays legal even though
;; it matches those. Probes pair DISTINCT values so they land on the value
;; clauses rather than that identity one.
;; A thunk (like hash-fast-probes): (keyword …) needs compute-keyword-hasheq,
;; defined in hasheq.ss which loads after this file — the probes are evaluated
;; at registration time, when the whole runtime is loaded.
(define (eq-fast-probes)
  (list (cons 0 1) (cons 1.5 2.5)
        (cons (keyword #f "a") (keyword #f "b"))
        (cons (jolt-symbol #f "a") (jolt-symbol #f "b"))
        (cons "s1" "s2")
        ;; jolt's own collection types, now answered ahead of the walk. All
        ;; THREE that jolt=2 hoists must be probed — a hoisted type missing from
        ;; here is one whose arms register happily and are then silently dead.
        (cons (jolt-vector 1) (jolt-vector 2))
        (cons (jolt-hash-map (keyword #f "a") 1) (jolt-hash-map (keyword #f "a") 2))
        (cons (jolt-hash-set 1) (jolt-hash-set 2))
        ;; procedures: fn equality is identity, answered ahead of the walk (a
        ;; collision-bucket compare of fn-keyed map keys paid the whole arm
        ;; walk per entry) — so no arm may claim one.
        (cons car cdr)))
(define (eq-arm-reject-fast-type! who pred)
  (reject-fast-type-claim! who
                           (lambda (probe) (pred (car probe) (cdr probe)))
                           (eq-fast-probes)
                           "the jolt=2 / pmap-fast-get fast paths"))
(define jolt-eq-arms '())
(define (register-eq-arm! pred handler)
  (eq-arm-reject-fast-type! 'register-eq-arm! pred)
  (set! jolt-eq-arms (cons (cons pred handler) jolt-eq-arms)))
(define (jolt=2-base a b)
  (cond
    ((and (jolt-nil? a) (jolt-nil? b)) #t)
    ((or  (jolt-nil? a) (jolt-nil? b)) #f)
    ((and (number? a) (number? b))                 ; exactness-aware
     (and (eq? (exact? a) (exact? b)) (= a b)))
    ((and (keyword-t? a) (keyword-t? b)) (eq? a b)) ; interned
    ((and (symbol-t? a) (symbol-t? b))
     (and (equal? (symbol-t-ns a) (symbol-t-ns b))
          (string=? (symbol-t-name a) (symbol-t-name b))))
    ((and (char? a) (char? b)) (char=? a b))
    ((and (string? a) (string? b)) (string=? a b))
    ((and (boolean? a) (boolean? b)) (eq? a b))
    ;; Two jolt vectors take the chunked leaf-run compare in jolt-coll=? — it
    ;; walks both leaf arrays in lockstep instead of allocating a seq cell per
    ;; element. A pvec IS jolt-sequential?, so this MUST precede the sequential
    ;; arm below or it is unreachable and every vector compare pays the seq walk
    ;; (measured 5.1 us against 0.19 us on the JVM for two 20-element vectors).
    ((and (pvec? a) (pvec? b)) (jolt-coll=? a b))
    ;; sequential (vector / list / lazy seq) compare element-wise, cross-type:
    ;; (= [1 2 3] (list 1 2 3)) is true. Forward to seq.ss (loaded by rt.ss).
    ((and (jolt-sequential? a) (jolt-sequential? b)) (seq=? a b))
    ((or (jolt-sequential? a) (jolt-sequential? b)) #f)
    ;; other collections (map/set): forward to collections.ss.
    ((and (jolt-coll? a) (jolt-coll? b)) (jolt-coll=? a b))
    (else (eq? a b))))
;; The symbol clause is a FAST PATH, not just a hoist of jolt=2-base's own arm.
;; Symbols are the one scalar jolt allocates fresh on a hot lookup path — a
;; keyword-to-symbol conversion feeding (get m sym) — so every such compare used
;; to walk the whole jolt-eq-arms registry and then four cond clauses before
;; reaching the symbol arm, at 177 ns against 11 ns for the equivalent keyword.
;;
;; eq? first on each half, then string=?: intern-symbol-cell pools the ns and
;; name strings, so the eq? hits for any two symbols read or built through
;; jolt-symbol, which is the whole population in practice. The string=? is not a
;; formality. A symbol whose name is not a string never entered the pool at all
;; (see make-symbol-t/pooled), and a caller that reaches make-symbol-t directly
;; bypasses it too, so eq? alone would answer #f for two symbols that are equal.
;; So the fast case is a pointer compare and the correct case is still a compare
;; of the contents.
(define (jolt=2 a b)
  (cond ((and (fixnum? a) (fixnum? b)) (= a b))
        ((and (flonum? a) (flonum? b)) (= a b))
        ((and (eq? a b) (not (number? a))) #t)
        ;; Two keywords, and two strings, answer HERE rather than after the arm
        ;; walk. Both pairs are already in eq-fast-probes, so the registry REFUSES
        ;; an arm that would claim them (eq-arm-reject-fast-type!) — that guard is
        ;; what makes answering early safe, and it is the same reason pmap-fast-get
        ;; may compare keyword and string keys directly.
        ;;
        ;; Without these, only the EQUAL case was fast (the eq? clause above catches
        ;; two interned keywords, and jolt=2-base's own clauses sat behind the
        ;; walk). Every UNEQUAL keyword or string compare paid one predicate call
        ;; per registered arm — and the registry grows as libraries load, so the
        ;; cost is invisible on a bare runtime and grows with the program. It is
        ;; also the comparison a map lookup makes on a key miss, so it is on the
        ;; path of every get/assoc that does not hit. Measured on honeysql, whose
        ;; clause walk is all keyword compares: (= :abc :abd) 1.035 -> 0.130 us
        ;; once its own libraries had registered their arms.
        ((and (keyword-t? a) (keyword-t? b)) (eq? a b))  ; interned; eq? settled it above
        ((and (string? a) (string? b)) (string=? a b))
        ((and (symbol-t? a) (symbol-t? b))
         (let ((nsa (symbol-t-ns a)) (nsb (symbol-t-ns b))
               (na (symbol-t-name a)) (nb (symbol-t-name b)))
           (and (or (eq? nsa nsb)
                    (and (string? nsa) (string? nsb) (string=? nsa nsb)))
                (or (eq? na nb) (string=? na nb)))))
        ;; Jolt's OWN collection types answer here too, for the same reason the
        ;; keyword and string clauses do: a compare of two vectors or two maps
        ;; otherwise pays one predicate call per registered arm, and the registry
        ;; GROWS as libraries load. Loading jolt-lang/time (whose __register-eq!
        ;; arm predicate is a Clojure fn called through jolt-invoke) made
        ;; (= v20 v20) 44% slower and `hash` of a 2-entry map 8.4x slower, purely
        ;; from the walk. All three pairs are in eq-fast-probes, so the registry
        ;; REFUSES an arm claiming them — that guard is what makes answering here
        ;; safe, and values-test asserts each of the three separately so a probe
        ;; set losing one cannot go unnoticed. Narrow on purpose: only
        ;; pvec/pmap/pset, never jolt-map? (whose own arms let host types
        ;; masquerade as maps) and never records.
        ((and (pvec? a) (pvec? b)) (jolt-coll=? a b))
        ((and (pmap? a) (pmap? b)) (jolt-coll=? a b))
        ((and (pset? a) (pset? b)) (jolt-coll=? a b))
        ;; fn equality is identity (the eq? clause above already answered the
        ;; EQUAL case); answering the unequal case here keeps a fn-keyed map's
        ;; bucket scan off the arm walk. The pair is in eq-fast-probes.
        ((and (procedure? a) (procedure? b)) #f)
        (else (let loop ((as jolt-eq-arms))
                (cond ((null? as) (jolt=2-base a b)) 
                      (((caar as) a b) ((cdar as) a b)) 
                      (else (loop (cdr as))))))))
(define (jolt= a . rest)
  (let loop ((a a) (rest rest))
    (cond ((null? rest) #t)
          ((jolt=2 a (car rest)) (loop (car rest) (cdr rest)))
          (else #f))))

;; --- jolt hash — consistent with jolt= (for the HAMT) -----------------------
;; A host shim (records, host-table, inst-time, …) registers its type's hash via
;; register-hash-arm! instead of set!-wrapping jolt-hash — the arms are disjoint
;; types, checked before the base cases, so the full behavior is gathered here plus
;; the registry rather than scattered across a set! chain (cf. register-str-render!).
;; Narrower than the printer's set: only nil, keywords, symbols, fixnums and
;; strings are answered before the arm walk, so chars, flonums, bignums and ratios
;; all still reach the arms and an arm claiming one of those is legal.
;; Built on demand, not at load: interning a keyword needs hasheq.ss, which
;; rt.ss loads after this file. Every arm registers later still.
(define (hash-fast-probes)
  (list jolt-nil (keyword #f "k") (jolt-symbol #f "s") 0 "s"
        ;; as in eq-fast-probes: every type jolt-hash / jolt-hasheq answers
        ;; ahead of the walk, sets included. Procedures hash by identity
        ;; (procedure-hasheq, hasheq.ss) ahead of the walk too.
        (jolt-vector 1) (jolt-hash-map (keyword #f "k") 1) (jolt-hash-set 1)
        car))
(define (hash-arm-reject-fast-type! who pred)
  (reject-fast-type-claim! who pred (hash-fast-probes) "the jolt-hash fast path"))
(define jolt-hash-arms '())
(define (register-hash-arm! pred handler)
  (hash-arm-reject-fast-type! 'register-hash-arm! pred)
  (set! jolt-hash-arms (cons (cons pred handler) jolt-hash-arms)))
(define (jolt-hash-base x)
  ;; Delegate to jolt-hasheq for all scalars; sequential/coll handled by
  ;; seq-hash / jolt-coll-hash which now use the Murmur3 mixers from hasheq.ss.
  (cond
    ((jolt-sequential? x) (seq-hash x))
    ((jolt-coll? x) (jolt-coll-hash x))
    (else (jolt-hasheq x))))
(define (jolt-hash x)
  ;; Fast path for common types: skip the arm walk entirely.
  (cond ((jolt-nil? x) 0)
        ((keyword-t? x) (keyword-t-khash x))
        ((symbol-t? x) (jolt-hasheq x))
        ((fixnum? x) (jolt-hasheq x))
        ((string? x) (jolt-hasheq x))
        ;; identity hasheq (hasheq.ss loads later; resolved at call time), in
        ;; hash-fast-probes so no arm may claim a procedure.
        ((procedure? x) (jolt-hasheq x))
        ;; Collections answer before the walk for the same reason (see jolt=2).
        ;; This one is the worse of the two: a pmap already CACHES its hasheq, so
        ;; the arm walk was the entire cost of a repeat `hash` of a map, and it is
        ;; paid again per nested collection. Routing matches jolt-hash-base
        ;; exactly — a pvec is jolt-sequential?, and seq-hash and jolt-coll-hash's
        ;; pvec arm are both (hash-ordered (jolt-seq x)) — so hash VALUES are
        ;; unchanged and the HAMT keeps working.
        ((pvec? x) (seq-hash x))
        ((pmap? x) (jolt-coll-hash x))
        ((pset? x) (jolt-coll-hash x))
        (else (let loop ((as jolt-hash-arms))
                (cond ((null? as) (jolt-hash-base x))
                      (((caar as) x) ((cdar as) x))
                      (else (loop (cdr as))))))))
