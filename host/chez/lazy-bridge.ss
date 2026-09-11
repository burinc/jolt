;; lazy-seq bridge — make-lazy-seq / coll->cells.
;;
;; The `lazy-seq` macro (00-syntax.clj) expands to
;;   (make-lazy-seq (fn* [] (coll->cells (do body))))
;; and `lazy-cat` to (concat (lazy-seq c) ...). These back every overlay fn
;; built on lazy-seq — repeat / iterate / cycle / dedupe / take-nth / keep /
;; interpose / reductions / tree-seq (-> flatten) / lazy-cat.
;;
;; Bridge to the cseq model (seq.ss): a `jolt-lazyseq` is a deferred seq — a 0-arg
;; thunk that, when forced once, yields a seq (cseq | nil). coll->cells coerces the
;; body result to a seq (= jolt-seq), so the thunk already returns a seq; jolt-seq
;; is extended to force a lazyseq. The one trap: (cons x (a-lazy-seq)) must NOT
;; force the tail (else (repeat x) = (lazy-seq (cons x (repeat x))) loops forever),
;; so jolt-cons defers a lazyseq tail into a lazy cseq cell.
;;
;; Loaded LAST (after host-table.ss): %ls-seq then captures the fully-extended
;; jolt-seq (sorted-aware), so a lazy body returning a sorted coll still seqs.

(define-record-type jolt-lazyseq
  (fields (mutable thunk) (mutable val)
          (mutable realized? jolt-lazyseq-realized-flag jolt-lazyseq-realized-flag-set!)
          (mutable error? jolt-lazyseq-error-flag jolt-lazyseq-error-flag-set!)
          (mutable lock))
  (nongenerative jolt-lazyseq-v2))
;; The thunk field is the node's ONE published word, exactly as a cell's tail is
;; (seq.ss seq-tail-realized?): the thunk -- a procedure, or a lazy-src
;; descriptor -- until the node is forced, and after it the seq (cseq | jolt-nil)
;; or, for a body that threw, a lazyseq-fail carrying the condition. A reader
;; decides from that word alone and never locks. val, realized? and error? are
;; mirrors written before it, for the image (the layout is frozen, and a node
;; written by the two-field protocol arrives with thunk #f and its answer in
;; val/error?, which deliver below still reads).
(define-record-type lazyseq-fail (fields condition) (nongenerative jolt-lazyseq-fail-v1))
(define (lazyseq-pending? t) (or (procedure? t) (lazy-src? t)))
(define (jolt-lazyseq-realized? x) (not (lazyseq-pending? (jolt-lazyseq-thunk x))))
;; the lock field's position for the claiming CAS (seq.ss force-claimed!),
;; checked at load like cseq-lock-index
(define jolt-lazyseq-lock-index 4)
(let ((x (make-jolt-lazyseq 'th 'v #f #f #f)))
  (unless (and (sa-record-cas! x jolt-lazyseq-lock-index #f 'probe)
               (eq? (jolt-lazyseq-lock x) 'probe)
               (eq? (jolt-lazyseq-thunk x) 'th) (eq? (jolt-lazyseq-val x) 'v)
               (eq? (jolt-lazyseq-error-flag x) #f))
    (error 'lazy-bridge.ss "jolt-lazyseq-lock-index does not address the lock field")))

;; Thread-safety for lazy realization is only needed once a second OS thread can
;; touch a shared, not-yet-realized node. In single-threaded programs — all of ys
;; and the overwhelming majority of code — a lazy node needs no exclusion at all,
;; and because iterate/repeat/cycle and every map/filter chunk tail is a lazy
;; node, anything paid per node is paid per element of idiomatic seq pipelines.
;;
;; `jolt-mt?` starts #f and flips to #t the first time a real OS thread is spawned
;; (fork-thread is shadowed below). This is race-free: a single thread is either
;; forking or forcing, never both, so no node is being realized on the lock-free
;; path at the instant the flag turns on; and fork-thread establishes happens-
;; before, so the spawned child observes the flip. Once multi-threaded, a first
;; force claims the node by compare-and-swap for the duration (seq.ss
;; force-claimed!) and publishes behind a release fence; reads stay free.
(define jolt-mt? #f)
(define (jolt-mark-mt!) (set! jolt-mt? #t))

(define (jolt-make-lazy-seq thunk) (make-jolt-lazyseq thunk jolt-nil #f #f #f))
;; the descriptor form: a producer that records what it is instead of closing
;; over it, so the cell can be written to a state image (seq.ss lazy-src).
(define (jolt-make-lazy-src fn a b)
  (make-jolt-lazyseq (make-lazy-src fn a b) jolt-nil #f #f #f))

;; force once and memoize. The thunk is (fn [] (coll->cells body)); coll->cells
;; already coerced the body to a seq (cseq | nil) via the live jolt-seq, so the
;; result needs no further coercion (a nested lazyseq was forced by coll->cells).
;; A thrown failure is cached and re-raised on every later force, like the JVM (the
;; body runs exactly once; a failed force rethrows). The captured Chez condition is
;; re-raised verbatim, so a downstream catch unwraps the original jolt value.
;; The fast test names the two answers coll->cells can give; everything else --
;; a thunk, a fail record, an older image's #f -- is the slow path's to sort out.
(define (force-lazyseq x)
  (let ((t (jolt-lazyseq-thunk x)))
    (if (or (cseq? t) (jolt-nil? t)) t (force-lazyseq-slow x t))))
(define (force-lazyseq-slow x t)
  (define (deliver t)
    (cond ((lazyseq-fail? t) (raise (lazyseq-fail-condition t)))
          ((not t) (if (jolt-lazyseq-error-flag x)      ; a node from an older image
                       (raise (jolt-lazyseq-val x))
                       (jolt-lazyseq-val x)))
          (else t)))
  ;; mirrors first, then the word readers decide from -- behind a fence on the
  ;; multi-threaded path so the seq's own fields (and the fail record's, which is
  ;; why it is built up front) are visible before the word that points to them.
  (define (publish! v fail?)
    (let ((w (if fail? (make-lazyseq-fail v) v)))
      (jolt-lazyseq-val-set! x v)
      (jolt-lazyseq-error-flag-set! x fail?)
      (jolt-lazyseq-realized-flag-set! x #t)
      (when jolt-mt? (memory-order-release))
      (jolt-lazyseq-thunk-set! x w)))
  (define (run! t)
    (guard (e (#t (publish! e #t) (raise e)))
      ;; the thunk is a procedure (a user `lazy-seq` form's fn literal) or a
      ;; lazy-src descriptor (a clojure.core producer, recorded so the cell can
      ;; travel in a state image -- see seq.ss). Both force to a seq | nil.
      (let ((r (if (lazy-src? t) (lazy-src-force t) (jolt-invoke t))))
        (publish! r #f)
        r)))
  (cond
    ((not (lazyseq-pending? t)) (deliver t))
    ((not jolt-mt?) (run! t))
    (else
     (force-claimed! x jolt-lazyseq-lock jolt-lazyseq-lock-index jolt-lazyseq-thunk
       (lambda ()
         (let ((t (jolt-lazyseq-thunk x)))
           (if (lazyseq-pending? t) (run! t) (deliver t))))))))

;; Shadow fork-thread so any spawn (future/agent/core.async/process, all loaded
;; after this file) flips jolt-mt? on and joins the live-thread set. Captured in a
;; prior define so the RHS sees the primitive, not the top-level binding being
;; defined (Chez top-level letrec*).
;;
;; Chez exposes no list of running threads, so the shadow keeps one: a thread
;; enters the set as its body starts and leaves when the body returns. This backs
;; Thread/getAllStackTraces (io.ss), whose callers are leak checks counting
;; threads before and after some work.
;;
;; It is also where a new thread's per-thread state is reset. A Chez thread
;; parameter hands a forked thread the CREATING thread's value, and two of
;; jolt's are a read's transient state that must not travel: the reader's mode
;; switches (rdr-edn-mode, rdr-scan-mode, …, reader.ss) and the STM transaction
;; (*txn*, refs.ss). A go block forked from inside an edn :readers fn used to
;; read every later form on that thread in edn mode, for the life of the
;; thread. Every spawn site did its own reset and five of them (core.async's
;; go/thread/put!/take!/timeout, the subprocess pump, a future's completion
;; callback) had none; doing it here once is what makes the invariant hold for
;; the next spawn site too. A site that needs the parent's dynamic bindings
;; installs them itself, after this (dyn-binding-stack snap).
(define live-threads (make-eqv-hashtable))
(define live-threads-mutex (make-mutex))
(define (live-thread-ids)
  (jolt-with-mutex live-threads-mutex (vector->list (hashtable-keys live-threads))))
(define %ls-orig-fork-thread fork-thread)
(define (fork-thread thunk)
  (jolt-mark-mt!)
  (%ls-orig-fork-thread
   (lambda ()
     (*txn* #f)
     (rdr-default-modes!)
     (let ((id (get-thread-id)))
       (jolt-with-mutex live-threads-mutex (hashtable-set! live-threads id #t))
       (dynamic-wind
         (lambda () #f)
         thunk
         (lambda () (jolt-with-mutex live-threads-mutex (hashtable-delete! live-threads id))))))))

;; coll->cells: coerce the body result to the cell representation = a seq | nil.
(define (jolt-coll->cells c) (jolt-seq c))

;; extend jolt-seq to force a lazyseq (a lazyseq is seqable -> its realized seq).
(register-seq-arm! jolt-lazyseq? force-lazyseq)

;; (cons x lazyseq): keep the tail lazy — force it only when the cseq cell is
;; walked, so an infinite (repeat/iterate/cycle) stays productive.
(define %ls-cons jolt-cons)
;; the deferral is a descriptor, not a closure, so a cons onto a lazy seq can be
;; written to a state image -- (rest user-lazy) reaches this too, since a user
;; `lazy-seq` body is usually (cons x (recur ...)) (seq.ss lazy-src).
(define lz-cons-tail
  (register-lazy-src! 'cons-tail (lambda (coll _b) (force-lazyseq coll))))
(set! jolt-cons (lambda (x coll)
  (if (jolt-lazyseq? coll)
      (cseq-lazy x (make-lazy-src lz-cons-tail coll #f))
      (%ls-cons x coll))))

;; (conj lazyseq x): conj onto a seq prepends, like any seq — (conj (rest xs) y).
;; rest returns a lazyseq, so this is a common path; without it conj reports the
;; lazyseq as an "unsupported collection".
(register-conj-arm! jolt-lazyseq? (lambda (coll x) (jolt-cons x coll)))

;; A lazyseq is a NEW value type, so the dispatchers that DON'T route through
;; jolt-seq must learn it or a raw (unrealized) lazyseq escapes — e.g. the corpus
;; compares (= [1 3 5] (take-nth 2 …)) against the raw lazyseq, and jolt=2 would
;; see an unknown type and return false. Recognizing it as sequential is enough
;; for equality + hash (seq=? / seq-hash coerce via jolt-seq); count / empty? /
;; nth / the printers don't, so coerce those explicitly.
(define %ls-sequential? jolt-sequential?)
(set! jolt-sequential? (lambda (x) (or (jolt-lazyseq? x) (%ls-sequential? x))))
(register-count-arm! jolt-lazyseq?
  (lambda (x) (jolt-count (jolt-seq x))))
(register-empty-arm! jolt-lazyseq? (lambda (x) (jolt-empty? (jolt-seq x))))
(define %ls-nth jolt-nth)
(set! jolt-nth (case-lambda
  ((coll i)   (if (jolt-lazyseq? coll) (%ls-nth (jolt-seq coll) i)   (%ls-nth coll i)))
  ((coll i d) (if (jolt-lazyseq? coll) (%ls-nth (jolt-seq coll) i d) (%ls-nth coll i d)))))
;; a lazy seq prints as its realized seq — force, then re-dispatch through the
;; printer. An empty realized lazy seq is still a sequence, printing "()" (like a
;; JVM LazySeq), not "nil" — so (lazy-seq nil) and (rest '(1)) render "()".
(register-pr-str-arm! jolt-lazyseq?
  (lambda (x) (let ((s (jolt-seq x))) (if (jolt-nil? s) "()" (jolt-pr-str s)))))
(register-pr-readable-arm! jolt-lazyseq?
  (lambda (x) (let ((s (jolt-seq x))) (if (jolt-nil? s) "()" (jolt-pr-readable s)))))
(register-str-render! jolt-lazyseq?
  (lambda (x) (let ((s (jolt-seq x))) (if (jolt-nil? s) "()" (jolt-str-render-one s)))))

;; seq? — a lazy seq IS a seq (predicates.ss's jolt-seq? predates the lazyseq
;; record). Unlike the native-op dispatchers above (called via a direct top-level
;; reference, so the set! is enough), seq? is reached through var-deref, which
;; reads the var-cell root — so the patched closure must be re-def-var!'d, not just
;; set!. (Exposed once dynamic binding let with-in-str/line-seq reach seq?.)
(define %ls-seq? jolt-seq?)
(set! jolt-seq? (lambda (x) (or (jolt-lazyseq? x) (%ls-seq? x))))
(def-var! "clojure.core" "seq?" jolt-seq?)

(def-var! "clojure.core" "make-lazy-seq" jolt-make-lazy-seq)
(def-var! "clojure.core" "coll->cells" jolt-coll->cells)
