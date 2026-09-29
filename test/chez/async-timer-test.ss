;; test/chez/async-timer-test.ss — the shared (timeout ms) timer (jolt-pe84).
;; Run: chez --script test/chez/async-timer-test.ss (wired into `make asynctimer`).
;;
;; One timer thread serves every (timeout ms) in the process, which makes the two
;; things asserted here properties of the WHOLE channel surface: alts! against a
;; timeout, core.async's own timeout-driven operators, and a fiber parked on a
;; timeout all resume when this timer says so.
;;
;;   1. A timeout closes on ITS OWN deadline, whatever else is pending. The timer
;;      used to sleep to the nearest deadline with timeout-mu released, so it was
;;      not on timeout-cv when a nearer deadline was inserted; the signal was
;;      dropped and the new timeout fired at the OLD deadline. (timeout 100)
;;      behind a pending (timeout 3000) took 3000ms. That is what the lateness
;;      checks are for, and why each one is measured against a far pending
;;      deadline rather than in isolation.
;;   2. The timer thread is forked ONCE. It waits rather than exiting when the
;;      pending list empties, so clearing timeout-running? before that wait made
;;      the next insert both signal the live thread AND fork another: 100
;;      sequential (timeout 1) calls left 100 live timer threads. The flag is the
;;      fork guard, so asserting it stays set across a drain to empty IS the
;;      no-leak check — Chez gives a script no way to count its own threads.
;;
;; White-box on purpose: the interesting states (an empty pending list, a far
;; deadline pending) are not reachable from a black-box read of a channel, and
;; timeout-pending / timeout-running? are top-level defines in async.ss, which
;; this gate loads into the same environment.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "  FAIL: ~a\n" name)))

;; Wall clock around a take, in ms. now-millis is the timer's own clock, so a
;; measurement here and a deadline there cannot disagree about the unit.
(define (take-ms ch)
  (let ((t0 (now-millis)))
    (jolt-async-take ch)
    (- (now-millis) t0)))

;; Read the timer's state the way the timer writes it. The entry for a closed
;; channel is removed under timeout-mu BEFORE the mutex drops, so by the time a
;; take has returned and this can acquire it, a fired timeout is already gone.
;; the pending store is a binary min-heap now (async.ss timeout-heap); its live
;; count is the heap fill less the cancelled entries still in it, read under the
;; same lock as before.
(define (pending-count) (jolt-with-mutex timeout-mu (timeout-pending-count)))

(printf "== the shared (timeout ms) timer ==\n")

;; --- 1. a lone timeout, and the drain to empty --------------------------------
(printf "\n== 1. one timeout: fires on time, leaves nothing pending ==\n")
(ok "1a. no timer thread before the first (timeout ms)" (not timeout-running?))
(let ((ms (take-ms (jolt-async-timeout 100))))
  (ok "1b. (timeout 100) closes at ~100ms" (and (>= ms 90) (< ms 1000))))
(ok "1c. the fired entry is off the pending list" (= 0 (pending-count)))
;; THE NO-LEAK CHECK: the list just drained to empty, so the timer is parked on
;; timeout-cv with nothing pending — the exact state in which it used to declare
;; itself gone and let the next insert fork a second immortal thread.
(ok "1d. the timer thread is still claimed after the list drained to empty"
    timeout-running?)

;; --- 2. a nearer deadline behind a farther one --------------------------------
;; far stays pending for the rest of the gate: every check below is therefore
;; made in the state that used to break them, not in isolation.
(printf "\n== 2. a nearer deadline arriving behind a far one ==\n")
(define far (jolt-async-timeout 60000))
(ok "2a. the far timeout is pending" (= 1 (pending-count)))
(let ((ms (take-ms (jolt-async-timeout 100))))
  (ok "2b. (timeout 100) behind a pending (timeout 60000) closes at ~100ms"
      (and (>= ms 90) (< ms 2000))))
(ok "2c. the far timeout is still pending, untouched" (= 1 (pending-count)))
;; Twice in a row: the second insert is a head insert against a timer that has
;; just been woken, which is where a lost signal would show up as ONE late one.
(let ((ms (take-ms (jolt-async-timeout 100))))
  (ok "2d. and again" (and (>= ms 90) (< ms 2000))))

;; --- 3. many deadlines, inserted out of order ---------------------------------
;; Inserted farthest-first, so every insert after the first is a head insert and
;; each one has to displace the deadline the timer is already waiting for.
(printf "\n== 3. deadlines inserted out of order all fire on time ==\n")
(define t300 (jolt-async-timeout 300))
(define t200 (jolt-async-timeout 200))
(define t100 (jolt-async-timeout 100))
(ok "3a. three more are pending, plus far" (= 4 (pending-count)))
(let* ((m1 (take-ms t100))
       (m2 (take-ms t200))
       (m3 (take-ms t300)))
  ;; Taken in deadline order, so each take's own wait is short; what is asserted
  ;; is the SUM, which is the time from the first insert to the last close.
  (ok "3b. all three closed within ~300ms of the first insert"
      (< (+ m1 m2 m3) 2000))
  (ok "3c. the 100ms one closed first" (< m1 250)))
(ok "3d. only the far one is left" (= 1 (pending-count)))

;; --- 4. the sequential shape that leaked a thread per call --------------------
(printf "\n== 4. 100 sequential timeouts ==\n")
(let ((t0 (now-millis)))
  (let loop ((k 0))
    (when (< k 100)
      (jolt-async-take (jolt-async-timeout 1))
      (loop (+ k 1))))
  ;; 100 × 1ms of deadline. A generous ceiling: the point is that none of them
  ;; waited for `far`, which would be 100 × 60s.
  (ok "4a. 100 × (timeout 1) finished promptly" (< (- (now-millis) t0) 10000)))
(ok "4b. still one timer thread, still claimed" timeout-running?)
(ok "4c. and nothing but far is pending" (= 1 (pending-count)))

;; --- 5. a deadline already in the past ----------------------------------------
(printf "\n== 5. a deadline in the past closes immediately ==\n")
(let ((ms (take-ms (jolt-async-timeout 0))))
  (ok "5a. (timeout 0) closes at once" (< ms 1000)))

;; --- 6. cancelling a pending deadline ----------------------------------------
;; A wait that ends before its deadline takes the entry out (jolt-timer-cancel!),
;; so the heap stops holding the thunk — and everything the thunk closes over —
;; the moment the wait is over rather than at the deadline.
(printf "\n== 6. a cancelled deadline leaves the heap and never runs ==\n")
(define fired-6 #f)
(let ((h (jolt-timer-at! (+ (now-millis) 100) (lambda () (set! fired-6 #t)))))
  (ok "6a. armed: pending grows by one" (= 2 (pending-count)))
  (ok "6b. cancel answers #t for a pending entry" (eq? #t (jolt-timer-cancel! h)))
  (ok "6c. it stops counting as pending at once" (= 1 (pending-count)))
  (ok "6c'. and the heap has let go of its thunk" (not (cdr h)))
  (ok "6d. a second cancel answers #f" (eq? #f (jolt-timer-cancel! h)))
  (take-ms (jolt-async-timeout 300))
  (ok "6e. its thunk never ran" (not fired-6)))
;; cancelling after it fired is a no-op that says so
(let* ((ch (jolt-async-timeout 1))
       (h (jolt-timer-at! (now-millis) (lambda () #t))))
  (jolt-async-take ch)
  (take-ms (jolt-async-timeout 20))
  (ok "6f. cancel after firing answers #f" (eq? #f (jolt-timer-cancel! h)))
  (ok "6g. and leaves far alone" (= 1 (pending-count))))

;; --- 7. the heap order survives arbitrary removals -----------------------------
;; Removing from the middle moves the last entry into the hole, which may have to
;; go up or down. Insert a scrambled band, cancel every third, and let the rest
;; fire: every survivor fires, no cancelled one does, and they fire in deadline
;; order (each thunk records its deadline).
(printf "\n== 7. cancels from the middle keep the heap ordered ==\n")
(define fired-7 '())
(let* ((base (+ (now-millis) 200))
       (n 300)
       (hs (let loop ((i 0) (acc '()))
             (if (= i n)
                 (reverse acc)
                 (let* ((d (+ base (modulo (* i 7919) n)))
                        (h (jolt-timer-at! d (lambda ()
                                               (jolt-with-mutex timeout-mu
                                                 (set! fired-7 (cons d fired-7)))))))
                   (loop (+ i 1) (cons (cons d h) acc))))))
       (kept (let loop ((hs hs) (i 0) (acc '()))
               (cond ((null? hs) acc)
                     ((= 0 (modulo i 3)) (jolt-timer-cancel! (cdar hs)) (loop (cdr hs) (+ i 1) acc))
                     (else (loop (cdr hs) (+ i 1) (cons (caar hs) acc)))))))
  (ok "7a. pending is far plus the survivors" (= (+ 1 (length kept)) (pending-count)))
  (take-ms (jolt-async-timeout (+ n 400)))
  (let ((fired (reverse (jolt-with-mutex timeout-mu fired-7))))
    (ok "7b. exactly the survivors fired" (equal? (sort < fired) (sort < kept)))
    (ok "7c. in deadline order"
        (let loop ((l fired)) (or (null? l) (null? (cdr l))
                                  (and (<= (car l) (cadr l)) (loop (cdr l))))))
    (ok "7d. only far is left" (= 1 (pending-count)))))

;; --- 8. dead entries do not accumulate -----------------------------------------
;; Cancelled entries are dropped lazily, so what bounds the heap is the rebuild:
;; once the dead outnumber the live, the heap is compacted to the live ones. Arm a
;; far band, cancel almost all of it, and the heap is back near its live size,
;; still ordered for what is left.
(printf "\n== 8. cancelled entries are compacted away ==\n")
(let* ((base (+ (now-millis) 3600000))
       (hs (let loop ((i 0) (acc '()))
             (if (= i 2000) acc
                 (loop (+ i 1) (cons (jolt-timer-at! (+ base (modulo (* i 7919) 2000)) (lambda () #t)) acc))))))
  (for-each jolt-timer-cancel! (list-tail hs 10))
  (ok "8a. ten of the band are still pending, plus far" (= 11 (pending-count)))
  (ok "8b. the heap holds at most twice what is pending (plus the floor)"
      (<= (jolt-with-mutex timeout-mu timeout-heap-n) (max 64 (* 2 11))))
  (ok "8c. the rebuilt heap is still a heap"
      (jolt-with-mutex timeout-mu
        (let loop ((i 1))
          (or (>= i timeout-heap-n)
              (and (<= (car (vector-ref timeout-heap (quotient (- i 1) 2)))
                       (car (vector-ref timeout-heap i)))
                   (loop (+ i 1)))))))
  (for-each jolt-timer-cancel! (list-head hs 10))
  (ok "8d. and only far is left" (= 1 (pending-count))))

(printf "\n~a checks, ~a failed\n" total fails)
(when (> fails 0) (exit 1))
(printf "async-timer gate: PASS\n")
