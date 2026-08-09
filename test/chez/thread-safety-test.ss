;; test/chez/thread-safety-test.ss — the runtime's shared side-tables under
;; concurrent access. Run: chez --script test/chez/thread-safety-test.ss
;; (wired into `make threadsafety`, which is part of `make ci`).
;;
;; WHY. A Chez hashtable is not thread-safe. Unsynchronized mutation corrupts its
;; internals and the damage surfaces later somewhere that names nothing:
;; `nonrecoverable invalid memory reference` faulting inside the collector, or a
;; hang. test/chez/thread-tables.clj covers the two tables found first (metadata
;; and the variadic fixed-arity registry) through a core.async pipeline sweep;
;; this file covers the ones found by auditing the rest, at host level where the
;; workload can be aimed directly at a single table.
;;
;; Scenario 1 is a REPRODUCER, not a smoke: with the hasheq caches shared instead
;; of per-thread it faults on 2 of 3 runs. Scenarios 2 and 3 assert properties
;; instead of hoping for a crash, because a synthetic hammer is usually vacuous —
;; the note at the top of thread-tables.clj is about two that were thrown away for
;; passing unfixed.

(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-secs)
  (let ((t (current-time 'time-monotonic)))
    (+ (time-second t) (/ (exact->inexact (time-nanosecond t)) 1e9))))

;; Run THUNK on n threads and wait for all of them, bounded. Returns #t if they
;; all finished — a hang is a failure, never an actual hang of the gate.
(define (run-threads n thunk secs what)
  (let ((done 0) (mu (make-mutex)))
    (let loop ((i 0))
      (when (fx<? i n)
        (fork-thread (lambda () (thunk i) (with-mutex mu (set! done (+ done 1)))))
        (loop (fx+ i 1))))
    (let ((deadline (+ (mono-secs) secs)))
      (let wait ()
        (cond ((= done n) #t)
              ((> (mono-secs) deadline)
               (set! fails (+ fails 1))
               (printf "  FAIL: ~a (~a/~a finished)\n" what done n)
               #f)
              (else (sleep (make-time 'time-duration 50000000 0)) (wait)))))))

(printf "== runtime side-tables under concurrent access ==\n")

;; --- 1. the hasheq caches ----------------------------------------------------
;; string-hasheq / symbol-hasheq cache their result, and write the cache on every
;; MISS from whatever thread is hashing — so a shared table is written
;; concurrently by every thread that puts a string or symbol in a map. The caches
;; are per THREAD (hasheq.ss, virtual register 5); with one shared table this
;; scenario faults inside the collector on most runs.
(printf "\n== 1. concurrent hashing of fresh strings and symbols ==\n")
(define hash-threads 16)
(define hash-per 40000)
(ok "1. every thread finished hashing"
    (run-threads hash-threads
                 (lambda (t)
                   (let loop ((i 0) (acc 0))
                     (if (fx=? i hash-per)
                         acc
                         (let* ((s (string-append "k-" (number->string t) "-" (number->string i)))
                                (sym (jolt-symbol #f (string-append "s-" (number->string t)
                                                                    "-" (number->string i)))))
                           (loop (fx+ i 1)
                                 (fx+ acc (fxand (string-hasheq s) 1)
                                      (fxand (symbol-hasheq sym) 1)))))))
                 120.0 "1. concurrent hashing"))
;; the caches must actually be distinct per thread — the property, not the crash
(define seen-caches '())
(define seen-mu (make-mutex))
(ok "1. each thread got its own cache pair"
    (and (run-threads 4 (lambda (t)
                          (string-hasheq (string-append "distinct" (number->string t)))
                          (with-mutex seen-mu
                            (set! seen-caches (cons (hasheq-caches) seen-caches))))
                      30.0 "1. cache identity")
         (= 4 (length seen-caches))
         ;; four threads, four distinct pairs
         (let loop ((l seen-caches))
           (cond ((null? l) #t)
                 ((memq (car l) (cdr l)) #f)
                 (else (loop (cdr l)))))))

;; --- 2. var interning --------------------------------------------------------
;; jolt-var interns: two threads racing the same NEW name must get the SAME cell,
;; or a def through one would be invisible through the other. The insert is
;; double-checked under a mutex; the hit path takes no lock. This assertion is
;; exact and does not depend on timing.
(printf "\n== 2. concurrent interning of one fresh var name ==\n")
(define intern-cells '())
(define intern-mu (make-mutex))
(ok "2. every thread interned"
    (run-threads 12
                 (lambda (t)
                   ;; hammer distinct names too, so the table resizes while the
                   ;; contended name is being interned
                   (let loop ((i 0))
                     (when (fx<? i 2000)
                       (jolt-var "race.ns" (string-append "filler-" (number->string t)
                                                          "-" (number->string i)))
                       (loop (fx+ i 1))))
                   (let ((c (jolt-var "race.ns" "contended")))
                     (with-mutex intern-mu (set! intern-cells (cons c intern-cells)))))
                 60.0 "2. concurrent interning"))
(ok "2. all twelve threads got the identical cell"
    (and (= 12 (length intern-cells))
         (let ((c0 (car intern-cells)))
           (let loop ((l (cdr intern-cells)))
             (cond ((null? l) #t)
                   ((eq? (car l) c0) (loop (cdr l)))
                   (else #f))))))
(ok "2. and it is the cell a later lookup finds"
    (eq? (car intern-cells) (var-cell-lookup "race.ns" "contended")))

;; --- 3. watches and validators ----------------------------------------------
;; add-watch / set-validator! on a VAR or REF write side-tables (an atom keeps its
;; own in the record), and def-var! reads them on every def. Writes are serialized
;; and the read side has a lock-free empty-table fast path.
(printf "\n== 3. concurrent add-watch while defs run ==\n")
(define watch-hits 0)
(define watch-mu (make-mutex))
(ok "3. watchers and definers all finished"
    (run-threads 8
                 (lambda (t)
                   (let loop ((i 0))
                     (when (fx<? i 400)
                       (let ((c (jolt-var "watch.ns" (string-append "v-" (number->string t)))))
                         (jolt-add-watch c (string-append "key-" (number->string i))
                                         (lambda (k r o n) (with-mutex watch-mu
                                                             (set! watch-hits (+ watch-hits 1)))))
                         (def-var! "watch.ns" (string-append "v-" (number->string t)) i)
                         (jolt-remove-watch c (string-append "key-" (number->string i))))
                       (loop (fx+ i 1)))))
                 60.0 "3. watch churn"))
(ok "3. the watches fired" (> watch-hits 0))

;; --- 4. the reader's weak side-tables ----------------------------------------
;; rdr-map-order records a map literal's SOURCE key order, written on every map
;; literal read and consulted by the analyzer. Two threads reading source at once
;; is ordinary (an nREPL session evaluating while the loader requires), and a
;; weak-eq table is the kind that CANNOT be read unlocked while another thread
;; writes it: Chez's eq adjust! relinks live cells in place with $set-tlc-next!
;; (s/library.ss) and the reader is unsafe primitive code, so a resize concurrent
;; with a lookup hangs or faults. Unguarded this scenario hangs rather than
;; failing, which is why run-threads is bounded.
(printf "\n== 4. concurrent map-literal reads (rdr-map-order) ==\n")
(define rdr-bad 0)
(define rdr-bad-mu (make-mutex))
(ok "4. every reader thread finished"
    (run-threads 12
                 (lambda (t)
                   (let loop ((i 0))
                     (when (fx<? i 3000)
                       ;; a fresh map each time, so every read is a cache MISS and
                       ;; writes the table — the shape that resizes it
                       (let* ((es (list (keyword #f (string-append "k" (number->string t)))
                                        i
                                        (keyword #f (string-append "j" (number->string i)))
                                        t))
                              (m (rdr-make-map es)))
                         (unless (equal? (rdr-map-order-ref m) es)
                           (with-mutex rdr-bad-mu (set! rdr-bad (+ rdr-bad 1)))))
                       (loop (fx+ i 1)))))
                 90.0 "4. concurrent map-literal reads"))
(ok "4. every map kept its own source order" (= rdr-bad 0))

;; --- 5. the deftype ctor -> tag table ----------------------------------------
;; Also weak-eq, but the opposite profile: read on multimethod dispatch and the
;; class-tag chain, written only at deftype/defrecord DEFINITION. A mutex would
;; sit on dispatch to protect a write that happens a few hundred times in a
;; process, so it is COPY-ON-WRITE instead — the writer copies under a lock and
;; swaps the box, and a reader unboxes once and walks a table nobody will mutate
;; again.
;;
;; No hammer here. A rare-writer table cannot be made to fault on demand, and a
;; synthetic one would pass unfixed (this scenario did, at 200 ctors and again at
;; 20000). What IS exact is the mechanism: a snapshot taken before a write must
;; still be the table it was. Revert the writer to mutating in place and the first
;; two checks fail immediately, with no timing involved.
(printf "\n== 5. the ctor-tag table is copy-on-write ==\n")
(define tag-ctor-a (lambda () 'a))
(define tag-ctor-b (lambda () 'b))
(deftype-ctor-tag-set! tag-ctor-a "t.A")
(define tag-snapshot (unbox chez-deftype-ctor-tag-box))
(define tag-snapshot-size (hashtable-size tag-snapshot))
(deftype-ctor-tag-set! tag-ctor-b "t.B")
(ok "5. a write swaps the box instead of mutating in place"
    (not (eq? tag-snapshot (unbox chez-deftype-ctor-tag-box))))
(ok "5. a reader's snapshot is unaffected by the write"
    (and (= tag-snapshot-size (hashtable-size tag-snapshot))
         (not (hashtable-ref tag-snapshot tag-ctor-b #f))))
(ok "5. the new table carries both entries"
    (and (equal? (deftype-ctor-tag tag-ctor-a) "t.A")
         (equal? (deftype-ctor-tag tag-ctor-b) "t.B")))
;; the copy has to stay WEAK, or every ctor ever defined would be pinned
(ok "5. the copy is still a weak table" (hashtable-weak? (unbox chez-deftype-ctor-tag-box)))
;; and concurrent readers must still see a consistent table while types register
(define tag-bad 0)
(define tag-bad-mu (make-mutex))
(define tag-n 4000)
(define tag-ctors
  (let loop ((i 0) (acc '()))
    (if (fx=? i tag-n) (list->vector (reverse acc)) (loop (fx+ i 1) (cons (lambda () i) acc)))))
(define (tag-want i) (string-append "t.T" (number->string i)))
(ok "5. definers and dispatchers all finished"
    (run-threads 9
                 (lambda (t)
                   (if (fx=? t 0)
                       (let loop ((i 0))
                         (when (fx<? i tag-n)
                           (deftype-ctor-tag-set! (vector-ref tag-ctors i) (tag-want i))
                           (loop (fx+ i 1))))
                       (let loop ((r 0))
                         (when (fx<? r 40)
                           (let inner ((i 0))
                             (when (fx<? i tag-n)
                               (let ((got (deftype-ctor-tag (vector-ref tag-ctors i))))
                                 (when (and got (not (string=? got (tag-want i))))
                                   (with-mutex tag-bad-mu (set! tag-bad (+ tag-bad 1)))))
                               (inner (fx+ i 1))))
                           (loop (fx+ r 1))))))
                 120.0 "5. ctor-tag churn"))
(ok "5. no read ever returned another type's tag" (= tag-bad 0))
(ok "5. every ctor is registered at the end"
    (let loop ((i 0))
      (cond ((fx=? i tag-n) #t)
            ((equal? (deftype-ctor-tag (vector-ref tag-ctors i)) (tag-want i)) (loop (fx+ i 1)))
            (else #f))))

;; --- 6. the multimethod tables ------------------------------------------------
;; defmethod writes the methods table and bumps a global epoch; dispatch reads it
;; and memoizes isa?-resolved values in a per-multifn cache that defmethod
;; invalidates with hashtable-clear!. All of it used to be unlocked. Two
;; properties, both of which failed before: every defmethod is still there at the
;; end (racing inserts drop entries), and the whole-table scan mm-find-isa does
;; never sees a FILL slot.
(printf "\n== 6. concurrent defmethod while dispatching ==\n")
(define mm-n 1500)
(define mm-sym (jolt-symbol "t6" "mm"))
(define mm-mf (jolt-defmulti-setup mm-sym (lambda (x) x)))
(define mm-err 0)
(define mm-err-mu (make-mutex))
;; A sentinel registered BEFORE the threads start, and never in a definer's key
;; range. mm-resolve finds it in the methods table directly and returns without
;; touching mm-find-isa — which matters because this gate loads rt.ss only, so
;; clojure.core's isa? is unbound and the isa? path would raise for reasons that
;; have nothing to do with what is under test. Resolving a key that a definer has
;; not written yet is exactly how that happened.
(define mm-sentinel -1)
(jolt-defmethod-setup mm-sym mm-sentinel (lambda (x) x))
(ok "6. definers and dispatchers all finished"
    (run-threads 8
                 (lambda (t)
                   (if (fx<? t 2)
                       ;; two definers, disjoint key ranges so neither overwrites
                       ;; the other's methods
                       (let loop ((i 0))
                         (when (fx<? i mm-n)
                           (jolt-defmethod-setup mm-sym (+ (* t mm-n) i) (lambda (x) x))
                           (loop (fx+ i 1))))
                       (let loop ((r 0))
                         (when (fx<? r 60)
                           (guard (e (#t (with-mutex mm-err-mu (set! mm-err (+ mm-err 1)))))
                             ;; the whole-table scan, concurrent with the inserts —
                             ;; unlocked this reads FILL slots and jolt-assoc gets
                             ;; a dispatch value of 0. (The isa? path is not driven
                             ;; here: this gate loads rt.ss only, so clojure.core's
                             ;; isa? / global-hierarchy are unbound. run-unit and
                             ;; the corpus cover isa? dispatch with the overlay up.)
                             (jolt-methods-setup mm-mf)
                             (mm-resolve mm-mf mm-sentinel))
                           (loop (fx+ r 1))))))
                 120.0 "6. defmethod churn"))
(ok "6. no dispatch raised" (= mm-err 0))
(ok "6. every defmethod survived"
    (let loop ((i 0) (missing 0))
      (if (fx=? i (* 2 mm-n))
          (= missing 0)
          (loop (fx+ i 1)
                (if (hashtable-ref (jolt-multifn-methods mm-mf) i #f) missing (+ missing 1))))))

;; --- 7. the protocol registry -------------------------------------------------
;; register-protocol-method builds type-registry's nested tables check-then-create
;; and bumps jolt-proto-epoch, and find-method-any-protocol walks
;; (hashtable-keys ti). The race is on a tag's FIRST registration — that is the
;; only moment two threads can both find no inner table and each make one, with
;; the second overwriting the first's protocol out of existence. So both definers
;; walk the SAME fresh tags in lockstep under different protocol names, making
;; every iteration a first registration for both of them. (An earlier version
;; raced two protocols onto one shared tag and passed unfixed: it had exactly two
;; contended instants in 1200 iterations.) Checked against the unfixed code: it
;; loses a protocol on 2 of 3 runs, the same rate scenario 1 reproduces at.
(printf "\n== 7. concurrent extend-type while resolving ==\n")
(define pr-n 1500)
(define pr-err 0)
(define pr-err-mu (make-mutex))
(define (pr-tag i) (string-append "t7.T" (number->string i)))
(ok "7. registrars and resolvers all finished"
    (run-threads 8
                 (lambda (t)
                   (if (fx<? t 2)
                       (let loop ((i 0))
                         (when (fx<? i pr-n)
                           (register-protocol-method (pr-tag i)
                                                     (string-append "P" (number->string t))
                                                     "m" (lambda (x) x))
                           (loop (fx+ i 1))))
                       (let loop ((r 0))
                         (when (fx<? r 400)
                           (guard (e (#t (with-mutex pr-err-mu (set! pr-err (+ pr-err 1)))))
                             ;; the whole-table scan over a type's protocols, while
                             ;; those protocols are being inserted
                             (find-method-any-protocol (pr-tag (fxmod r pr-n)) "m")
                             (find-method-any-protocol-arity (pr-tag (fxmod r pr-n)) "m" 1))
                           (loop (fx+ r 1))))))
                 120.0 "7. extend churn"))
(ok "7. no resolve raised" (= pr-err 0))
(ok "7. neither definer's protocol was lost on any type"
    (let loop ((i 0) (lost 0))
      (if (fx=? i pr-n)
          (= lost 0)
          (loop (fx+ i 1)
                (+ lost
                   (if (find-protocol-method (pr-tag i) "P0" "m") 0 1)
                   (if (find-protocol-method (pr-tag i) "P1" "m") 0 1))))))

;; --- 8. the class graph and its derived caches --------------------------------
;; jch-register-supers! read-modify-writes jvm-class-parents and invalidates two
;; memo caches with hashtable-clear!; jch-known? built its table by publishing an
;; EMPTY one and filling it afterwards, so a concurrent instance? read it mid-fill
;; and got a definitive #f for a class the graph does model.
(printf "\n== 8. concurrent class-graph registration while asking isa? ==\n")
(define jch-n 800)
(define jch-bad 0)
(define jch-bad-mu (make-mutex))
(define (jch-name i) (string-append "t8.C" (number->string i)))
(ok "8. registrars and askers all finished"
    (run-threads 8
                 (lambda (t)
                   (if (fx<? t 2)
                       (let loop ((i 0))
                         (when (fx<? i jch-n)
                           (jch-register-supers! (jch-name i) (list "t8.Base"))
                           (loop (fx+ i 1))))
                       (let loop ((r 0))
                         (when (fx<? r 200)
                           ;; t8.Base is grafted by the very first registration, so
                           ;; once it is known it must STAY known — a half-built
                           ;; jch-known-cache is what made this flip back to #f
                           (when (and (fx> r 20) (not (jch-known? "t8.Base")))
                             (with-mutex jch-bad-mu (set! jch-bad (+ jch-bad 1))))
                           (jch-closure (jch-name (fxmod r jch-n)))
                           (jch-tags (jch-name (fxmod r jch-n)))
                           (loop (fx+ r 1))))))
                 120.0 "8. class-graph churn"))
(ok "8. a known class never read back as unknown" (= jch-bad 0))
(ok "8. every registration survived"
    (let loop ((i 0))
      (cond ((fx=? i jch-n) #t)
            ((member "t8.Base" (jch-direct-supers (jch-name i))) (loop (fx+ i 1)))
            (else #f))))
;; and the ancestry the caches serve is the CURRENT one, not a pre-clear leftover
(ok "8. the cached closure matches the live graph"
    (let loop ((i 0))
      (cond ((fx=? i jch-n) #t)
            ((member "t8.Base" (jch-closure (jch-name i))) (loop (fx+ i 1)))
            (else #f))))

;; --- 9. keyword interning ----------------------------------------------------
;; The worst one the audit found, and not because it corrupts anything: these are
;; STRONG hashtables, so the failure is a lost update, not a fault. But keyword
;; equality IS identity (values.ss jolt=2-base answers keywords with eq?, which is
;; what makes (:k m) a pointer compare), so a lost intern means two keyword-t for
;; one name and (= :foo :foo) false between the threads that made them. The hashes
;; still agree, since khash comes from ns/name — so a map lookup finds the right
;; bucket, fails the equality check, and answers nil for a key the map has.
;;
;; Asserted as a property, not as a crash: unfixed, 8 threads over 4000 fresh
;; names split 64 of them and (get {:kw-0 42} :kw-0) came back nil across a split.
(printf "\n== 9. concurrent interning of fresh keywords ==\n")
(define kw-threads 8)
(define kw-n 4000)
(define kw-res (make-vector kw-threads #f))
(ok "9. every thread finished interning"
    (run-threads kw-threads
                 (lambda (t)
                   (let loop ((i 0) (acc '()))
                     (if (fx=? i kw-n)
                         (vector-set! kw-res t (list->vector (reverse acc)))
                         (loop (fx+ i 1)
                               (cons (keyword #f (string-append "ts9-kw-" (number->string i)))
                                     acc)))))
                 60.0 "9. keyword interning"))
(define kw-split 0)
(let loop ((i 0))
  (when (fx<? i kw-n)
    (let ((k0 (vector-ref (vector-ref kw-res 0) i)))
      (let scan ((t 1))
        (cond ((fx=? t kw-threads) #f)
              ((not (eq? k0 (vector-ref (vector-ref kw-res t) i)))
               (set! kw-split (+ kw-split 1)))
              (else (scan (fx+ t 1))))))
    (loop (fx+ i 1))))
(ok "9. one object per keyword name across every thread" (= kw-split 0))
;; the consequence, stated directly: a map keyed by one thread's keyword must
;; answer another thread's keyword of the same name
(ok "9. a map keyed by one thread's keyword answers another thread's"
    (let loop ((i 0))
      (cond ((fx=? i kw-n) #t)
            ((let ((m (jolt-hash-map (vector-ref (vector-ref kw-res 0) i) 42)))
               (eqv? 42 (jolt-get m (vector-ref (vector-ref kw-res (fx- kw-threads 1)) i) jolt-nil)))
             (loop (fx+ i 1)))
            (else #f))))
;; symbol name strings are pooled by the same check-then-set, for JVM-parity
;; string identity ((str sym) is compared by identity in core.logic)
(define sym-res (make-vector kw-threads #f))
(ok "9. every thread finished interning symbol names"
    (run-threads kw-threads
                 (lambda (t)
                   (let loop ((i 0) (acc '()))
                     (if (fx=? i kw-n)
                         (vector-set! sym-res t (list->vector (reverse acc)))
                         (loop (fx+ i 1)
                               (cons (symbol-t-name
                                      (jolt-symbol #f (string-append "ts9-sym-" (number->string i))))
                                     acc)))))
                 60.0 "9. symbol-string interning"))
(ok "9. one name string per symbol name across every thread"
    (let loop ((i 0))
      (cond ((fx=? i kw-n) #t)
            ((let ((s0 (vector-ref (vector-ref sym-res 0) i)))
               (let scan ((t 1))
                 (cond ((fx=? t kw-threads) #t)
                       ((eq? s0 (vector-ref (vector-ref sym-res t) i)) (scan (fx+ t 1)))
                       (else #f))))
             (loop (fx+ i 1)))
            (else #f))))

;; --- 10. the two registrations the BACK END emits ----------------------------
;; jolt-register-callsite! and jolt-register-source! are emitted into every
;; compiled namespace and run at load. That used to be single-threaded; namespaces
;; now load in parallel, so both run concurrently and both were read-modify-write.
;; Strong tables again, so the failure is lost updates: 297 of 48000 callsite
;; entries, and the source registry's 'ambiguous marker missed 3 of 400 times.
(printf "\n== 10. the back end's load-time registrations ==\n")
(define reg-threads 8)
(define reg-n 6000)
(ok "10. every registrar finished"
    (run-threads reg-threads
                 (lambda (t)
                   (let loop ((i 0))
                     (when (fx<? i reg-n)
                       (jolt-register-callsite!
                        (string-append "ts10.ns" (number->string t) "/f") i
                        (string-append "ts10-callee-" (number->string i)) #f)
                       (loop (fx+ i 1)))))
                 120.0 "10. callsite registration"))
(ok "10. no callsite registration was lost"
    (let loop ((t 0))
      (cond ((fx=? t reg-threads) #t)
            ((let inner ((i 0))
               (cond ((fx=? i reg-n) #t)
                     ((jolt-callsite-callees (string-append "ts10.ns" (number->string t) "/f") i)
                      (inner (fx+ i 1)))
                     (else #f)))
             (loop (fx+ t 1)))
            (else #f))))

;; The 'ambiguous marker exists so a trace is never MISATTRIBUTED: two defs whose
;; emitted procname collides must drop the ns/file:line rather than pick one. Both
;; registrars reading #f before either writes defeats exactly that.
(define amb-rounds 400)
(define amb-missed 0)
(let loop ((r 0))
  (when (fx<? r amb-rounds)
    (let ((nm (string-append "ts10-proc-" (number->string r))))
      (run-threads 2
                   (lambda (t)
                     (jolt-register-source! nm (string-append "ts10.ns" (number->string t))
                                            "f" "a.clj" 1))
                   30.0 "10. source registration")
      (unless (eq? (hashtable-ref source-registry nm #f) 'ambiguous)
        (set! amb-missed (+ amb-missed 1))))
    (loop (fx+ r 1))))
(ok "10. a colliding procname is always marked ambiguous" (= amb-missed 0))

(printf "\nthread-safety-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "thread-safety-test: PASS — shared side-tables under concurrency\n") (exit 0))
    (exit 1))
