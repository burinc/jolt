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

;; Elapsed time around a take, in ms. mono-millis is the timer's own clock, so a
;; measurement here and a deadline there cannot disagree about the unit.
(define (take-ms ch)
  (let ((t0 (mono-millis)))
    (jolt-async-take ch)
    (- (mono-millis) t0)))

(define (mono-ns) (let ((t (current-time 'time-monotonic))) (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (ns->ms ns) (/ (round (/ ns 10000)) 100.))

;; How the on-time rows are judged. EARLY is a bug whatever the load: a timeout
;; must not close before its deadline. Deadlines are exact (mono-deadline), and
;; elapsed is read in nanoseconds on the same monotonic clock from BEFORE the
;; timeout is made, so the lower bound needs no allowance at all.
;; LATE is what the ceilings are for, and the lateness they exist to catch is
;; gross: a lost wakeup closes a (timeout 100) at the 60000ms deadline pending
;; behind it. Load only ever adds to a wake, by tens of ms and now and then more,
;; so a reading over its ceiling is measured again, and fails only when it is
;; over in every round -- a lost wakeup is late every time.
;; A take that never returns would hang the gate rather than fail it, so each
;; one runs under a watchdog (a plain Chez timed wait, not this timer) that
;; fails the gate by name and exits.
(define watchdog-secs 20)
(define (watched name thunk)
  (let ((mu (make-mutex)) (cv (make-condition)) (done #f))
    (fork-thread
      (lambda ()
        (with-mutex mu
          (let wait ((left watchdog-secs))
            (unless done
              (if (<= left 0)
                  (begin
                    (printf "  FAIL: ~a -- no close after ~as (timer never fired, or a lost wakeup)\n"
                            name watchdog-secs)
                    (jolt-exit-process 1))
                  (begin
                    (condition-wait cv mu (make-time 'time-duration 0 1))
                    (wait (- left 1)))))))))
    (let ((v (thunk)))
      (with-mutex mu (set! done #t) (condition-signal cv))
      v)))

;; (timeout ms) made and taken: nanoseconds from just before it was made to the
;; take's return.
(define (timeout-ns name ms)
  (let* ((t0 (mono-ns)) (ch (jolt-async-timeout ms)))
    (watched name (lambda () (jolt-async-take ch)))
    (- (mono-ns) t0)))

;; One reading of (measure) against [floor-ms, ceiling-ms): early fails at once,
;; late is measured again, up to late-rounds readings in all.
(define late-rounds 3)
(define (on-time? name floor-ms ceiling-ms measure)
  (let round ((k 1))
    (let ((ns (measure)))
      (cond ((< ns (* floor-ms 1000000))
             (printf "    ~a closed EARLY: ~ams, deadline ~ams\n" name (ns->ms ns) floor-ms) #f)
            ((< ns (* ceiling-ms 1000000)) #t)
            ((< k late-rounds) (round (+ k 1)))
            (else (printf "    ~a: over ~ams in all ~a rounds, last ~ams\n"
                          name ceiling-ms late-rounds (ns->ms ns)) #f)))))

;; A structural property shows in every round; a noisy one can lose one. So a
;; row of paired medians passes on any of late-rounds rounds. (trial) answers
;; #t, or a diagnostic string for the round it lost.
(define (in-some-round? trial)
  (let round ((k 1))
    (let ((r (trial)))
      (cond ((eq? r #t) #t)
            ((< k late-rounds) (round (+ k 1)))
            (else (printf "    ~a (all ~a rounds)\n" r late-rounds) #f)))))

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
(ok "1b. (timeout 100) closes at ~100ms, never before"
    (on-time? "1b" 100 1000 (lambda () (timeout-ns "1b" 100))))
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
(ok "2b. (timeout 100) behind a pending (timeout 60000) closes at ~100ms"
    (on-time? "2b" 100 2000 (lambda () (timeout-ns "2b" 100))))
(ok "2c. the far timeout is still pending, untouched" (= 1 (pending-count)))
;; Twice in a row: the second insert is a head insert against a timer that has
;; just been woken, which is where a lost signal would show up as ONE late one.
(ok "2d. and again" (on-time? "2d" 100 2000 (lambda () (timeout-ns "2d" 100))))

;; --- 3. many deadlines, inserted out of order ---------------------------------
;; Inserted farthest-first, so every insert after the first is a head insert and
;; each one has to displace the deadline the timer is already waiting for.
(printf "\n== 3. deadlines inserted out of order all fire on time ==\n")
;; One round arms 300, 200, 100, takes them in deadline order, and answers when
;; each take returned, in ns from before the first insert. Each is held to its
;; own deadline for early, in every round. 3b and 3c judge lateness, and a round
;; that misses either is run again, by on-time?'s rule. 3c is the row that sees a
;; PARTIAL loss -- the 300 insert signalled, the 200 and 100 ones dropped -- which
;; closes the 100ms timeout at 300ms: late in every round, as load is not.
(define section-3-early #f)
(define (section-3-round first?)
  (let* ((t0 (mono-ns))
         (t300 (jolt-async-timeout 300))
         (t200 (jolt-async-timeout 200))
         (t100 (jolt-async-timeout 100)))
    (when first? (ok "3a. three more are pending, plus far" (= 4 (pending-count))))
    (let* ((e1 (begin (watched "3 (timeout 100)" (lambda () (jolt-async-take t100))) (- (mono-ns) t0)))
           (e2 (begin (watched "3 (timeout 200)" (lambda () (jolt-async-take t200))) (- (mono-ns) t0)))
           (e3 (begin (watched "3 (timeout 300)" (lambda () (jolt-async-take t300))) (- (mono-ns) t0))))
      (when (or (< e1 100000000) (< e2 200000000) (< e3 300000000))
        (printf "    3 closed EARLY: ~ams ~ams ~ams for 100/200/300\n"
                (ns->ms e1) (ns->ms e2) (ns->ms e3))
        (set! section-3-early #t))
      (list e1 e2 e3))))
(let round ((k 1))
  (let* ((es (section-3-round (= k 1)))
         (e1 (car es)) (e3 (caddr es))
         (b (< e3 2000000000))    ; all three closed within ~300ms of the first insert
         (c (< e1 250000000)))    ; the 100ms one did not wait for a later deadline
    (if (or section-3-early (and b c) (= k late-rounds))
        (begin
          (unless (and b c)
            (printf "    3: ~ams ~ams ~ams for 100/200/300 (over in all ~a rounds)\n"
                    (ns->ms e1) (ns->ms (cadr es)) (ns->ms e3) late-rounds))
          (ok "3b. all three closed within ~300ms of the first insert, none early"
              (and b (not section-3-early)))
          (ok "3c. the 100ms one closed at ~100ms, not at a later deadline" c))
        (round (+ k 1)))))
(ok "3d. only the far one is left" (= 1 (pending-count)))

;; --- 4. the sequential shape that leaked a thread per call --------------------
(printf "\n== 4. 100 sequential timeouts ==\n")
(let ((t0 (mono-millis)))
  (let loop ((k 0))
    (when (< k 100)
      (jolt-async-take (jolt-async-timeout 1))
      (loop (+ k 1))))
  ;; 100 × 1ms of deadline. A generous ceiling: the point is that none of them
  ;; waited for `far`, which would be 100 × 60s.
  (ok "4a. 100 × (timeout 1) finished promptly" (< (- (mono-millis) t0) 10000)))
(ok "4b. still one timer thread, still claimed" timeout-running?)
(ok "4c. and nothing but far is pending" (= 1 (pending-count)))

;; --- 5. a deadline already in the past ----------------------------------------
(printf "\n== 5. a deadline in the past closes immediately ==\n")
(ok "5a. (timeout 0) closes at once"
    (on-time? "5a" 0 1000 (lambda () (timeout-ns "5a" 0))))

;; --- 6. cancelling a pending deadline ----------------------------------------
;; A wait that ends before its deadline takes the entry out (jolt-timer-cancel!),
;; so the heap stops holding the thunk — and everything the thunk closes over —
;; the moment the wait is over rather than at the deadline.
(printf "\n== 6. a cancelled deadline leaves the heap and never runs ==\n")
(define fired-6 #f)
(let ((h (jolt-timer-at! (+ (mono-millis) 100) (lambda () (set! fired-6 #t)))))
  (ok "6a. armed: pending grows by one" (= 2 (pending-count)))
  (ok "6b. cancel answers #t for a pending entry" (eq? #t (jolt-timer-cancel! h)))
  (ok "6c. it stops counting as pending at once" (= 1 (pending-count)))
  (ok "6c'. and the heap has let go of its thunk" (not (cdr h)))
  (ok "6d. a second cancel answers #f" (eq? #f (jolt-timer-cancel! h)))
  (take-ms (jolt-async-timeout 300))
  (ok "6e. its thunk never ran" (not fired-6)))
;; cancelling after it fired is a no-op that says so
(let* ((ch (jolt-async-timeout 1))
       (h (jolt-timer-at! (mono-millis) (lambda () #t))))
  (jolt-async-take ch)
  (take-ms (jolt-async-timeout 20))
  (ok "6f. cancel after firing answers #f" (eq? #f (jolt-timer-cancel! h)))
  (ok "6g. and leaves far alone" (= 1 (pending-count))))

;; --- 7. the heap order survives arbitrary removals -----------------------------
;; A cancel leaves its entry in place with no thunk; the timer drops it when it
;; reaches the top. Insert a scrambled band, cancel every third, and let the rest
;; fire: every survivor fires, no cancelled one does, and they fire in deadline
;; order (each thunk records its deadline).
(printf "\n== 7. cancels from the middle keep the heap ordered ==\n")
(define fired-7 '())
(let* ((base (+ (mono-millis) 200))
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
(let* ((base (+ (mono-millis) 3600000))
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

;; --- 9. a deadline is never due early --------------------------------------
;; mono-millis truncates, so a deadline built off it fell up to 1ms short of the
;; time asked for, and a wait could end before its timeout (the JDK's never do;
;; #1305's waitFor gate caught it on bionic). Busy-waiting on the clock takes OS
;; wake-up latency out, which otherwise hides the shortfall; the elapsed time is
;; read in nanoseconds on the same monotonic clock.
(printf "\n== 9. a deadline is never due early ==\n")
(let loop ((i 0) (short 0))
  (if (= i 50)
      (ok "9a. no 2ms deadline came due before 2ms had passed" (= short 0))
      (let* ((t0 (mono-ns)) (d (mono-deadline 2)))
        (let spin () (when (< (mono-millis) d) (spin)))
        (loop (+ i 1) (if (< (- (mono-ns) t0) 2000000) (+ short 1) short)))))

;; --- 10. a timed wait does not run past its deadline ----------------------
;; The relative timeout a thread waits with was (- deadline (mono-millis)) ms,
;; counted from the truncated millisecond, so it ended up to 1ms after the
;; deadline, and (Thread/sleep 1) took 2.5ms. The timeout handed to
;; condition-wait must not exceed the time actually left. (Thread/sleep 0) waited
;; for the next tick of the clock, and (Thread/sleep 0 n) dropped the n.
(printf "\n== 10. a timed wait does not run past its deadline ==\n")
(define (duration-ns d) (+ (* 1000000000 (time-second d)) (time-nanosecond d)))
(let loop ((i 0) (over 0))
  (if (= i 50)
      (ok "10a. no timeout reaches past its deadline" (= over 0))
      (let* ((d (mono-deadline 2))
             (left (- (* 1000000 d) (mono-ns)))
             (w (duration-ns (jolt-deadline->timeout d))))
        (loop (+ i 1) (if (> w left) (+ over 1) over)))))
;; Timing rows compare two things measured interleaved in this one run, not a
;; wall-clock bound: a loaded runner (the Android emulator) stretches a yield and
;; a wake alike, and an absolute ceiling read that as a regression.
(define (time-ns thunk) (let ((t0 (mono-ns))) (thunk) (- (mono-ns) t0)))
(define (median xs) (list-ref (sort < xs) (quotient (length xs) 2)))
(define (paired-medians a b n)   ; -> (median-of-a . median-of-b), interleaved
  (let loop ((i 0) (as '()) (bs '()))
    (if (= i n)
        (cons (median as) (median bs))
        (let* ((ta (time-ns a)) (tb (time-ns b)))
          (loop (+ i 1) (cons ta as) (cons tb bs))))))
;; sleep(0) is a yield, so it costs what a yield costs; waiting for the next tick
;; of the millisecond clock cost ~1ms more than that.
(ok "10b. sleep(0) costs a yield, not a clock tick"
    (in-some-round?
      (lambda ()
        (let ((m (paired-medians (lambda () (jolt-thread-sleep-ms 0))
                                 (lambda () (unless (jolt-fiber-wait-turn! 0) (thread-yield!)))
                                 51)))
          (or (<= (car m) (+ (* 4 (cdr m)) 200000))
              (format "sleep(0) ~ans vs yield ~ans" (car m) (cdr m)))))))
(ok "10c. sleep(0, 100000) is not cut to nothing"
    (let loop ((i 0))
      (or (= i 20)
          (let ((t0 (mono-ns)))
            (jolt-thread-sleep-ms+ns 0 100000)
            (and (>= (- (mono-ns) t0) 100000) (loop (+ i 1)))))))
;; and not rounded up to a whole millisecond, which would make it cost what
;; sleep(1) costs
(ok "10d. and not stretched to a millisecond either"
    (in-some-round?
      (lambda ()
        (let ((m (paired-medians (lambda () (jolt-thread-sleep-ms+ns 0 100000))
                                 (lambda () (jolt-thread-sleep-ms 1))
                                 31)))
          (or (< (car m) (* 3/4 (cdr m)))
              (format "sleep(0, 100000) ~ans vs sleep(1) ~ans" (car m) (cdr m)))))))

;; A timeout of zero or less is already due: rounding now up made (.poll q 0 ms)
;; and (deref p 0 nil) wait for the next tick of the clock, ~1ms a call, where
;; the JDK's return at once.
(ok "10e. a zero or negative timeout is due as it is made"
    (let loop ((i 0))
      (or (= i 50)
          (and (mono-due? (mono-deadline 0)) (mono-due? (mono-deadline -5))
               (loop (+ i 1))))))

;; --- 11. every timed wait ends at its deadline, not a millisecond tick ----
;; Thread/sleep got an exact deadline in 10; the other timed waits still built
;; theirs as a whole millisecond rounded up from now, so with the wake latency on
;; top a 1ms wait took ~2ms where the JDK's take ~1.1-1.3ms, and a TimeUnit finer
;; than a millisecond was truncated to no wait at all. Each site's 1ms wait is
;; timed interleaved with a sleep(1) from this run -- the same timed condition
;; wait, so load stretches both alike -- and must cost about what it does, and
;; never less than the 1ms it was asked for.
(printf "\n== 11. every timed wait ends at its deadline ==\n")
(define (ev s) (jolt-compile-eval s "user"))
(ev "(import '[java.util.concurrent TimeUnit LinkedBlockingQueue ArrayBlockingQueue CountDownLatch Executors CompletableFuture FutureTask] '[java.util.concurrent.locks ReentrantLock])")
(ev "(def tw-ms TimeUnit/MILLISECONDS)")
(ev "(def tw-p (promise))")
(ev "(def tw-fut (future (Thread/sleep 600000)))")
(ev "(def tw-q (LinkedBlockingQueue.))")
(ev "(def tw-fq (doto (ArrayBlockingQueue. 1) (.offer 1)))")
(ev "(def tw-latch (CountDownLatch. 1))")
(ev "(def tw-lk (ReentrantLock.))")
(ev "(let [held (CountDownLatch. 1)] (doto (Thread. (fn [] (.lock tw-lk) (.countDown held) (Thread/sleep 600000))) (.setDaemon true) .start) (.await held))")
(ev "(def tw-ex (Executors/newFixedThreadPool 1))")
(ev "(.submit tw-ex ^Runnable (fn [] (Thread/sleep 600000)))")
(ev "(def tw-jf (.submit tw-ex ^Callable (fn [] 1)))")
(ev "(def tw-cf (CompletableFuture.))")
(ev "(def tw-ft (FutureTask. (fn [] 1)))")
(ev "(def tw-th (doto (Thread. (fn [] (Thread/sleep 600000))) (.setDaemon true) .start))")
(ev "(def tw-o (Object.))")
(ev "(def tw-proc (.start (ProcessBuilder. [\"sleep\" \"600\"])))")
(ev "(def tw-ag (agent 0))")
(ev "(send-off tw-ag (fn [x] (Thread/sleep 600000) x))")
(define tw-sites
  '(("deref promise" . "(deref tw-p 1 nil)")
    ("deref future" . "(deref tw-fut 1 nil)")
    ("LinkedBlockingQueue.poll" . "(.poll tw-q 1 tw-ms)")
    ("ArrayBlockingQueue.offer" . "(.offer tw-fq 2 1 tw-ms)")
    ("CountDownLatch.await" . "(.await tw-latch 1 tw-ms)")
    ("ReentrantLock.tryLock" . "(.tryLock tw-lk 1 tw-ms)")
    ("awaitTermination" . "(.awaitTermination tw-ex 1 tw-ms)")
    ("executor Future.get" . "(try (.get tw-jf 1 tw-ms) (catch Exception _ nil))")
    ("CompletableFuture.get" . "(try (.get tw-cf 1 tw-ms) (catch Exception _ nil))")
    ("FutureTask.get" . "(try (.get tw-ft 1 tw-ms) (catch Exception _ nil))")
    ("Thread.join" . "(.join tw-th 1)")
    ("Object.wait" . "(locking tw-o (.wait tw-o 1))")
    ("Process.waitFor" . "(.waitFor tw-proc 1 tw-ms)")
    ("await-for" . "(await-for 1 tw-ag)")
    ("async timeout" . "(clojure.core.async/<!! (clojure.core.async/timeout 1))")))
;; Load only ever adds to a wait, and a noisy round can leave one median above
;; the other by more than the margin; the rounding this row is about is structural
;; and shows in every round. So a site passes on any of a few rounds, and fails
;; only when every round puts it a fraction of a tick behind sleep(1).
(define (tw-like-sleep1? name wait sleep1)
  (let round ((k 0))
    (let ((m (paired-medians wait sleep1 21)))
      (cond ((<= (car m) (+ (* 5/4 (cdr m)) 100000)) #t)
            ((< k 3) (round (+ k 1)))
            (else (printf "    ~a ~ans vs sleep(1) ~ans\n" name (car m) (cdr m)) #f)))))
(for-each
  (lambda (site)
    (let* ((f (ev (string-append "(fn [] " (cdr site) ")")))
           (wait (lambda () (jolt-invoke f)))
           (sleep1 (lambda () (jolt-thread-sleep-ms 1)))
           (early 0))
      (wait) (sleep1)
      (let loop ((i 0))
        (when (< i 5)
          (when (< (time-ns wait) 1000000) (set! early (+ early 1)))
          (loop (+ i 1))))
      (ok (format "11a. ~a(1ms) never returns early" (car site)) (= early 0))
      (ok (format "11b. ~a(1ms) costs a sleep(1), not two ticks" (car site))
          (tw-like-sleep1? (car site) wait sleep1))))
  tw-sites)
;; a TimeUnit finer than a millisecond was truncated to whole milliseconds: 500us
;; was no wait at all
(ok "11c. poll(500, MICROSECONDS) waits its half millisecond"
    (let ((f (ev "(fn [] (.poll tw-q 500 TimeUnit/MICROSECONDS))")))
      (let loop ((i 0))
        (or (= i 10)
            (and (>= (time-ns (lambda () (jolt-invoke f))) 500000) (loop (+ i 1)))))))
(ok "11d. and is not stretched to a millisecond"
    (let ((f (ev "(fn [] (.poll tw-q 250 TimeUnit/MICROSECONDS))")))
      (in-some-round?
        (lambda ()
          (let ((m (paired-medians (lambda () (jolt-invoke f))
                                   (lambda () (jolt-thread-sleep-ms 1))
                                   21)))
            (or (< (car m) (* 3/4 (cdr m)))
                (format "poll(250us) ~ans vs sleep(1) ~ans" (car m) (cdr m))))))))
;; a one-shot timeout starts when the wait first waits, so the zero and negative
;; ones are due on the first decide, and a positive one only after it
(ok "11e. a timeout not yet started is due exactly when it is zero or less"
    (and (jolt-deadline-due? (jolt-timeout 0)) (jolt-deadline-due? (jolt-timeout -1))
         (not (jolt-deadline-due? (jolt-timeout 1/1000)))
         (not (mono-due? (jolt-deadline-start (jolt-timeout 1000))))))
(ev "(.destroy tw-proc)")

(printf "\n~a checks, ~a failed\n" total fails)
(when (> fails 0) (exit 1))
(printf "async-timer gate: PASS\n")
