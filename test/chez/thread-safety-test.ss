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

(printf "\nthread-safety-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "thread-safety-test: PASS — shared side-tables under concurrency\n") (exit 0))
    (exit 1))
