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

(printf "\nthread-safety-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "thread-safety-test: PASS — shared side-tables under concurrency\n") (exit 0))
    (exit 1))
