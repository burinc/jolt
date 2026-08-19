;; State image round-trip regression. Run:
;;   chez --script test/chez/state-image-test.ss
;;
;; Pins the two things the image format rests on: that a jolt value graph
;; survives write -> read unchanged (including sharing, cycles and every numeric
;; type), and that everything Chez's fasl refuses is either encoded as data or
;; refused with the path to it. Also pins the Chez behaviour the design assumes,
;; so a Chez upgrade that changes fasl fails here rather than in someone's image.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
;; gate-boot's optimized profile compiles with generate-inspector-information off,
;; which suppresses the closure free-var info free-value recovery needs
;; ((io 'ref i) reports nothing); the release runtime has it ON, so turn it back
;; on here — only code compiled after this point (the fixture evals) is affected.
(generate-inspector-information #t)

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-final-str (jolt-compile-eval (string-append "(do " s ")") "user")))
(define (is name s expect)
  (let ((got (ev s)))
    (set! total (+ total 1))
    (unless (string=? got expect)
      (set! fails (+ fails 1))
      (printf "FAIL: ~a\n  expected: ~a\n  actual:   ~a\n" name expect got))))

;; Keyed by PID, the way aot-fingerprint-test.ss does it. (random 100000) is not
;; random across PROCESSES — Chez seeds its generator the same way every start,
;; so every run of this file picked the identical name and two concurrent runs
;; deleted each other's image ("image: no such file", from whichever lost).
(define tmp (string-append "/tmp/jolt-image-test-" (number->string (get-process-id)) ".jimg"))
(define refstub-tmp (string-append "/tmp/jolt-image-refstub-" (number->string (get-process-id)) ".txt"))
(define (cleanup!) (when (file-exists? tmp) (delete-file tmp)))

;; --- Chez substrate the format depends on ------------------------------------
;; If any of these change, the encoding assumptions change with them.
(define (fasl-bytes obj . pred)
  (call-with-bytevector-output-port
    (lambda (p) (if (null? pred) (fasl-write obj p) (fasl-write obj p (car pred))))))

(ok "data-only fasl is machine-independent (byte 12 = 0)"
    (fx=? 0 (bytevector-u8-ref (fasl-bytes (list 1 "two" 'three 4.0)) 12)))
(ok "records/cycles/bignums stay machine-independent"
    (and (fx=? 0 (bytevector-u8-ref (fasl-bytes (list (expt 2 200) -0.0 +nan.0 1/3)) 12))
         (fx=? 0 (bytevector-u8-ref (fasl-bytes (let ((v (vector 1))) (list v v))) 12))))
(ok "fasl-write refuses procedures"
    (call/cc (lambda (k) (with-exception-handler (lambda (e) (k #t))
                           (lambda () (fasl-bytes car) #f)))))
(ok "fasl-write refuses non-eq hashtables"
    (call/cc (lambda (k) (with-exception-handler (lambda (e) (k #t))
                           (lambda () (fasl-bytes (make-hashtable equal-hash equal?)) #f)))))
(ok "eq hashtables fasl fine"
    (let ((h (make-eq-hashtable)))
      (hashtable-set! h 'a 1)
      (not (not (fasl-bytes h)))))
(ok "externals vector length mismatch fails loudly"
    (call/cc (lambda (k) (with-exception-handler (lambda (e) (k #t))
                           (lambda ()
                             (fasl-read (open-bytevector-input-port (fasl-bytes (list car) procedure?))
                                        'load (vector))
                             #f)))))

;; --- value round-trip ---------------------------------------------------------
(define (roundtrip-expr expr)
  ;; write EXPR's value to the image, read it back, print it
  (cleanup!)
  (ev (string-append "(jolt.host/image-write! \"" tmp "\" " expr ")"))
  (ev (string-append "(pr-str (jolt.host/image-read \"" tmp "\"))")))

(define (rt name expr expect)
  (let ((got (roundtrip-expr expr)))
    (set! total (+ total 1))
    (unless (string=? got expect)
      (set! fails (+ fails 1))
      (printf "FAIL: round-trip ~a\n  expected: ~a\n  actual:   ~a\n" name expect got))))

(rt "vector"      "[1 2 3]"                        "[1 2 3]")
(rt "map"         "{:a 1 :b 2}"                    "{:a 1, :b 2}")
(rt "nested"      "{:xs [1 {:y #{3}}] :s \"hi\"}"  "{:xs [1 {:y #{3}}], :s \"hi\"}")
(rt "set"         "#{1 2 3}"                       "#{1 3 2}")
(rt "list"        "'(1 2 3)"                       "(1 2 3)")
(rt "keywords"    "[:a :b/c]"                      "[:a :b/c]")
(rt "symbols"     "'[a b/c]"                       "[a b/c]")
(rt "nil/bool"    "[nil true false]"               "[nil true false]")
(rt "strings"     "[\"a\" \"\"]"                   "[\"a\" \"\"]")
(rt "chars"       "[\\a \\newline]"                "[\\a \\newline]")
(rt "ratio"       "(/ 1 3)"                        "1/3")
(rt "bigint"      "(* 99999999999 99999999999)"    "9999999999800000000001N")
(rt "double"      "[1.5 -0.0]"                     "[1.5 -0.0]")
(rt "empty colls" "[[] {} #{} ()]"                 "[[] {} #{} ()]")
(rt "record"      "(do (defrecord P [x y]) (->P 1 2))" "#user.P{:x 1, :y 2}")

;; --- R4: sorted maps and sets travel -------------------------------------------
;; The wrapper's internal comparator machinery (a wrapped comparator closure + an
;; :ops table of closures in a string-keyed hashtable) never reaches the externals
;; path now: the transformer intercepts htable-sorted? and restores through the
;; public constructors with the ORIGINAL :cmp-fn.

(ev (string-append "(jolt.host/image-write! \"" tmp "\" (sorted-map :b 2 :a 1))"))
(is "natural sorted-map round-trips (order, lookups, count, sorted?, assoc)"
    (string-append "(let [m (jolt.host/image-read \"" tmp "\")]"
                   " (vector (keys m) (m :a) (m :b) (count m) (sorted? m) (keys (assoc m :c 3))))")
    "[(:a :b) 1 2 2 true (:a :b :c)]")

(ev (string-append "(jolt.host/image-write! \"" tmp "\" (sorted-set 5 3 8 1))"))
(is "natural sorted-set round-trips (order, lookup, count, sorted?, conj)"
    (string-append "(let [s (jolt.host/image-read \"" tmp "\")]"
                   " (vector (seq s) (s 3) (count s) (sorted? s) (seq (conj s 4))))")
    "[(1 3 5 8) 3 4 true (1 3 4 5 8)]")

(ev (string-append "(jolt.host/image-write! \"" tmp "\" (sorted-map-by > 1 :a 2 :b 3 :c))"))
;; fn-ref restores the VAR ROOT; a bare `>` reference compiles to the seq.ss
;; value-position singleton, which is a different (pre-existing) identity —
;; jolt-obtq tracks it — so the assertion derefs the var.
(is "named comparator (>) round-trips; cmp-fn IS clojure.core/>'s root"
    (string-append "(let [m (jolt.host/image-read \"" tmp "\")"
                   "       f (jolt.host/ref-get m :cmp-fn)]"
                   " (vector (keys m) (identical? f (deref (var clojure.core/>))) (sorted? m)))")
    "[(3 2 1) true true]")

(ev (string-append "(jolt.host/image-write! \"" tmp "\""
                   " (sorted-map-by (fn [a b] (compare (str a) (str b))) :b 2 :a 1))"))
(is "anon comparator round-trips; restored map sorts by it, new key lands in order"
    (string-append "(let [m (jolt.host/image-read \"" tmp "\")]"
                   " (vector (keys m) (keys (assoc m :c 3))))")
    "[(:a :b) (:a :b :c)]")

(ev (string-append "(jolt.host/image-write! \"" tmp "\" (atom [(sorted-map :b 2 :a 1)]))"))
(is "sorted-map nested in a vector inside an atom round-trips"
    (string-append "(let [m (first @(jolt.host/image-read \"" tmp "\"))]"
                   " (vector (keys m) (sorted? m)))")
    "[(:a :b) true]")

(ev (string-append "(jolt.host/image-write! \"" tmp "\" (with-meta (sorted-map :b 2 :a 1) {:m 1}))"))
(is "meta on a sorted map round-trips"
    (string-append "(:m (meta (jolt.host/image-read \"" tmp "\")))")
    "1")

(is "scan of a natural sorted map is empty"
    "(count (jolt.host/image-scan (sorted-map :b 2 :a 1)))"
    "0")

;; A collection HASHED before the dump must not carry that cache into the
;; image: procedure hasheq is identity-based and per-process (hasheq.ss), so a
;; restored fn hashes differently than the one the cache was computed over. A
;; stale cached hash made the restored vector compare UNEQUAL to an equal
;; vector rebuilt around the restored fn (the = fast-reject trusts cached
;; hashes), and their hashes disagreed. The dump walk zeroes hasheq caches, so
;; the restored side recomputes from what it actually holds.
(begin
  (cleanup!)
  (is "hashed fn-carrying vector: restored = rebuilt, hashes agree"
      (string-append
        "(let [f (fn [x] (+ x 1)) v [f :a]]"
        " (hash v)"
        " (jolt.host/image-write! \"" tmp "\" v)"
        " (let [v2 (jolt.host/image-read \"" tmp "\")"
        "       fresh [(nth v2 0) :a]]"
        "   (vector (= v2 fresh) (= (hash v2) (hash fresh)))))")
      "[true true]")
  (cleanup!)
  (is "hashed fn-carrying set: restored membership via rebuilt element"
      (string-append
        "(let [f (fn [x] x) s (hash-set [f :k])]"
        " (hash s)"
        " (jolt.host/image-write! \"" tmp "\" s)"
        " (let [s2 (jolt.host/image-read \"" tmp "\")"
        "       f2 (first (first s2))]"
        "   (vector (= (hash s2) (hash (hash-set [f2 :k]))) (= s2 (hash-set [f2 :k])))))")
      "[true true]"))

;; The zeroing mechanism itself, pinned at the Scheme level: the write walk
;; must drop a pre-armed hasheq cache from every collection it visits. The
;; in-process fixtures above cannot show the cross-process staleness (a
;; var-referenced fn restores to the SAME live object here), so pin the guard
;; directly: after image-write!, the graph's collections carry no cache.
(begin
  (cleanup!)
  (ok "write walk zeroes armed hasheq caches (vec/map/set)"
      (let* ((v (jolt-vector 1 2 3))
             (m (jolt-hash-map (keyword #f "a") v))
             (s (jolt-hash-set v)))
        (jolt-hasheq v) (jolt-hasheq m) (jolt-hasheq s)
        (and (not (fx=? 0 (pvec-hasheq v)))     ; armed before
             (begin
               ((var-deref "jolt.host" "image-write!") tmp (jolt-vector v m s))
               (and (fx=? 0 (pvec-hasheq v))
                    (fx=? 0 (pmap-hasheq m))
                    (fx=? 0 (pset-hasheq s)))))))
  (cleanup!))

;; fn-KEYED hash containers: their trie placement is computed from procedure
;; identity hasheqs, which are PER-PROCESS (hasheq.ss proc-hasheq-tbl) — a map
;; keyed by a var-referenced fn traveled raw, so a restoring process looked
;; keys up with ids the stored placement was never built from and silently got
;; nil. The in-process stand-in for "a different process": hand the fns fresh
;; ids between write and read, exactly what a new process's id counter does.
;; The fix substitutes an image-rekey record on the write side (the sorted-map
;; pattern) so restore REBUILDS the container with the restoring process's ids.
(begin
  (cleanup!)
  (ev (string-append "(jolt.host/image-write! \"" tmp "\""
                     " [(hash-map inc 1 dec 2 [inc :v] 3)"
                     "  (conj (hash-set) inc [dec :k])])"))
  (let ((bump (lambda (nm)
                (let ((p (var-deref "clojure.core" nm)))
                  (hashtable-set! proc-hasheq-tbl p
                                  (i32 (+ 424243 (procedure-hasheq p))))))))
    (bump "inc") (bump "dec"))
  (is "fn-keyed map+set look up after a fn-id change (cross-process stand-in)"
      (string-append "(let [r (jolt.host/image-read \"" tmp "\")"
                     "      m (nth r 0) s (nth r 1)]"
                     " [(get m inc) (get m dec) (get m [inc :v]) (count m)"
                     "  (contains? s inc) (contains? s [dec :k])])")
      "[1 2 3 3 true true]")
  (cleanup!))
;; (partial compare) would be compare ITSELF (partial's 1-arg arity), a named
;; fn — (comp - compare) is a real core-tier closure with no registration
(is "scan of a sorted-map-by with an unregistered closure reports one finding at the comparator"
    (string-append "(let [f (jolt.host/image-scan (sorted-map-by (comp - compare) :b 2 :a 1))]"
                   " (vector (count f) (boolean (re-find #\"cmp-fn\" (str (:path (first f)))))))")
    "[1 true]")

;; deep + wide, to catch anything that only shows up past the small-map cutoff
(is "large map round-trips"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" (zipmap (range 200) (range 200)))"
                   " (= (zipmap (range 200) (range 200)) (jolt.host/image-read \"" tmp "\")))")
    "true")
(is "large vector round-trips"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" (vec (range 5000)))"
                   " (= (vec (range 5000)) (jolt.host/image-read \"" tmp "\")))")
    "true")

;; RRB: a catvec result with a relaxed root dump/restore — the rrbnode record
;; is an image-format surface (chez-rrbnode-v1, raw-travel). The split is 63+65
;; deliberately: 64+64 rebalances to a fully classic trie (probed), so only a
;; misaligned seam actually produces the relaxed root this case exists to cover.
;; Uses jolt.host/catvec directly: the gate harness stops before loader.ss, so
;; a (require 'clojure.core.rrb-vector) is alias-only and cannot load the ns.
(is "relaxed-root RRB vector round-trips (element equality after restore)"
    (string-append "(let [c (jolt.host/catvec (vec (range 63)) (vec (range 63 128)))]"
                   " (jolt.host/image-write! \"" tmp "\" c)"
                   " (= c (jolt.host/image-read \"" tmp "\")))")
    "true")

;; metadata rides along
(is "metadata preserved"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" (with-meta [1] {:m 1}))"
                   " (:m (meta (jolt.host/image-read \"" tmp "\"))))")
    "1")

;; structural sharing: one object referenced twice stays one object
(is "sharing preserved"
    (string-append "(do (def shared {:a 1}) (jolt.host/image-write! \"" tmp "\" [shared shared])"
                   " (let [r (jolt.host/image-read \"" tmp "\")]"
                   " (identical? (first r) (second r))))")
    "true")

;; --- functions travel as var names --------------------------------------------
(is "named core fn round-trips and stays callable"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" {:f inc})"
                   " ((:f (jolt.host/image-read \"" tmp "\")) 41))")
    "42")
(is "user-defined fn round-trips"
    (string-append "(do (defn dbl [x] (* 2 x)) (jolt.host/image-write! \"" tmp "\" [dbl])"
                   " ((first (jolt.host/image-read \"" tmp "\")) 21))")
    "42")

;; a closure with no source registration to write -> refused, with the path to
;; it (a core-tier closure like partial's is never jfn$-registered)
(is "unregistered closure is refused"
    (string-append "(try (jolt.host/image-write! \"" tmp "\" {:handlers {:go (partial + 1)}}) :no-throw"
                   " (catch Exception e (if (re-find #\"cannot write\" (ex-message e)) :refused :wrong-error)))")
    ":refused")
(is "refusal names the path"
    (string-append "(try (jolt.host/image-write! \"" tmp "\" {:handlers {:go (partial + 1)}}) \"\""
                   " (catch Exception e (if (re-find #\":handlers\" (ex-message e)) :has-path :no-path)))")
    ":has-path")

;; --- scan reports without writing ----------------------------------------------
(is "scan is empty for pure data"
    "(count (jolt.host/image-scan {:a [1 2] :b #{3}}))" "0")
;; R2: a registered anon literal substitutes, so scan no longer flags it. The
;; fixture is a separate def: an inline literal's registration sibling runs after
;; the enclosing form's value is computed, so scan would see it unregistered.
(ev "(def scn {:f (fn [x] x)})")
(is "scan is empty for a registered anon fn"
    "(count (jolt.host/image-scan user/scn))" "0")
(is "scan reports an unregistered closure"
    "(count (jolt.host/image-scan {:p (partial + 1)}))" "1")
(is "scan reports a path"
    "(-> (jolt.host/image-scan {:outer {:p (partial + 1)}}) first :path string? )" "true")
(is "scan is empty for a named fn"
    "(count (jolt.host/image-scan {:f inc}))" "0")

;; --- R2: anonymous closures substitute as image-fnsrc records -------------------
;; Write-side only: dump! succeeds where it refused, and the records land in the
;; fasl body. R3 reconstructs them; here they come back inert, so the tests read
;; the file low-level (the way jolt-image-read does) and assert the fields.

(define (closure-name c)
  (guard (e (#t #f))
    (let* ((io (inspect/object c))
           (code (guard (e (#t #f)) (io 'code))))
      (and code (guard (e (#t #f)) (code 'name))))))

(define (image-body path)
  (let ((port (open-file-input-port path)))
    (let* ((h (fasl-read port))
           (descs (fasl-read port))
           (exts (list->vector (map image-decode-external descs)))
           (b (fasl-read port 'load exts)))
      (close-port port)
      b)))

(define (image-graph path) (vector-ref (image-body path) 0))

(define (find-fnsrcs root)
  (let ((acc '()))
    (image-walk root (lambda (x p) (when (image-fnsrc? x) (set! acc (cons x acc)))))
    (reverse acc)))

(define (jvec->strings v)
  (let loop ((s (jolt-seq v)) (acc '()))
    (if (jolt-nil? s)
        (reverse acc)
        (loop (seq-more s) (cons (seq-first s) acc)))))

;; the free-VALUE aligned to a registered free-name (matched by munged name), or
;; #f when the name isn't there
(define (fvs-by-name r nm)
  (let ((frees (jvec->strings (image-fnsrc-free-names r)))
        (fvs (image-fnsrc-free-values r)))
    (let ((i (let loop ((l frees) (j 0))
               (cond ((null? l) #f)
                     ((string=? (car l) nm) j)
                     (else (loop (cdr l) (+ j 1)))))))
      (and i (vector-ref fvs i)))))

;; a def whose init is an anon literal binds that literal directly (named by the
;; define), so the R2 cases bind the literal to a local first and store it inside
;; data, leaving it anonymous for the dump
(ev "(def img {:f (fn [x] (* x 2))})")
(is "anon fn in state dumps"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" user/img) :ok)")
    ":ok")
(let* ((g (image-graph tmp))
       (recs (find-fnsrcs g))
       (orig (jolt-get (var-deref "user" "img") (keyword #f "f") jolt-nil)))
  (ok "dump writes exactly one fnsrc record" (= 1 (length recs)))
  (ok "fnsrc name matches the live closure's inspector name"
      (string=? (image-fnsrc-name (car recs)) (closure-name orig)))
  (ok "fnsrc ns" (string=? (image-fnsrc-ns (car recs)) "user"))
  (ok "fnsrc free-names is an empty jolt vector"
      (and (pvec? (image-fnsrc-free-names (car recs)))
           (fx=? 0 (pvec-count (image-fnsrc-free-names (car recs))))))
  (ok "fnsrc form is the registered fn* form"
      (let* ((r (car recs))
             (reg (image-fn-form-lookup (image-fnsrc-name r))))
        (and reg (equal? (jolt-final-str (jolt-pr-readable (image-fnsrc-form r)))
                         (jolt-final-str (jolt-pr-readable (vector-ref reg 0))))))))

;; a closure shared through two slots writes ONE record; the read-back graph
;; shares it (memoized by identity)
(ev "(def shared (let [f (fn [x] (* x 2))] {:a f :b f}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/shared)"))
(let* ((g (image-graph tmp))
       (recs (find-fnsrcs g))
       (va (jolt-get g (keyword #f "a") jolt-nil))
       (vb (jolt-get g (keyword #f "b") jolt-nil)))
  (ok "shared closure writes one record" (= 1 (length recs)))
  (ok "shared closure is one shared record" (and (eq? va vb) (image-fnsrc? va))))

;; a capture cycle (closure -> atom -> closure) survives: the recovered free
;; value re-enters the transformer and finds the copy, not the live atom. The
;; closure rides inside a map (a def whose direct value is a closure would land
;; in proc-name-tbl and travel fn-ref instead).
(ev "(def cyc (let [a (atom nil)] (reset! a (fn [x] (deref a))) {:self a}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/cyc)"))
(let* ((g (image-graph tmp))
       (self (jolt-get g (keyword #f "self") jolt-nil))
       (rec (jolt-atom-val self)))
  (ok "cycle root is a map" (and (pmap? g) (jolt-atom? self)))
  (ok "cycle atom holds one fnsrc record" (image-fnsrc? rec))
  (ok "fnsrc free-value cycles back into the graph"
      (let ((fvs (image-fnsrc-free-values rec)))
        (and (vector? fvs)
             (fx=? 1 (vector-length fvs))
             (eq? (vector-ref fvs 0) self)))))

;; a keyword and a named fn captured as free values travel as themselves: the
;; keyword re-interns, the named fn goes fn-ref (not source). The closure rides
;; inside a map so the def's direct value isn't the closure (that would put it in
;; proc-name-tbl and it would travel fn-ref), and the captured values are runtime
;; (a deref) so the analyzer cannot fold them into the literal.
(ev "(def mix {:m (let [k (deref (atom :tag)) nf inc] (fn [x] [k nf x]))})")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/mix)"))
(let* ((g (image-graph tmp))
       (recs (find-fnsrcs g))
       (r (and (= 1 (length recs)) (car recs))))
  (ok "mix writes one fnsrc record" (= 1 (length recs)))
  (ok "mix free-values carry the keyword"
      (and r (eq? (fvs-by-name r "k") (keyword #f "tag"))))
  (ok "mix free-values carry the named fn via fn-ref"
      (and r (eq? (fvs-by-name r "nf") (var-deref "clojure.core" "inc")))))

;; a def whose DIRECT value is a closure lands in proc-name-tbl (var-set! names
;; it) and travels fn-ref with NO record — whether its literal folded to the
;; direct init (a let over constants) or not. Pins that fn-ref precedence.
(ev "(def fold (let [k :tag nf inc] (fn [x] [k nf x])))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/fold)"))
(let* ((g (image-graph tmp)))
  (ok "folded closure writes no fnsrc record" (null? (find-fnsrcs g)))
  (ok "folded closure travels fn-ref as the live fn"
      (eq? g (var-deref "user" "fold"))))

;; munge-name agreement: the write side munges registered free names with the
;; same mapping the emitter used, so a capture whose local needs munging is
;; still matched by name. Pin both sides, then end-to-end.
(define (jolt-backend-munge s)
  (jolt-invoke1 (var-deref "jolt.backend-scheme" "munge-name") s))
(define (jolt-host-munge s)
  (jolt-invoke1 (var-deref "jolt.host" "munge-name") s))
(ok "munge seam agrees with the backend emitter"
    (equal? (map jolt-host-munge '("x" "base" "hash#" "f'" "a$b" "if" "lambda" "jolt-x" "jv$x" "inc"))
            (map jolt-backend-munge '("x" "base" "hash#" "f'" "a$b" "if" "lambda" "jolt-x" "jv$x" "inc"))))
(ev "(def adv {:f (let [if (atom 3) hash# (atom 5)] (fn [x] (+ x (deref if) (deref hash#))))})")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/adv)"))
(let* ((g (image-graph tmp))
       (recs (find-fnsrcs g))
       (r (and (= 1 (length recs)) (car recs))))
  (ok "adversarial capture writes one fnsrc" (= 1 (length recs)))
  (ok "adversarial free-names keep original names"
      (and r
           (let ((l (jvec->strings (image-fnsrc-free-names r))))
             (and (member "if" l) (member "hash#" l)))))
  (ok "adversarial free-values matched by munged name"
      (and r
           (eqv? (jolt-atom-val (fvs-by-name r "if")) 3)
           (eqv? (jolt-atom-val (fvs-by-name r "hash#")) 5))))

;; the atom arm covers watches + validator (scan/dump parity): a registered anon
;; watch substitutes, an unregistered one is reported and refused
(ev "(def wa (atom 0))")
(ev "(add-watch user/wa :w (fn [k r o n] nil))")
(is "scan is empty for an atom with a registered anon watch"
    "(count (jolt.host/image-scan user/wa))" "0")
(is "dump succeeds with a registered anon watch"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" user/wa) :ok)")
    ":ok")
;; the watch list stores (key . fn) pairs; the walk substitutes each fn
(let* ((g (image-graph tmp))
       (ws (jolt-atom-watches g)))
  (ok "watch slot holds one fnsrc record"
      (and (pair? ws)
           (pair? (car ws))
           (image-fnsrc? (cdr (car ws)))
           (null? (cdr ws))))
  (ok "watch key preserved" (eq? (car (car ws)) (keyword #f "w"))))
(ev "(def wb (atom 0))")
(ev "(add-watch user/wb :w (partial + 1))")
(is "scan reports an unregistered watch"
    "(count (jolt.host/image-scan user/wb))" "1")
(is "dump refuses an unregistered watch"
    (string-append "(try (jolt.host/image-write! \"" tmp "\" user/wb) :no-throw"
                   " (catch Exception e (if (re-find #\"cannot write\" (ex-message e)) :refused :wrong-error)))")
    ":refused")

;; metadata rides to the substituted object: the write side copies the meta
;; table entry across the transform memo, so collect-meta keys the copy
(ev "(def mm (with-meta {:f (fn [x] x)} {:m 1}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/mm)"))
(let* ((b (image-body tmp))
       (g (vector-ref b 0))
       (meta-alist (vector-ref b 1)))
  (ok "the substituted map is a fresh object" (not (eq? g (var-deref "user" "mm"))))
  (ok "meta rides keyed by the substituted map"
      (let ((e (assq g meta-alist)))
        (and e (= 1 (jolt-get (cdr e) (keyword #f "m") jolt-nil))))))

;; handlers claim at any depth (not just var roots), procedures and resources
(ev "(jolt.host/image-register-handler! (fn [x] (and (map? x) (= (:res-id x) 7))) (fn [x] {:claimed (:res-id x)}) (fn [d] d))")
(ev "(def deep {:outer {:r {:res-id 7 :keep 1}}})")
(is "handler claims a resource at depth"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" user/deep) :ok)")
    ":ok")
(let* ((g (image-graph tmp))
       (handled '()))
  (image-walk g (lambda (x p) (when (image-handled? x) (set! handled (cons x handled)))))
  (ok "one image-handled record at depth" (= 1 (length handled)))
  (ok "handler payload rides in the body"
      (= 7 (jolt-get (image-handled-payload (car handled)) (keyword #f "claimed") jolt-nil))))


;; --- header / compatibility ------------------------------------------------------
(is "reading a non-image fails with a clear message"
    (string-append "(do (spit \"" tmp ".txt\" \"not an image\")"
                   " (try (jolt.host/image-read \"" tmp ".txt\") :no-throw"
                   " (catch Exception e :threw)))")
    ":threw")
(is "reading a missing file names the file"
    "(try (jolt.host/image-read \"/tmp/definitely-not-here.jimg\") :no-throw (catch Exception e (if (re-find #\"no such file\" (ex-message e)) :named :unnamed)))"
    ":named")
(is "runtime version is reported"
    "(string? (jolt.host/image-runtime-version))" "true")

;; --- interned-identity regression -----------------------------------------------
;; A fasl copy of a keyword is a key nothing can find: the map prints and counts
;; correctly while every lookup returns nil and = is false. That shape of bug is
;; invisible to a pr-str assertion, so it gets its own block.
(define (rt-expr expr) (string-append "(do (jolt.host/image-write! \"" tmp "\" " expr ")"
                                      " (jolt.host/image-read \"" tmp "\"))"))

(is "keyword lookup works after restore"     (string-append "(:m " (rt-expr "{:m 1 :n 2}") ")") "1")
(is "get works after restore"                (string-append "(get " (rt-expr "{:m 1}") " :m)") "1")
(is "= holds after restore"                  (string-append "(= {:m 1 :n 2} " (rt-expr "{:m 1 :n 2}") ")") "true")
(is "keywords are re-interned (identical?)"  (string-append "(identical? :m (first (keys " (rt-expr "{:m 1}") ")))") "true")
(is "namespaced keywords re-intern"          (string-append "(identical? :a/b (first (keys " (rt-expr "{:a/b 1}") ")))") "true")
(is "nested keyword lookup"                  (string-append "(get-in " (rt-expr "{:a {:b {:c 7}}}") " [:a :b :c])") "7")
(is "keyword set membership"                 (string-append "(contains? " (rt-expr "#{:x :y}") " :x)") "true")
;; A lookup answers with the element the collection HOLDS, and its metadata rides
;; along, so the image has to carry the stored element and not just something equal
;; to it. The set's lookup value is separately addressable from its key — conj! of
;; an equal element splits the two — so the pset arms rebuild pair-wise; a walk that
;; folded elements alone would restore a set whose get and seq had been merged.
(is "a set's element keeps its metadata across a round trip"
    (string-append "(meta (get " (rt-expr "#{^{:a 1} [1 2]}") " [1 2]))") "{:a 1}")
(is "a map's stored key keeps its metadata across a round trip"
    (string-append "(meta (key (find " (rt-expr "(assoc {} ^{:a 1} [1 2] :v)") " [1 2])))") "{:a 1}")
(is "a set's conj! split survives a round trip"
    (string-append "(let [s " (rt-expr "(persistent! (-> (transient #{}) (conj! ^{:a 1} [1 2]) (conj! ^{:a 2} [1 2])))")
                   "] [(meta (first (seq s))) (meta (get s [1 2]))])") "[{:a 1} {:a 2}]")
(is "record field access after restore"
    (string-append "(do (defrecord Q [a b]) (:a " (rt-expr "(->Q 5 6)") "))") "5")
(is "record = after restore"
    (string-append "(do (defrecord R [a]) (= (->R 1) " (rt-expr "(->R 1)") "))") "true")
;; A record's INHERITED fields are part of its value. A jrec keeps its descriptor
;; and its extension map on the PARENT type, so a walk that reads only a record's
;; own fields both under-reports what a dump refuses and rebuilds the record with
;; the wrong arity — an atom in a record field failed the dump outright
;; ("incorrect number of arguments to #<procedure constructor>").
(is "a record field that needs substitution round-trips"
    (string-append
      "(do (defrecord Holder [a b])"
      "  (let [h (->Holder (atom 1) :x)"
      "        _ (jolt.host/image-write! \"" tmp "\" {:h h})"
      "        g (jolt.host/image-read \"" tmp "\")]"
      "    [(deref (:a (:h g))) (:b (:h g)) (record? (:h g))]))")
    "[1 :x true]")
;; the extension map rides on the parent too: an assoc'd key holding an atom is
;; reached only by walking the inherited fields
(is "an assoc'd record key holding an atom round-trips"
    (string-append
      "(do (defrecord Holder2 [a])"
      "  (let [h (assoc (->Holder2 1) :extra (atom 7))"
      "        _ (jolt.host/image-write! \"" tmp "\" {:h h})"
      "        g (jolt.host/image-read \"" tmp "\")]"
      "    [(:a (:h g)) (deref (:extra (:h g)))]))")
    "[1 7]")
;; the descriptor itself must NOT be walked, and so not copied: it is the type,
;; not the value, and every instance shares one — as they do live. Rebuilding
;; these two records (each holds an atom) must leave that sharing intact.
(ok "restored instances of one type share one descriptor"
    (let ((g (begin
               (ev (string-append
                     "(do (defrecord Holder3 [a])"
                     "  (jolt.host/image-write! \"" tmp "\""
                     "    [(->Holder3 (atom 1)) (->Holder3 (atom 2))]))"))
               (jolt-compile-eval (string-append "(jolt.host/image-read \"" tmp "\")") "user"))))
      (let ((a (jolt-nth g 0)) (b (jolt-nth g 1)))
        (and (jrec? a) (jrec? b) (eq? (jrec-desc a) (jrec-desc b))))))
;; symbols are not interned and compare by ns/name, so a copy must still work as a key
(is "symbol-keyed lookup works"              (string-append "(get " (rt-expr "{'a 1}") " 'a)") "1")
(is "string-keyed lookup works"              (string-append "(get " (rt-expr "{\"s\" 1}") " \"s\")") "1")
(is "integer-keyed lookup works"             (string-append "(get " (rt-expr "{7 1}") " 7)") "1")
(is "large keyword map keeps every lookup"
    (string-append "(let [m " (rt-expr "(zipmap (map #(keyword (str \"k\" %)) (range 300)) (range 300))")
                   "] (every? (fn [i] (= i (get m (keyword (str \"k\" i))))) (range 300)))")
    "true")
(is "keyword sharing collapses to one intern"
    (string-append "(let [m " (rt-expr "[{:k 1} {:k 2}]")
                   "] (identical? (first (keys (first m))) (first (keys (second m)))))")
    "true")

;; cycles: fasl handles them, so an atom pointing at itself must survive
(is "cyclic structure survives"
    (string-append "(do (def a (atom nil)) (reset! a {:self a})"
                   " (jolt.host/image-write! \"" tmp "\" @a)"
                   " (let [r (jolt.host/image-read \"" tmp "\")]"
                   " (identical? r (deref (:self r)))))")
    "true")


;; --- whole-world image -----------------------------------------------------------
;; The Smalltalk/CL shape: save the program, not one named value. Code is skipped
;; (the restoring build already has it), so only data moves.
(define world-tmp (string-append tmp ".world"))
(ev "(ns imgtest.app)")
(jolt-compile-eval "(def board {:tasks [{:id 1 :text \"a\"}] :filter :all})" "imgtest.app")
(jolt-compile-eval "(def counter 41)" "imgtest.app")
(jolt-compile-eval "(defn helper [x] (* 2 x))" "imgtest.app")

(is "world scan is clean for data-only namespaces"
    "(count (jolt.host/image-scan-world [\"imgtest.app\"]))" "0")
(ev (string-append "(jolt.host/image-dump-world! \"" world-tmp "\" [\"imgtest.app\"])"))
;; clobber the world
(jolt-compile-eval "(def board {:tasks [] :filter :done})" "imgtest.app")
(jolt-compile-eval "(def counter 0)" "imgtest.app")
(is "world restore reports how many vars it rebound"
    (string-append "(jolt.host/image-restore-world! \"" world-tmp "\")") "2")
(is "data vars come back"
    "(str (:filter imgtest.app/board) \" \" imgtest.app/counter)" ":all 41")
(is "restored data keeps working keyword lookup"
    "(count (:tasks imgtest.app/board))" "1")
(is "code vars are untouched by a restore"
    "(imgtest.app/helper 21)" "42")
(is "a value image is refused by restore-world!"
    (string-append "(do (jolt.host/image-write! \"" tmp "\" {:a 1})"
                   " (try (jolt.host/image-restore-world! \"" tmp "\") :no-throw"
                   " (catch Exception e (if (re-find #\"value image\" (ex-message e)) :named :other))))")
    ":named")
(is "a world image is refused by plain read"
    (string-append "(let [w (jolt.host/image-read \"" world-tmp "\")] (vector? w))") "false")
;; hooks fire in order around the operation
(jolt-compile-eval "(def hooklog (atom []))" "user")
(is "before-dump and after-restore hooks fire"
    (string-append "(do (jolt.host/image-add-before-dump-hook! (fn [] (swap! user/hooklog conj :before)))"
                   " (jolt.host/image-add-after-restore-hook! (fn [] (swap! user/hooklog conj :after)))"
                   " (jolt.host/image-dump-world! \"" world-tmp "\" [\"imgtest.app\"])"
                   " (jolt.host/image-restore-world! \"" world-tmp "\")"
                   " (pr-str @user/hooklog))")
    "[:before :after]")
;; a sorted-map var survives a world dump/restore
(ev "(ns imgtest.sorted)")
(jolt-compile-eval "(def sm (sorted-map :b 2 :a 1))" "imgtest.sorted")
(ev (string-append "(jolt.host/image-dump-world! \"" world-tmp "\" [\"imgtest.sorted\"])"))
(is "world dump/restore brings a sorted-map var back, sorted"
    (string-append "(do (jolt.host/image-restore-world! \"" world-tmp "\")"
                   " (let [m imgtest.sorted/sm] (vector (keys m) (sorted? m))))")
    "[(:a :b) true]")

(when (file-exists? world-tmp) (delete-file world-tmp))

;; --- R3: read side — restored closures are CALLED ---------------------------
;; The R2 write fixtures now get their round-trip halves: dump through the real
;; write path, read through jolt-image-read (the restore transform), and CALL.
;; Captures must be RUNTIME-computed: const-fold bakes a let-bound constant
;; into the code and the capture disappears from the closure — the folded
;; fixture below pins that refusal instead.
(ev "(def r3 {:f (fn [x] (* x 3))})")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/r3)"))
(is "restored anon fn is callable"
    (string-append "((:f (jolt.host/image-read \"" tmp "\")) 14)")
    "42")
(ev "(def r3cap (let [a (+ 2 (count [1 2 3]))] {:f (fn [x] (+ a x))}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/r3cap)"))
(is "a runtime-captured local round-trips and calls"
    (string-append "((:f (jolt.host/image-read \"" tmp "\")) 37)")
    "42")

;; keyword + named-fn capture: the keyword went through free-values in the
;; BODY, so re-interning must have applied; the named fn traveled fn-ref and
;; must resolve to the LIVE fn. These are the assertions most likely to catch
;; a bypass (a fasl keyword copy or a re-compiled core fn).
(ev "(def mix {:m (let [k (deref (atom :tag)) nf inc] (fn [x] [k nf x]))})")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/mix)"))
(is "restored closure returns the INTERNED keyword"
    (string-append "(let [r ((:m (jolt.host/image-read \"" tmp "\")) 0)]"
                   " (identical? (nth r 0) :tag))")
    "true")
(is "restored closure calls the LIVE named fn (fn-ref path)"
    (string-append "(let [r ((:m (jolt.host/image-read \"" tmp "\")) 41)]"
                   " (identical? (nth r 1) inc))")
    "true")

;; nested closures: the outer literal's src-form contains the inner one, and
;; the outer's free-name list carries every name the whole form needs, so the
;; restored outer returns a working inner closure.
(ev "(def r3nest (let [k (+ 1 (count [1 2]))] {:outer (fn [x m] (fn [y] (+ (* x y) k m)))}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/r3nest)"))
(is "nested closures round-trip; call both"
    (string-append "(let [g (jolt.host/image-read \"" tmp "\")"
                   " inner ((:outer g) 5 2)] (inner 3))")
    "20")

;; shared-capture identity: two closures over ONE atom; after restore the atom
;; each closure captured must BE the graph's own (:a g) — three-way eq — and
;; mutation through one closure must be visible through the other and through
;; the graph reference.
(define (closure-free-vals c)
  (let ((io (inspect/object c)))
    (let loop ((i 0) (acc '()))
      (if (fx>=? i (io 'length))
          (reverse acc)
          (let ((vo (io 'ref i)))
            (loop (fx+ i 1) (cons ((vo 'ref) 'value) acc)))))))
(ev "(def r3shared (let [a (atom 1)] {:f1 (fn [] (swap! a inc)) :f2 (fn [] (deref a)) :a a}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/r3shared)"))
(let* ((g (jolt-image-read tmp))
       (f1 (jolt-get g (keyword #f "f1") jolt-nil))
       (f2 (jolt-get g (keyword #f "f2") jolt-nil))
       (ga (jolt-get g (keyword #f "a") jolt-nil)))
  (ok "restored closures share one atom with the graph (three-way eq)"
      (and (procedure? f1) (procedure? f2)
           (let ((a1 (closure-free-vals f1)) (a2 (closure-free-vals f2)))
             (and (pair? a1) (pair? a2)
                  (eq? (car a1) ga) (eq? (car a2) ga)
                  (eq? (car a1) (car a2))))))
  (ok "swap through one restored closure is visible through the other and the graph"
      (let ((_ (jolt-invoke f1)))
        (and (= (jolt-atom-val ga) 2) (= (jolt-invoke f2) 2)))))

;; the R2 cycle fixture read back and CALLED: ((deref a)) returns the closure
;; itself, and the atom's val IS that closure after the call.
(ev "(def cyc (let [a (atom nil)] (reset! a (fn [x] (deref a))) {:self a}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/cyc)"))
(let* ((g (jolt-image-read tmp))
       (a (jolt-get g (keyword #f "self") jolt-nil))
       (cl (jolt-atom-val a)))
  ;; (deref a) yields the atom's VAL — the closure itself — so a restored
  ;; call returning the very closure being called is the cycle proof
  (ok "restored cycle closure calls and returns itself through its atom"
      (and (procedure? cl) (eq? (jolt-invoke cl 'x) cl)))
  (ok "restored cycle closure is still the atom's val after the call"
      (eq? (jolt-atom-val a) cl)))

;; folded capture: a let-bound CONSTANT is baked into the compiled code, so the
;; capture is unrecoverable at dump — refuse with a named, actionable message;
;; scan reports the same finding.
(ev "(def r3folded (let [a 5] {:f (fn [x] (+ a x))}))")
(is "folded capture refuses at dump naming the local"
    (string-append "(try (jolt.host/image-write! \"" tmp "\" user/r3folded) :no-throw"
                   " (catch Exception e (if (re-find #\"captured local 'a' was optimized\" (ex-message e))"
                   " :named :wrong)))")
    ":named")
(is "scan agrees the folded capture is unwritable"
    "(= 1 (count (jolt.host/image-scan user/r3folded)))"
    "true")

;; multi-arity + variadic literals round-trip and are callable at each arity.
(ev "(def r3arity (let [k (+ 2 (count [1 2 3]))] {:f (fn ([x] (* x k)) ([x y] (+ x y k))) :v (fn [x & xs] (+ x (count xs) k))}))")
(ev (string-append "(jolt.host/image-write! \"" tmp "\" user/r3arity)"))
(is "multi-arity restored closure is callable at each arity"
    (string-append "(let [g (jolt.host/image-read \"" tmp "\")]"
                   " (str ((:f g) 7) \"/\" ((:f g) 2 3)))")
    "35/10")
(is "variadic restored closure is callable"
    (string-append "((:v (jolt.host/image-read \"" tmp "\")) 5 9 9)")
    "12")

;; world restore with closures: a var whose root holds a closure-bearing map
;; travels; restore-world! rebuilds it into a live closure.
(jolt-compile-eval "(def r3app {:cb (let [a (+ 2 (count [1 2 3]))] (fn [x] (+ a x))) :n 1})" "r3.app")
(ev (string-append "(jolt.host/image-dump-world! \"" world-tmp "\" [\"r3.app\"])"))
(jolt-compile-eval "(def r3app {:cb :clobbered})" "r3.app")
(is "restore-world! rebuilds closures and reports the rebound count"
    (string-append "(let [n (jolt.host/image-restore-world! \"" world-tmp "\")]"
                   " (str n \"/\" ((:cb r3.app/r3app) 37) \"/\" (:n r3.app/r3app)))")
    "1/42/1")

;; error paths: a malformed record (free-values arity != free-names) refuses
;; with a named error.
(define (str-contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (<= (+ i m) n)
           (or (string=? (substring s i (+ i m)) sub)
               (loop (+ i 1)))))))
(let* ((fn-form (list->cseq (list (jolt-symbol #f "fn*")
                                  (apply jolt-vector (list (jolt-symbol #f "x")))
                                  (list->cseq (list (jolt-symbol #f "x"))))))
       (bad (make-image-fnsrc "jfn$r3$bad$0" fn-form "user"
                              (apply jolt-vector (list (jolt-symbol #f "x")))
                              (vector 1 2))))
  (ok "malformed fnsrc record refuses with a named error"
      (call/cc (lambda (k)
        (with-exception-handler
          (lambda (e)
            (k (str-contains? (condition->message-string e) "malformed fn source record")))
          (lambda () (image-graph-process bad 'restore #f) #f))))))

;; compiler-dropped build: the tree-shaken manifest drops the 'image +
;; 'compile-eval tags, so a runtime with only rt.ss has no compile seam. Probe
;; that condition in a subprocess (same build as this gate, minus the spine).
(let ((probe (string-append tmp ".noce-probe.ss"))
      (out   (string-append tmp ".noce-out.txt"))
      (chez-bin (or (getenv "JOLT_CHEZ") "chez")))
  (call-with-output-file probe
    (lambda (p)
      (put-string p "(import (chezscheme))\n")
      ;; every boot path loads the runtime adapter FIRST (rt.ss top-levels
      ;; call sa-* — scheme-adapter-runtime.ss header); this probe is a boot
      ;; path too.
      (put-string p "(load \"host/chez/scheme-adapter-runtime.ss\")\n")
      (put-string p "(load \"host/chez/rt.ss\")\n")
      (put-string p "(guard (e (#t (display (condition->message-string e)) (newline)))\n")
      (put-string p "  (image-eval-fnsrc (make-image-fnsrc \"jfn$r3$nce$0\" '() \"user\" '() (vector)) '()))\n"))
    'replace)
  (let* ((rc (system (string-append chez-bin " --script " probe " > " out " 2>&1")))
         (msg (read-file-string out)))
    (ok "compiler-dropped build refuses fnsrc restore, naming the fn"
        (and (fx=? rc 0)
             (str-contains? msg "no compiler")
             (str-contains? msg "jfn$r3$nce$0")))
    (delete-file probe)
    (delete-file out)))


;; --- R6: resource stubs ---------------------------------------------------------
;; dump! stays strict by default; {:unwritable :stub} substitutes an image-stub
;; for anything the encoder refuses. dump-world! stubs by default and reports.

(define stub-probe-file (string-append tmp ".stub-probe.txt"))
(define stub-port (open-file-output-port stub-probe-file (file-options no-fail)))

(ok "strict dump! still refuses a port"
    (call/cc (lambda (k)
      (with-exception-handler (lambda (e) (k #t))
        (lambda () (jolt-image-write! tmp (jolt-hash-map (jolt-keyword "log") stub-port)) #f)))))

;; stub mode: the port dumps as a stub, the write reports it, the read
;; brings back an inert record that prints and names its class
(let ((rep (jolt-image-write! tmp (jolt-hash-map (jolt-keyword "log") stub-port)
                              (jolt-hash-map (jolt-keyword "unwritable") (jolt-keyword "stub")))))
  (ok "stub-mode dump reports the stubbed port"
      (fx=? 1 (jolt-count (jolt-get rep (jolt-keyword "stubbed") jolt-nil)))))
(let* ((g (jolt-image-read tmp))
       (st (jolt-get g (jolt-keyword "log") jolt-nil)))
  (ok "stubbed port restores as an inert image-stub" (image-stub? st))
  (ok "stub prints as #image/stub{...}"
      (let ((r (jolt-pr-readable st)))
        (and (string? r) (fx>=? (string-length r) 12)
             (string=? (substring r 0 12) "#image/stub{"))))
  (ok "stub class is jolt.image.Stub" (string=? (jolt-class-name st) "jolt.image.Stub"))
  (ok "port stub extra carries direction + open state"
      (let ((ex (image-stub-extra st)))
        (and (eq? (jolt-get ex (jolt-keyword "direction") jolt-nil) (jolt-keyword "output"))
             (eq? (jolt-get ex (jolt-keyword "open") jolt-nil) #t)))))

;; a throwing describer never fails the dump
(jolt-image-register-stub-describer!
  (lambda (x) (and (hashtable? x) (not (image-eq-hashtable? x))))
  (lambda (x) (error 'describer "boom")))
(let ((rep (jolt-image-write! tmp (jolt-hash-map (jolt-keyword "tbl") (make-hashtable equal-hash equal?))
                              (jolt-hash-map (jolt-keyword "unwritable") (jolt-keyword "stub")))))
  (ok "throwing describer does not fail the dump"
      (fx=? 1 (jolt-count (jolt-get rep (jolt-keyword "stubbed") jolt-nil)))))

;; folded capture stubs in stub mode, naming the capture
(jolt-compile-eval "(def r6folded (let [a 5] {:f (fn [x] (+ a x))}))" "user")
(let ((rep (jolt-image-write! tmp (var-cell-root (jolt-var "user" "r6folded"))
                              (jolt-hash-map (jolt-keyword "unwritable") (jolt-keyword "stub")))))
  (ok "folded capture stubs in stub mode, description names the capture"
      (let* ((sv (jolt-get rep (jolt-keyword "stubbed") jolt-nil))
             (info (jolt-nth sv 0))
             (d (jolt-get info (jolt-keyword "description") jolt-nil)))
        (and (fx=? 1 (jolt-count sv)) (string? d)
             (str-contains? d "folded capture a")))))

;; scan dispositions: a port is :would-stub
(let ((f (jolt-image-scan (jolt-hash-map (jolt-keyword "log") stub-port))))
  (ok "scan reports a port as :would-stub"
      (and (fx=? 1 (jolt-count f))
           (eq? (jolt-get (jolt-nth f 0) (jolt-keyword "disposition") jolt-nil)
                (jolt-keyword "would-stub")))))

;; A var's meta is a FIELD of the cell, so fasl-write sees it and the walk has to
;; reach it. It did not, so a var carrying ^{:test (fn …)} — which is where deftest
;; puts a test body — scanned clean and then failed the dump on the same graph, at
;; <unknown>. Both halves are asserted: the scan finds it, and the path names it.
(jolt-compile-eval "(def r7metafn 41)" "r7.meta")
(let ((cell (jolt-var "r7.meta" "r7metafn")))
  (var-cell-meta-set! cell (jolt-hash-map (jolt-keyword "test") stub-port))
  (let ((f (jolt-image-scan cell)))
    (ok "scan reaches an unwritable object in a var's META"
        (and (fx=? 1 (jolt-count f))
             (str-contains? (jolt-get (jolt-nth f 0) (jolt-keyword "path") jolt-nil)
                            "#'r7.meta/r7metafn meta"))))
  (var-cell-meta-set! cell jolt-nil))
;; and the writable case still round-trips the meta through a rebuild
(jolt-compile-eval "(def ^{:doc \"d\" :my {:a [1 2]}} r7metaok 41)" "r7.meta")
(jolt-image-write! tmp (jolt-var "r7.meta" "r7metaok") jolt-nil)
(let ((c (jolt-image-read tmp)))
  (ok "a var cell's meta survives the image round trip"
      (and (var-cell? c)
           (equal? "d" (jolt-get (var-cell-meta c) (jolt-keyword "doc") jolt-nil))
           (fx=? 2 (jolt-count (jolt-get (jolt-get (var-cell-meta c) (jolt-keyword "my") jolt-nil)
                                         (jolt-keyword "a") jolt-nil))))))

;; world: stub by default, listed with its var, resolved in place
(jolt-compile-eval "(def cfg {:name \"app\" :log nil})" "r6.world")
(let ((cell (jolt-var "r6.world" "cfg")))
  (var-cell-root-set! cell
    (jolt-assoc (var-cell-root cell) (jolt-keyword "log") stub-port)))
(let ((rep (jolt-image-dump-world! world-tmp (jolt-vector "r6.world"))))
  (ok "dump-world! stubs by default and reports"
      (fx=? 1 (jolt-count (jolt-get rep (jolt-keyword "stubbed") jolt-nil)))))
(jolt-compile-eval "(def cfg :clobbered)" "r6.world")
(jolt-image-restore-world! world-tmp)
(let ((ss (jolt-image-stubs)))
  (ok "stubs lists the unresolved stub with its owning var"
      (and (fx=? 1 (jolt-count ss))
           (string=? (jolt-get (jolt-nth ss 0) (jolt-keyword "var") jolt-nil) "r6.world/cfg")))
  (let* ((id (jolt-get (jolt-nth ss 0) (jolt-keyword "id") jolt-nil))
         (cnt (jolt-image-resolve-stub! id "LIVE-AGAIN")))
    (ok "resolve-stub! replaces one slot" (fx=? 1 cnt))
    (ok "resolved value lands in the var's map"
        (equal? "LIVE-AGAIN"
                (jolt-get (var-cell-root (jolt-var "r6.world" "cfg"))
                          (jolt-keyword "log") jolt-nil)))
    (ok "stubs empties after resolve" (fx=? 0 (jolt-count (jolt-image-stubs))))))

;; a stub inside a REF's val resolves through the in-place substitution walk
;; (the walk previously passed refs through untouched — resolved stubs never
;; landed inside a ref)
(let ((sp (open-file-output-port refstub-tmp (file-options no-fail))))
  (jolt-compile-eval "(def holder nil)" "r11.world")
  (let ((cell (jolt-var "r11.world" "holder")))
    (var-cell-root-set! cell (jolt-ref-new sp)))
  (jolt-image-dump-world! tmp (jolt-vector "r11.world"))
  (jolt-compile-eval "(def holder :clobbered)" "r11.world")
  (jolt-image-restore-world! tmp)
  (let ((ss (jolt-image-stubs)))
    (ok "stub inside a ref's val is listed"
        (fx=? 1 (jolt-count ss)))
    (when (fx=? 1 (jolt-count ss))
      (let ((id (jolt-get (jolt-nth ss 0) (jolt-keyword "id") jolt-nil)))
        (ok "resolve-stub! replaces the slot inside the ref"
            (and (fx=? 1 (jolt-image-resolve-stub! id "PORT-AGAIN"))
                 (equal? "PORT-AGAIN"
                         (jolt-ref-val (var-cell-root (jolt-var "r11.world" "holder")))))))))
  (close-port sp)
  (delete-file refstub-tmp))

;; resolver pre-registered: the stub never materializes
;; kind strings match the STUBBED OBJECT's class (a port's, here), so a
;; catch-all predicate is the simplest fixture
(jolt-image-register-stub-resolver! (lambda (info) #t)
  (lambda (info) "RESOLVED-INLINE"))
(let ((cell (jolt-var "r6.world" "cfg")))
  (var-cell-root-set! cell
    (jolt-assoc (var-cell-root cell) (jolt-keyword "log") stub-port)))
(jolt-image-dump-world! world-tmp (jolt-vector "r6.world"))
(jolt-image-restore-world! world-tmp)
(ok "pre-registered resolver restores inline; stubs stays empty"
    (and (equal? "RESOLVED-INLINE"
                 (jolt-get (var-cell-root (jolt-var "r6.world" "cfg"))
                           (jolt-keyword "log") jolt-nil))
         (fx=? 0 (jolt-count (jolt-image-stubs)))))

(close-port stub-port)
(delete-file stub-probe-file)

;; --- cross-version restore: the LEGACY-FORMAT proof. A v0.6.5-made (format-2)
;; world image carries its ref as a raw nongenerative jolt-ref-v1 record; the
;; live type is jolt-ref-v2, so the v1 rtd materializes from the fasl and the
;; legacy restore arm re-mints a live ref from it. This fixture is permanent:
;; it is the only thing proving old ref-carrying images keep restoring.
(ok "v0.6.5 fixture present" (file-exists? "test/chez/fixtures/image-v0.6.5-ref-atom.image"))
(jolt-image-restore-world! "test/chez/fixtures/image-v0.6.5-ref-atom.image")
(is "v0.6.5 fixture: imgtest/plain" "imgtest/plain" "7")
(is "v0.6.5 fixture: imgtest/my-atom deref" "(deref imgtest/my-atom)" "42")
(is "v0.6.5 fixture: imgtest/my-ref deref" "(deref imgtest/my-ref)" "99")
;; the legacy-restored ref is a LIVE v2 ref, not an inert v1 record: STM works
(is "v0.6.5 fixture: legacy ref participates in dosync"
    "(do (dosync (ref-set imgtest/my-ref 100)) (deref imgtest/my-ref))" "100")

;; --- the same proof for RECORDS. A defrecord/deftype instance rides raw, and
;; its descriptor (jrdesc) rides inside it, so the descriptor's field list is
;; image-format surface exactly as the ref record's was: a released image
;; carrying one stops restoring the moment jrdesc gains or loses a field.
;; Fixture made by the real v0.6.8 binary; permanent, like the v0.6.5 one.
(ok "v0.6.8 record fixture present" (file-exists? "test/chez/fixtures/image-v0.6.8-record.image"))
(jolt-image-restore-world! "test/chez/fixtures/image-v0.6.8-record.image")
(is "v0.6.8 fixture: imgrec8/plain" "imgrec8/plain" "7")
(is "v0.6.8 fixture: a defrecord instance prints" "(pr-str imgrec8/box)" "#imgrec8.Box{:a 1, :b \"two\"}")
(is "v0.6.8 fixture: its fields read" "[(:a imgrec8/box) (:b imgrec8/box) (count imgrec8/box)]" "[1 two 2]")
(is "v0.6.8 fixture: a deftype instance prints" "(pr-str imgrec8/pt)" "#imgrec8.Pt{:x 3, :y 4}")

;; --- refs travel by value (format 3, jolt-867l.11): descriptor on dump,
;; re-mint on restore. Value, meta, shared identity, cycles, and STM liveness
;; all survive; the raw jolt-ref record never enters the fasl, so its layout
;; is no longer image-format surface.
(is "ref round-trip: value + meta + identity + cycle + dosync"
    (string-append
      "(let [r (ref 99 :meta {:tag :hot})"
      "      shared (ref [1 2])"
      "      cyc (ref nil)"
      "      _ (dosync (ref-set cyc {:self cyc}))"
      "      _ (jolt.host/image-write! \"" tmp "\" {:a r :b shared :c shared :cyc cyc})"
      "      g (jolt.host/image-read \"" tmp "\")]"
      "  [(deref (:a g)) (:tag (meta (:a g)))"
      "   (identical? (:b g) (:c g))"
      "   (identical? (:cyc g) (:self (deref (:cyc g))))"
      "   (do (dosync (ref-set (:a g) 100)) (deref (:a g)))])")
    "[99 :hot true true 100]")
;; format discipline: the new image writes header version 4 (3 added ref
;; descriptors, 4 added image-rekey), and its bytes carry the descriptor rtd,
;; never the live ref rtd
(define (bv-contains? bv s)
  (let* ((sb (string->utf8 s)) (m (bytevector-length sb)) (n (bytevector-length bv)))
    (let scan ((i 0))
      (cond ((fx>? (fx+ i m) n) #f)
            ((let cmp ((j 0))
               (or (fx=? j m)
                   (and (fx=? (bytevector-u8-ref bv (fx+ i j)) (bytevector-u8-ref sb j))
                        (cmp (fx+ j 1))))) #t)
            (else (scan (fx+ i 1)))))))
(ok "ref-carrying image is format 4 with no raw jolt-ref rtd"
    (let ((port (open-file-input-port tmp)))
      (let* ((h (fasl-read port))
             (rest (get-bytevector-all port)))
        (close-port port)
        (and (fx=? 4 (vector-ref h 1))
             (bv-contains? rest "image-ref")
             (not (bv-contains? rest "jolt-ref-v2"))))))
;; an unknown format version refuses with a clean error naming both versions
(let ((vport (open-file-output-port tmp (file-options no-fail))))
  (fasl-write (vector 'jolt-image 99 (jolt-image-runtime-version) (sa-host-tag)) vport)
  (close-port vport))
(ok "future format version refuses cleanly"
    (call/cc (lambda (k)
      (with-exception-handler (lambda (e) (k #t))
        (lambda () (jolt-image-read tmp) #f)))))

(cleanup!)
(when (file-exists? (string-append tmp ".txt")) (delete-file (string-append tmp ".txt")))

(printf "~a/~a state-image assertions passed\n" (- total fails) total)
(when (> fails 0) (exit 1))
