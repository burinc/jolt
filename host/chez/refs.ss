;; refs.ss — Clojure refs and STM for the Chez host.
;;
;; Multiversion concurrency with a global commit clock, the shape of the JVM's
;; LockingTransaction. A transaction reads the world as of its READ POINT (the
;; clock when it started) and buffers its writes in its own table. Its first write
;; to a ref CLAIMS the ref: a claim held by another live transaction makes this one
;; wait for that one and retry, unless this one is older and has run a while, in
;; which case it BARGES — kills the younger owner and takes the claim, so a long
;; transaction is not starved by short ones. ensure holds writers off the same
;; way. The commit computes its commutes and runs the validators with no lock
;; held, then checks and publishes under stm-mu, which no user code runs under:
;; nothing it wrote or ensured changed after its read point, every commuted ref is
;; still at the version its commutes were computed over, and the clock advances
;; after the refs are written. A read that finds no version at or before the read
;; point, a conflict or a kill throws the retry and the body runs again from the
;; start, up to the JVM's 10000 attempts.
;;
;; No lock is held while user code runs. A body, a commute fn or a validator may
;; block on another thread's transaction and a fiber may park in any of them;
;; none of it can deadlock or lose an update, because a waiter holds no lock and a
;; transaction waiting on a claim gives up its own claims first and waits a
;; bounded time.
;;
;; Watches fire once per changed ref after commit, outside stm-mu.
;; Refs participate in the IRef seam (watches/validators/metadata) like
;; atom/var/agent.  Loaded after atoms.ss (shares jolt-iref-state-throw and
;; the iref tables).

;; Refs travel in state images by VALUE (state-image.ss substitutes an
;; image-ref descriptor on dump and re-mints through make-jolt-ref on
;; restore), so this layout is NOT image-format surface and may change
;; freely. The uids jolt-ref-v1 and jolt-ref-v2 are RETIRED: format-2 images
;; carry refs as raw nongenerative jolt-ref-v1 records (fields: val lock), and
;; the legacy restore arm depends on materializing that rtd from the fasl
;; without a live conflict — never reuse a retired uid for a different layout.
;;
;;   tvals       — the committed history, newest first: a list of (point . val).
;;                 Never mutated, only replaced, so a reader that loads it holds a
;;                 consistent history without a lock.
;;   faults      — reads that found no version old enough since the last commit
;;                 that kept one more; a fault lets the next commit grow the history
;;   min-hist / max-hist — the history the ref keeps (ref-min-history)
;;   claim       — the transaction that wrote the ref and has not finished, or #f
;;   ensurers    — the transactions that ensured the ref and have not finished
;; claim and ensurers change only under stm-mu.
(define-record-type (jolt-ref %make-jolt-ref jolt-ref?)
  (fields (mutable tvals) (mutable faults) (mutable min-hist) (mutable max-hist)
          (mutable claim) (mutable ensurers))
  (nongenerative jolt-ref-v3))

(define (make-jolt-ref v) (%make-jolt-ref (list (cons 0 v)) 0 0 10 #f '()))
;; the newest committed value
(define (jolt-ref-val ref) (cdar (jolt-ref-tvals ref)))
;; A write outside any transaction (the loader's *loaded-libs* mark, an image
;; restore): the newest version takes the value and keeps its point.
(define (jolt-ref-val-set! ref v)
  (let ((tv (jolt-ref-tvals ref)))
    (let ((ntv (cons (cons (caar tv) v) (cdr tv))))
      (when jolt-mt? (memory-order-release))
      (jolt-ref-tvals-set! ref ntv))))

;; IRef arm: refs are watchable/validatable through the iref tables.
(register-iref-arm! jolt-ref?)

;; --- transaction record -------------------------------------------------------
;; A per-transaction record, held in the thread-parameter *txn* (#f when
;; no transaction is running). One record per attempt: a retry starts a new one.
;;   read-point    — the clock when the attempt started
;;   vals          — eq-hashtable: ref -> (in-txn value . set?), set? true once
;;                   ref-set / alter wrote it (a commuted ref's is #f)
;;   commutes      — alist: ref -> its commute fns, newest first, as (f . args)
;;   ensures       — list of the refs ensured
;;   pending-sends — thunks dispatching the agent sends made inside the txn
;;   status        — running, committing, killed (a barger took a claim), or done
;;   claims        — the refs this attempt claimed
;;   age           — (start . blocked-ms), one pair for the dosync's every attempt:
;;                   start is its first read point, so a lower start is older, and
;;                   blocked-ms is when it first found a younger owner in its way
;;   latch         — what transactions waiting on this one block on, made by the
;;                   first of them
;;   wait-on       — the transaction this attempt retries to wait for, or #f
;; status, claims, age and latch change only under stm-mu.
(define-record-type jolt-txn
  (fields read-point vals (mutable commutes) (mutable ensures) (mutable pending-sends)
          (mutable status) (mutable claims) (mutable age) (mutable latch) (mutable wait-on))
  (nongenerative jolt-txn-v2))

(define (make-txn rp age)
  (make-jolt-txn rp (make-eq-hashtable) '() '() '() 'running '() (or age (cons rp #f)) #f #f))

;; --- transaction state -------------------------------------------------------
;; stm-clock is the point of the last commit. Only a commit writes it, under
;; stm-mu, and it advances AFTER the commit's refs are written: a transaction
;; that reads point c then sees every ref commit c wrote.
;;
;; stm-mu guards claims, ensurers, statuses and the publish. It is held for
;; bookkeeping only — never across user code or a wait — so it is a leaf.
(define stm-clock 0)
(define stm-mu (make-mutex))
(define *txn* (make-thread-parameter #f))
(define stm-retry-limit 10000)
(define stm-barge-ms 10)        ; how long a transaction runs before it may barge
(define stm-wait-ms 100)        ; how long a blocked transaction waits before retrying
(define stm-again-limit 100)    ; commute recomputations before the commit retries

;; Waiting is the threaded host's: java/concurrency.ss installs a clock and a latch
;; made of a mutex and a jolt-cv. A host that runs one thread never contends, so
;; these defaults never wait.
(define stm-now-ms (lambda () 0))
(define stm-make-latch (lambda () #f))
(define stm-latch-wait (lambda (latch ms) (void)))
(define stm-latch-release! (lambda (latch) (void)))

;; (dyn-with-txn txn thunk) — scope *txn* over a dynamic extent.
;;
;; NOT `parameterize`, and the reason is the rule dyn-binding.ss already states at
;; dyn-with-frame: a winder must not re-establish state the jolt-dslice already
;; carries. The dslice carries *txn* — that is how a fiber parked inside a dosync
;; resumes inside its own transaction — and Chez's parameterize is a SWAP: one
;; thunk is both the wind's before and its after, exchanging the parameter with a
;; saved slot. jolt-fiber-slice-restore! writes *txn* BEFORE the rewind runs that
;; swap, so the saved slot would come back holding the transaction instead of the
;; outer nil, and the way out would then restore the TRANSACTION: the fiber's next
;; dosync would see (*txn*) non-nil, take the nested arm and join a dead
;; transaction whose log nobody commits.
;;
;; So the same shape dyn-with-frame uses, for the same reason. The set happens ONCE,
;; outside the wind, so a rewind cannot re-establish anything; and the after-thunk
;; restores an ABSOLUTE value rather than swapping, so it is right however many times
;; the extent is left and re-entered. The slice is then the single owner of *txn*
;; across a switch, which is what fibers.ss says the design is.
;;
;; The after-thunk DOES fire on a park: the slice owns *txn*, so letting it revert
;; and be restored is correct. That rests on a park being a CAPTURE park that
;; rewinds, which is what fn* opacity gives dosync (java/sm.ss's invariant;
;; run-gosm.ss checks it).
(define (dyn-with-txn txn thunk)
  (let ((outer (*txn*)))
    ;; masked at its edges (jolt-wind*, locks.ss): an interrupt's escape at either
    ;; left *txn* set, and the thread ran on as if inside the transaction
    (jolt-wind* (lambda () #f) (*txn* txn) thunk (*txn* outer))))

;; --- the retry ------------------------------------------------------------------
;; A clojure.lang.LockingTransaction$RetryEx, which is an Error on the JVM, so a
;; body's (catch Exception e) does not swallow it. One instance serves every retry,
;; made on first use under a mutex so every thread raises and recognizes the same one.
(define stm-retry-ex #f)
(define stm-retry-mu (make-mutex))
(define (stm-retry!)
  (unless stm-retry-ex
    (jolt-with-mutex stm-retry-mu
      (unless stm-retry-ex
        (set! stm-retry-ex (jolt-host-throwable "clojure.lang.LockingTransaction$RetryEx" jolt-nil)))))
  (jolt-throw stm-retry-ex))
(define (stm-retry? e)
  (and stm-retry-ex (eq? (jolt-unwrap-throw e) stm-retry-ex)))

;; --- in-txn reads and writes -------------------------------------------------

;; Sentinel for hashtable-ref to distinguish "not found" from a valid value.
(define txn-not-found (list 'txn-not-found))

(define (txn-live? t)
  (let ((st (jolt-txn-status t))) (or (eq? st 'running) (eq? st 'committing))))
;; a killed attempt retries at its next ref operation
(define (txn-check-running! txn)
  (unless (eq? (jolt-txn-status txn) 'running) (stm-retry!)))

;; The newest version at or before point rp, or txn-not-found.
(define (ref-val-at ref rp)
  (let loop ((tv (jolt-ref-tvals ref)))
    (cond ((null? tv) txn-not-found)
          ((<= (caar tv) rp) (cdar tv))
          (else (loop (cdr tv))))))

;; Read a ref inside a transaction: its in-txn value, else the version the read
;; point sees. No version that old is a fault, and the attempt retries.
(define (txn-get txn ref)
  (txn-check-running! txn)
  (let ((cell (hashtable-ref (jolt-txn-vals txn) ref #f)))
    (if cell
        (car cell)
        (let ((v (ref-val-at ref (jolt-txn-read-point txn))))
          (when (eq? v txn-not-found)
            (jolt-ref-faults-set! ref (+ 1 (jolt-ref-faults ref)))
            (stm-retry!))
          v))))

(define (txn-read ref)
  (let ((txn (*txn*)))
    (if txn (txn-get txn ref) (jolt-ref-val ref))))

;; --- claims, under stm-mu ------------------------------------------------------
;; The claim steps answer #t, 'retry, or the live transaction to wait for.

(define (changed-since? ref txn)
  (> (caar (jolt-ref-tvals ref)) (jolt-txn-read-point txn)))

;; Kill a running, younger owner once this transaction has been held up by
;; younger ones for stm-barge-ms.
(define (txn-barge!/locked txn other)
  (let ((mine (jolt-txn-age txn)))
    (and (< (car mine) (car (jolt-txn-age other)))
         (eq? (jolt-txn-status other) 'running)
         (let ((now (stm-now-ms)))
           (unless (cdr mine) (set-cdr! mine now))
           (> (- now (cdr mine)) stm-barge-ms))
         (begin
           (jolt-txn-status-set! other 'killed)
           (let ((l (jolt-txn-latch other))) (when l (stm-latch-release! l)))
           #t))))

;; another live transaction holding ref ensured, or #f
(define (ref-other-ensurer ref txn)
  (let loop ((es (jolt-ref-ensurers ref)))
    (cond ((null? es) #f)
          ((and (not (eq? (car es) txn)) (txn-live? (car es))) (car es))
          (else (loop (cdr es))))))

;; ref's owner when it is another live transaction txn cannot barge, or #f
(define (ref-blocking-owner ref txn)
  (let ((owner (jolt-ref-claim ref)))
    (and owner (not (eq? owner txn)) (txn-live? owner)
         (not (txn-barge!/locked txn owner))
         owner)))

(define (txn-claim!/locked txn ref)
  (cond
    ((not (eq? (jolt-txn-status txn) 'running)) 'retry)
    ((changed-since? ref txn) 'retry)
    (else
     (or (ref-blocking-owner ref txn)
         (ref-other-ensurer ref txn)
         (begin
           (jolt-ref-claim-set! ref txn)
           (jolt-txn-claims-set! txn (cons ref (jolt-txn-claims txn)))
           #t)))))

(define (txn-ensure!/locked txn ref)
  (cond
    ((not (eq? (jolt-txn-status txn) 'running)) 'retry)
    ((changed-since? ref txn) 'retry)
    (else
     (let ((owner (jolt-ref-claim ref)))
       (cond
         ((and owner (txn-live? owner)) (if (eq? owner txn) #t owner))
         (else
          (jolt-ref-ensurers-set! ref (cons txn (jolt-ref-ensurers ref)))
          (jolt-txn-ensures-set! txn (cons ref (jolt-txn-ensures txn)))
          #t))))))

;; Act on a claim step's answer, outside stm-mu. A transaction to wait for is
;; waited for once this attempt has let go of its own claims (jolt-sync).
(define (txn-blocked! txn r)
  (cond ((eq? r #t) #t)
        ((eq? r 'retry) (stm-retry!))
        (else (jolt-txn-wait-on-set! txn r) (stm-retry!))))

;; End an attempt: it is no longer live and its claims and ensures go. Answers
;; the latch to release once stm-mu is let go.
(define (txn-finish!/locked txn)
  (jolt-txn-status-set! txn 'done)
  (for-each (lambda (ref) (when (eq? (jolt-ref-claim ref) txn) (jolt-ref-claim-set! ref #f)))
            (jolt-txn-claims txn))
  (for-each (lambda (ref) (jolt-ref-ensurers-set! ref (remq txn (jolt-ref-ensurers ref))))
            (jolt-txn-ensures txn))
  (jolt-txn-latch txn))

(define (txn-release! txn)
  (when (or (pair? (jolt-txn-claims txn)) (pair? (jolt-txn-ensures txn)) (jolt-txn-latch txn))
    (let ((l (jolt-with-mutex stm-mu (txn-finish!/locked txn))))
      (when l (stm-latch-release! l)))))

;; Wait, a bounded time, for a transaction this one found in its way.
(define (txn-wait-for! owner)
  (let ((l (jolt-with-mutex stm-mu
             (and (txn-live? owner)
                  (or (jolt-txn-latch owner)
                      (let ((l (stm-make-latch)))
                        (jolt-txn-latch-set! owner l)
                        l))))))
    (when l (stm-latch-wait l stm-wait-ms))))

;; ref-set / alter: a commuted ref cannot be set; the first set claims the ref.
(define (txn-set! txn ref v)
  (when (and (pair? (jolt-txn-commutes txn)) (assq ref (jolt-txn-commutes txn)))
    (jolt-throw (jolt-host-throwable "java.lang.IllegalStateException" "Can't set after commute")))
  (txn-check-running! txn)
  (let ((cell (hashtable-ref (jolt-txn-vals txn) ref #f)))
    (if cell
        (set-car! cell v)
        (begin
          (txn-blocked! txn (jolt-with-mutex stm-mu (txn-claim!/locked txn ref)))
          (hashtable-set! (jolt-txn-vals txn) ref (cons v #t)))))
  v)

;; --- commit ---------------------------------------------------------------------

;; The history a commit leaves: one version more when the ref faulted and is
;; under its max, or is under its min; otherwise the oldest version goes.
(define (ref-next-tvals ref point v)
  (let ((tv (jolt-ref-tvals ref)))
    (if (and (null? (cdr tv)) (eqv? 0 (jolt-ref-faults ref)) (eqv? 0 (jolt-ref-min-hist ref)))
        (list (cons point v))
        (let* ((hcount (- (length tv) 1))
               (grow? (or (and (> (jolt-ref-faults ref) 0) (< hcount (jolt-ref-max-hist ref)))
                          (< hcount (jolt-ref-min-hist ref)))))
          (when grow? (jolt-ref-faults-set! ref 0))
          (cons (cons point v)
                (if grow? tv (let drop-last ((l tv)) (if (null? (cdr l)) '() (cons (car l) (drop-last (cdr l)))))))))))

;; The checks before a publish: 'retry when something written or ensured changed
;; after the read point, 'again when a commuted ref moved past the version its
;; commutes were computed over (seen), a transaction to wait for when another
;; holds a commuted ref, else #f.
(define (txn-commit-conflict/locked txn refs cells seen)
  (let ((n (vector-length refs)))
    (let loop ((i 0))
      (cond
        ((fx< i n)
         (if (and (cdr (vector-ref cells i)) (changed-since? (vector-ref refs i) txn))
             'retry
             (loop (fx+ i 1))))
        ((let eloop ((es (jolt-txn-ensures txn)))
           (cond ((null? es) #f)
                 ((changed-since? (car es) txn) #t)
                 (else (eloop (cdr es)))))
         'retry)
        (else
         (let cloop ((ss seen))
           (if (null? ss)
               #f
               (let ((ref (caar ss)))
                 (cond ((ref-blocking-owner ref txn) => values)
                       ((ref-other-ensurer ref txn) => values)
                       ((not (eq? (car (jolt-ref-tvals ref)) (cdar ss))) 'again)
                       (else (cloop (cdr ss))))))))))))

;; Under stm-mu, no user code: check, then publish. Answers (notes . latch) on
;; success, else what txn-commit-conflict/locked found.
(define (txn-publish!/locked txn refs cells seen)
  (cond
    ((not (eq? (jolt-txn-status txn) 'running)) 'retry)
    ((txn-commit-conflict/locked txn refs cells seen) => values)
    (else
     (jolt-txn-status-set! txn 'committing)
     (let* ((n (vector-length refs))
            (point (+ stm-clock 1))
            (notes (if (iref-any?)
                       (let loop ((i (fx- n 1)) (acc '()))
                         (if (fx< i 0)
                             acc
                             (loop (fx- i 1)
                                   (let ((ref (vector-ref refs i)))
                                     (cons (list ref (jolt-ref-val ref) (car (vector-ref cells i))) acc)))))
                       '()))
            (ntvs (make-vector n)))
       (do ((i 0 (fx+ i 1))) ((fx= i n))
         (vector-set! ntvs i (ref-next-tvals (vector-ref refs i) point (car (vector-ref cells i)))))
       (when jolt-mt? (memory-order-release))
       (do ((i 0 (fx+ i 1))) ((fx= i n))
         (jolt-ref-tvals-set! (vector-ref refs i) (vector-ref ntvs i)))
       (when jolt-mt? (memory-order-release))
       (set! stm-clock point)
       (cons notes (txn-finish!/locked txn))))))

;; Returns the (ref old new) notifications, or throws the retry.
(define (txn-commit! txn)
  (let-values (((refs cells) (hashtable-entries (jolt-txn-vals txn))))
    (let again ((k 0))
      ;; commutes over the newest values, then every validator: user code, so no
      ;; lock is held
      (let ((seen
             (let loop ((cs (jolt-txn-commutes txn)) (acc '()))
               (if (null? cs)
                   acc
                   (let* ((rc (car cs)) (ref (car rc))
                          (cell (hashtable-ref (jolt-txn-vals txn) ref #f)))
                     (if (cdr cell)
                         (loop (cdr cs) acc)
                         (let ((tv (car (jolt-ref-tvals ref))))
                           (set-car! cell
                             (let cf ((v (cdr tv)) (cfs (reverse (cdr rc))))
                               (if (null? cfs)
                                   v
                                   (cf (apply jolt-invoke (caar cfs) v (cdar cfs)) (cdr cfs)))))
                           (loop (cdr cs) (cons (cons ref tv) acc)))))))))
        (do ((i 0 (fx+ i 1))) ((fx= i (vector-length refs)))
          (iref-validate (vector-ref refs i) (car (vector-ref cells i))))
        (let ((r (jolt-with-mutex stm-mu (txn-publish!/locked txn refs cells seen))))
          (cond
            ((pair? r)
             (when (cdr r) (stm-latch-release! (cdr r)))
             (car r))
            ((and (eq? r 'again) (fx< k stm-again-limit)) (again (fx+ k 1)))
            ((eq? r 'again) (stm-retry!))
            (else (txn-blocked! txn r))))))))

(define (txn-writes? txn)
  (or (fx> (hashtable-size (jolt-txn-vals txn)) 0)
      (pair? (jolt-txn-ensures txn))))

;; --- constructor -------------------------------------------------------------
;; (ref init :validator f :meta m :min-history n :max-history n) — the ARef ctor
;; contract: validator runs against the initial value; :meta must be a map.
(define (jolt-ref-new v . opts)
  (let loop ((o opts) (validator jolt-nil) (m #f) (minh 0) (maxh 10))
    (cond
      ((or (null? o) (null? (cdr o)))
       (let ((r (make-jolt-ref v)))
         (jolt-ref-min-hist-set! r minh)
         (jolt-ref-max-hist-set! r maxh)
         ;; validate init via iref validator table
         (when (and (not (jolt-nil? validator)) (jolt-not (jolt-invoke validator v)))
           (jolt-iref-state-throw))
         (unless (jolt-nil? validator)
           (jolt-with-mutex iref-tbl-mu
             (iref-tbl-bump!)
             (hashtable-set! iref-validator-tbl r validator)))
         (when (and m (not (jolt-nil? m)))
           (unless (jolt-map? m)
             (jolt-throw (jolt-host-throwable
                          "java.lang.ClassCastException"
                          (string-append "class " (jolt-class-name m)
                                         " cannot be cast to class clojure.lang.IPersistentMap"))))
           (meta-table-set! r m))
         r))
      ((keyword-t? (car o))
       (let ((k (keyword-t-name (car o))))
         (cond ((string=? k "validator") (loop (cddr o) (cadr o) m minh maxh))
               ((string=? k "meta") (loop (cddr o) validator (cadr o) minh maxh))
               ((string=? k "min-history") (loop (cddr o) validator m (cadr o) maxh))
               ((string=? k "max-history") (loop (cddr o) validator m minh (cadr o)))
               (else (loop (cddr o) validator m minh maxh)))))
      (else (loop (cddr o) validator m minh maxh)))))

;; --- transaction-guarded operations ------------------------------------------
;; Inside a transaction, ref-set/alter/commute/ensure write through the
;; per-txn table; the commit validates and writes them. On exception the table
;; is discarded — rollback is implicit.

(define (jolt-ref-ensure-txn)
  (or (*txn*)
      (jolt-throw (jolt-host-throwable
                   "java.lang.IllegalStateException"
                   "No transaction running"))))

(define (jolt-ref-set ref v)
  (txn-set! (jolt-ref-ensure-txn) ref v))

(define (jolt-alter ref f . args)
  (let* ((txn (jolt-ref-ensure-txn))
         (v (apply jolt-invoke f (txn-get txn ref) args)))
    (txn-set! txn ref v)))

;; commute never conflicts: the in-txn value starts from the newest committed
;; one, and the commit applies the fns again to whatever is newest then.
(define (jolt-commute ref f . args)
  (let ((txn (jolt-ref-ensure-txn)))
    (txn-check-running! txn)
    (let* ((vals (jolt-txn-vals txn))
           (cell (or (hashtable-ref vals ref #f)
                     (let ((c (cons (jolt-ref-val ref) #f)))
                       (hashtable-set! vals ref c)
                       c)))
           (v (apply jolt-invoke f (car cell) args)))
      (let* ((cs (jolt-txn-commutes txn)) (rc (assq ref cs)))
        (if rc
            (set-cdr! rc (cons (cons f args) (cdr rc)))
            (jolt-txn-commutes-set! txn (cons (list ref (cons f args)) cs))))
      (set-car! cell v)
      v)))

;; ensure: holds other writers off the ref until this transaction finishes, as
;; the JVM's read lock does, and waits for a writer that already holds it.
(define (jolt-ensure ref)
  (let ((txn (jolt-ref-ensure-txn)))
    (txn-check-running! txn)
    (unless (memq ref (jolt-txn-ensures txn))
      (txn-blocked! txn (jolt-with-mutex stm-mu (txn-ensure!/locked txn ref))))
    (txn-get txn ref)))

;; __sync-call: run a thunk inside a transaction — the seam the sync/dosync
;; MACROS (30-macros.clj) expand through; sync itself is a macro with the
;; reference's (sync flags & body) shape. Nested calls join the outer
;; transaction (re-entrant through the thread-local parameter).
;;
;; The body is a thunk because dosync reaches here as (__sync-call (fn* [] body)) —
;; an fn*, which is opaque to the CPS pass, so a park inside a transaction takes a
;; CAPTURE park and rewinds properly through dyn-with-txn.
(define (jolt-sync thunk)
  (if (*txn*)
      ;; nested — just run the body under the existing transaction
      (jolt-invoke thunk)
      (let attempt ((n 0) (age #f))
        (when (fx= n stm-retry-limit)
          (jolt-throw (jolt-host-throwable "java.lang.RuntimeException"
                                           "Transaction failed after reaching retry limit")))
        (let ((rp stm-clock))
          (when jolt-mt? (memory-order-acquire))
          ;; outcome: (result . notifications), #f to retry, or #(raised)
          (let* ((txn (make-txn rp age))
                 (outcome
                  (guard (e (#t (if (stm-retry? e) #f (vector e))))
                    (let ((result (dyn-with-txn txn (lambda () (jolt-invoke thunk)))))
                      (cons result (if (txn-writes? txn) (txn-commit! txn) '()))))))
            ;; a commit lets go of its claims itself; any other end lets go here
            (unless (pair? outcome) (txn-release! txn))
            (cond
              ((not outcome)
               (let ((w (jolt-txn-wait-on txn))) (when w (txn-wait-for! w)))
               (attempt (fx+ n 1) (jolt-txn-age txn)))
              ((vector? outcome) (raise (vector-ref outcome 0)))
              (else
               ;; stm-mu is released and *txn* is back to #f
               (for-each (lambda (nt) (apply iref-notify nt)) (cdr outcome))
               (for-each (lambda (send) (send)) (reverse (jolt-txn-pending-sends txn)))
               (car outcome))))))))

;; io! is a MACRO (30-macros.clj): its body must NOT evaluate when the
;; transaction check throws. The macro tests this seam.
(define (jolt-txn-running?) (and (*txn*) #t))

;; --- history ops -------------------------------------------------------------
;; ref-history-count is how many versions besides the newest a ref keeps. A ref
;; keeps min-history of them at least, and grows toward max-history when a read
;; finds no version old enough (a fault).
;;
;; case-lambda rather than a rest-arg: a rest-arg accepted ANY arg count and
;; silently took the getter branch for 3+ (so (ref-min-history r 1 2) read the
;; value instead of raising), and (ref-min-history) died in `car` with a raw
;; host error that carried no class, so no catch clause could select it.
;; nil and a wrong type are different answers on the JVM, because the ^Ref hint
;; makes these an interface call: a null target is a NullPointerException, a
;; non-Ref is the cast failure. jolt-class-name itself raises on nil, so the nil
;; arm has to come first regardless.
(define (ref-history-arg-check ref)
  (cond
    ((jolt-ref? ref) #t)
    ((jolt-nil? ref)
     (throw-jvm (quote NullPointerException)
                "Cannot invoke \"clojure.lang.Ref\" method because \"ref\" is null"))
    (else
     (jolt-throw (jolt-host-throwable
                  "java.lang.ClassCastException"
                  (string-append "class " (jolt-class-name ref)
                                 " cannot be cast to class clojure.lang.Ref"))))))
(define (jolt-ref-history-count ref)
  (ref-history-arg-check ref)
  (- (length (jolt-ref-tvals ref)) 1))

(define (make-ref-history-op get set)
  (case-lambda
    ((ref)
     (ref-history-arg-check ref)
     (get ref))
    ((ref n)
     (ref-history-arg-check ref)
     (set ref n)
     ref)))
(define jolt-ref-min-history (make-ref-history-op jolt-ref-min-hist jolt-ref-min-hist-set!))
(define jolt-ref-max-history (make-ref-history-op jolt-ref-max-hist jolt-ref-max-hist-set!))

;; --- deref -------------------------------------------------------------------
;; Inside a transaction, the in-txn value or the version the read point sees.
;; Outside a transaction, the newest committed value.
(define (jolt-ref-deref ref)
  (txn-read ref))

;; Chain jolt-deref to handle refs (capture the pre-ref jolt-deref from atoms).
(define %pre-ref-deref jolt-deref)
(set! jolt-deref
  (lambda (x . opts)
    (if (jolt-ref? x)
        (jolt-ref-deref x)
        (apply %pre-ref-deref x opts))))

;; --- bind into clojure.core -------------------------------------------------
;; sync/dosync/io! are macros in the overlay (30-macros.clj) over the
;; __sync-call / __txn-running? seams.
(def-var! "clojure.core" "ref" jolt-ref-new)
(def-var! "clojure.core" "ref?" jolt-ref?)
(def-var! "clojure.core" "ref-set" jolt-ref-set)
(def-var! "clojure.core" "alter" jolt-alter)
(def-var! "clojure.core" "commute" jolt-commute)
(def-var! "clojure.core" "ensure" jolt-ensure)
(def-var! "clojure.core" "__sync-call" jolt-sync)
(def-var! "clojure.core" "__txn-running?" jolt-txn-running?)
(def-var! "clojure.core" "ref-history-count" jolt-ref-history-count)
;; ref-min-history / ref-max-history are multi-arity (getter / setter)
(def-var! "clojure.core" "ref-min-history" jolt-ref-min-history)
(def-var! "clojure.core" "ref-max-history" jolt-ref-max-history)
;; deref is already bound; the chain above extends jolt-deref, and
;; concurrency.ss will re-chain over us.

;; *loaded-libs* — seeded empty; loader.ss populates and wires it.
(def-dynvar! "clojure.core" "*loaded-libs*" (jolt-ref-new (jolt-hash-set)))
;; loaded-libs fn returns the derefed set.
(def-var! "clojure.core" "loaded-libs"
  (lambda () (jolt-deref (var-deref "clojure.core" "*loaded-libs*"))))
