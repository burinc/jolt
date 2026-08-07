;; test/chez/fibers-chan-test.ss — R3 gate: one waiter protocol for threads and
;; fibers (epic jolt-nvpr.4). Run: chez --script test/chez/fibers-chan-test.ss
;; (wired into `make fibers`).
;;
;; Loads the full host runtime (rt.ss), like fibers-state-test.ss: the gate
;; drives the REAL async.ss channels and the R1/R2 fibers at host level.
;;
;; The bet under test: fibers consume core.async's existing callback protocol.
;; A fiber's <! registers an alt-taker handler whose wake is the fiber; a
;; thread's pending op keeps the condvar wake. Channels are not rewritten — the
;; only channel-side change is that alt-deliver! dispatches the wake strategy.
;;
;; Gate scenarios (spec, in order):
;;   1. fiber -> thread handoff, unbuffered (fiber put parks; thread take wakes it)
;;   2. thread -> fiber handoff, unbuffered (fiber take parks; thread put wakes it)
;;   3. buffered handoff in both directions — immediate, no capture
;;   4. a take that finds a waiting putter — immediate, no capture
;;   5. a thread blocked on an empty channel wakes when a fiber puts
;;   5b. put! completes on the caller against a parked fiber taker
;;   6. N fibers and M threads on one channel, every value delivered exactly once
;;      (fiber-takers/thread-putters, and fiber-putters/thread-takers)
;;   7. a closed channel wakes both kinds of waiter
;;   8. no deadlock: a fiber parks on a channel while another fiber on the same
;;      carrier is putting (the notify pairing path)
;;   9. offer! completes against a parked fiber taker (the ac-try-give! clause)
;;  10. stress: a fiber drains a pumping thread, no lost wakeups (bounded)
;;
;; The R3 measurement is the capture counter jolt-fiber-chan-parks — the
;; immediate-completion path must not move it. Where timing appears it is a
;; RATIO against a calibration loop in this process, never an absolute ceiling.

(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))

(define (all-done? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'done) (all-done? (cdr fs)))))
(define (all? pred ls)
  (or (null? ls) (and (pred (car ls)) (all? pred (cdr ls)))))
(define (all-vector? v)
  (let loop ((i 0))
    (or (fx>=? i (vector-length v))
        (and (vector-ref v i) (loop (fx+ i 1))))))
(define (spawn-n n mk)
  (let loop ((i 0) (acc '()))
    (if (fx<? i n)
        (loop (fx+ i 1) (cons (mk i) acc))
        (reverse acc))))

;; Bounded wait: a bug must FAIL the gate, never hang it. Returns #t if pred
;; became true within secs, else records a failure.
(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (if (pred)
          #t
          (if (> (now-secs) deadline)
              (begin (set! fails (+ fails 1)) (printf "  FAIL: ~a (timed out)\n" what) #f)
              (begin (sleep (make-time 'time-duration 1000000 0)) (loop)))))))

;; Run the carrier repeatedly (run-all drains; a wake from another thread lands
;; on the queue between drains) until fiber f finishes or secs pass. The gate's
;; version of "the scheduler loop": run ready fibers, then wait a beat, repeat.
(define (run-all-until f secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((eq? (jolt-fiber-state f) 'done) #t)
            ((> (now-secs) deadline)
             (set! fails (+ fails 1)) (printf "  FAIL: ~a (timed out)\n" what) #f)
            (else (sa-fiber-run-all)
                  (sleep (make-time 'time-duration 1000000 0))
                  (loop))))))

;; The same, for a SET of fibers. This exists because of a real CI failure worth
;; remembering: a cross-thread wake lands a fiber on the run queue AFTER
;; sa-fiber-run-all has already drained and returned, so a single drain is not
;; enough whenever another OS thread is what unblocks the fiber. Locally the
;; threads were always blocked in take before the fibers ran, so every put
;; completed immediately and one drain sufficed; on a slower runner some fibers
;; parked and were left runnable-but-unrun. sa-fiber-run-all is a one-shot
;; drain, NOT a scheduler — a real carrier loops (R5), and until then a test
;; that mixes threads and fibers has to pump.
(define (run-all-until-all fs secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((all-done? fs) #t)
            ((> (now-secs) deadline)
             (set! fails (+ fails 1)) (printf "  FAIL: ~a (timed out)\n" what) #f)
            (else (sa-fiber-run-all)
                  (sleep (make-time 'time-duration 1000000 0))
                  (loop))))))

(printf "== R3: one waiter protocol for threads and fibers ==\n")

;; --- 1. fiber -> thread, unbuffered ------------------------------------------
;; The fiber's >! parks (no taker); the thread's blocking take claims the
;; alt-putter handler, which delivers #t (waking the fiber) and returns the
;; value.
(printf "\n== 1. fiber -> thread, unbuffered ==\n")
(define ch1 (jolt-async-chan))
(define f1 (sa-fiber-spawn (lambda () (jolt-fiber->! ch1 42))))
(sa-fiber-run-all)
(ok "1. fiber putter parked" (eq? (jolt-fiber-state f1) 'parked))
(define t1-val 'unset)
(fork-thread (lambda () (set! t1-val (jolt-async-take ch1))))
(wait-until (lambda () (not (eq? t1-val 'unset))) 5.0 "thread take completed")
(sa-fiber-run-all)
(ok "1. thread got the value" (eq? t1-val 42))
(ok "1. fiber put completed" (eq? (jolt-fiber-result f1) #t))
(ok "1. exactly one park (the put)" (= jolt-fiber-chan-parks 1))

;; --- 2. thread -> fiber, unbuffered ------------------------------------------
;; The fiber's <! parks (empty); the thread's blocking put delivers the value
;; to the alt-taker (waking the fiber) and returns once taken.
(printf "\n== 2. thread -> fiber, unbuffered ==\n")
(define ch2 (jolt-async-chan))
(define f2 (sa-fiber-spawn (lambda () (jolt-fiber-<! ch2))))
(sa-fiber-run-all)
(ok "2. fiber taker parked" (eq? (jolt-fiber-state f2) 'parked))
(define p2 jolt-fiber-chan-parks)
(ok "2. thread put completed (taker already waiting)" (eq? (jolt-async-give ch2 43) #t))
(sa-fiber-run-all)
(ok "2. fiber got the value" (eq? (jolt-fiber-result f2) 43))
(ok "2. no additional capture" (= jolt-fiber-chan-parks p2))

;; --- 3. buffered, both directions (immediate) --------------------------------
;; Room on the put side and a buffered value on the take side complete without
;; parking — the capture counter must not move.
(printf "\n== 3. buffered, both directions (immediate) ==\n")
(define ch3 (jolt-async-chan 2))
(define p3 jolt-fiber-chan-parks)
(define f3a (sa-fiber-spawn (lambda () (jolt-fiber->! ch3 1))))
(sa-fiber-run-all)
(ok "3. fiber put into room: immediate, no capture"
    (and (eq? (jolt-fiber-result f3a) #t) (= jolt-fiber-chan-parks p3)))
(ok "3. thread take got the value" (eq? (jolt-async-take ch3) 1))
(ok "3. thread put into room" (eq? (jolt-async-give ch3 2) #t))
(define f3b (sa-fiber-spawn (lambda () (jolt-fiber-<! ch3))))
(sa-fiber-run-all)
(ok "3. fiber take of a buffered value: immediate, no capture"
    (and (eq? (jolt-fiber-result f3b) 2) (= jolt-fiber-chan-parks p3)))

;; --- 4. a take that finds a waiting putter: immediate, no capture ------------
(printf "\n== 4. take finds a waiting putter: no capture ==\n")
(define ch4 (jolt-async-chan))
(define f4p (sa-fiber-spawn (lambda () (jolt-fiber->! ch4 5))))
(sa-fiber-run-all)
(ok "4. putter parked" (eq? (jolt-fiber-state f4p) 'parked))
(define p4 jolt-fiber-chan-parks)
(define f4t (sa-fiber-spawn (lambda () (jolt-fiber-<! ch4))))
(sa-fiber-run-all)
(ok "4. taker drained the putter without parking" (= jolt-fiber-chan-parks p4))
(ok "4. taker got the value" (eq? (jolt-fiber-result f4t) 5))
(ok "4. putter completed" (eq? (jolt-fiber-result f4p) #t))

;; --- 5. a thread blocked on an empty channel wakes when a fiber puts ---------
;; The thread's take is a takew waiter; the fiber's >! sees takew > 0 and
;; completes immediately (no capture) via the rendezvous push + broadcast.
(printf "\n== 5. thread blocked on empty, fiber puts ==\n")
(define ch5 (jolt-async-chan))
(define t5-val 'unset)
(fork-thread (lambda () (set! t5-val (jolt-async-take ch5))))
(wait-until (lambda () (> (async-chan-takew ch5) 0)) 5.0 "thread blocked in take")
(define p5 jolt-fiber-chan-parks)
(define f5 (sa-fiber-spawn (lambda () (jolt-fiber->! ch5 44))))
(sa-fiber-run-all)
(wait-until (lambda () (not (eq? t5-val 'unset))) 5.0 "thread take completed")
(ok "5. thread got the fiber's value" (eq? t5-val 44))
(ok "5. fiber put completed immediately, no capture"
    (and (eq? (jolt-fiber-result f5) #t) (= jolt-fiber-chan-parks p5)))

;; --- 5b. put! completes on the caller against a parked fiber taker -----------
;; Without the ac-try-give! alt-taker clause, put! would see 'full and fork a
;; thread; the callback would NOT have run when we check. This is the shared-
;; channel completeness fix (offer!/put! must count a fiber taker as waiting).
(printf "\n== 5b. put! against a parked fiber taker ==\n")
(define ch5b (jolt-async-chan))
(define f5b (sa-fiber-spawn (lambda () (jolt-fiber-<! ch5b))))
(sa-fiber-run-all)
(ok "5b. fiber taker parked" (eq? (jolt-fiber-state f5b) 'parked))
(define cb5 'unset)
(jolt-async-put! ch5b 45 (lambda (ok) (set! cb5 ok)))
(ok "5b. put! callback ran on the caller with #t" (eq? cb5 #t))
(sa-fiber-run-all)
(ok "5b. fiber got the value" (eq? (jolt-fiber-result f5b) 45))

;; --- 6a. N fiber-takers, M thread-putters: exactly once -----------------------
(printf "\n== 6a. N fiber-takers, M thread-putters: exactly once ==\n")
(define N6 6)
(define M6 6)
(define log6 '())
(define ch6 (jolt-async-chan))
(define fs6
  (spawn-n N6 (lambda (i) (sa-fiber-spawn (lambda () (set! log6 (cons (jolt-fiber-<! ch6) log6)))))))
(sa-fiber-run-all)
(ok "6a. all fiber-takers parked" (all? (lambda (f) (eq? (jolt-fiber-state f) 'parked)) fs6))
(define p6 jolt-fiber-chan-parks)
(define t6-done (make-vector M6 #f))
(spawn-n M6 (lambda (i)
              (fork-thread (lambda ()
                             (jolt-async-give ch6 (+ 100 i))
                             (vector-set! t6-done i #t)))))
(wait-until (lambda () (all-vector? t6-done)) 5.0 "all thread puts delivered")
(run-all-until-all fs6 5.0 "6a. fiber takers finished")
(ok "6a. every value delivered exactly once"
    (equal? (sort (lambda (a b) (< a b)) log6) '(100 101 102 103 104 105)))
(ok "6a. all fiber-takers done" (all-done? fs6))
(ok "6a. no extra captures" (= jolt-fiber-chan-parks p6))

;; --- 6b. N fiber-putters, M thread-takers: exactly once -----------------------
;; Threads block in take (takew); a fiber put either completes immediately
;; against a waiting taker or parks as an alt-putter that a take drains. Either
;; way every value lands in exactly one take.
(printf "\n== 6b. N fiber-putters, M thread-takers: exactly once ==\n")
(define log6b '())
(define t6b-done (make-vector M6 #f))
(define ch6b (jolt-async-chan))
(spawn-n M6 (lambda (i)
              (fork-thread (lambda ()
                             (set! log6b (cons (jolt-async-take ch6b) log6b))
                             (vector-set! t6b-done i #t)))))
(define fs6b
  (spawn-n N6 (lambda (i) (sa-fiber-spawn (lambda () (jolt-fiber->! ch6b (+ 200 i)))))))
(run-all-until-all fs6b 5.0 "6b. fiber putters finished")
(wait-until (lambda () (all-vector? t6b-done)) 5.0 "all thread takes completed")
(ok "6b. every value delivered exactly once"
    (equal? (sort (lambda (a b) (< a b)) log6b) '(200 201 202 203 204 205)))
(ok "6b. all fiber-putters done" (all-done? fs6b))

;; --- 7. a closed channel wakes both kinds of waiter ---------------------------
(printf "\n== 7. closed channel wakes both kinds ==\n")
(define ch7 (jolt-async-chan))
(define f7 (sa-fiber-spawn (lambda () (jolt-fiber-<! ch7))))
(sa-fiber-run-all)
(ok "7. fiber taker parked" (eq? (jolt-fiber-state f7) 'parked))
(jolt-async-close! ch7)
(sa-fiber-run-all)
(ok "7. fiber woke with nil" (eq? (jolt-fiber-result f7) jolt-nil))
(ok "7. fiber done" (eq? (jolt-fiber-state f7) 'done))

(define ch7b (jolt-async-chan))
(define t7-val 'unset)
(fork-thread (lambda () (set! t7-val (jolt-async-take ch7b))))
(wait-until (lambda () (> (async-chan-takew ch7b) 0)) 5.0 "thread blocked in take")
(define f7b (sa-fiber-spawn (lambda () (jolt-async-close! ch7b) 'closed)))
(sa-fiber-run-all)
(wait-until (lambda () (not (eq? t7-val 'unset))) 5.0 "thread woke with nil")
(ok "7b. thread woke with nil" (eq? t7-val jolt-nil))
(ok "7b. closing fiber done" (eq? (jolt-fiber-state f7b) 'done))

;; --- 8. no deadlock: a fiber parks while a sibling on the same carrier puts ---
;; f8a parks as an alt-taker; f8b's >! registers as an alt-putter and the
;; notify pairing step (ac-notify! step 3 -> step 1) completes BOTH without
;; f8b parking. The carrier must not deadlock.
(printf "\n== 8. fiber parks while a sibling on the same carrier puts ==\n")
(define ch8 (jolt-async-chan))
(define f8a (sa-fiber-spawn (lambda () (jolt-fiber-<! ch8))))
(sa-fiber-run-all)
(ok "8. taker parked" (eq? (jolt-fiber-state f8a) 'parked))
(define p8 jolt-fiber-chan-parks)
(define f8b (sa-fiber-spawn (lambda () (jolt-fiber->! ch8 8))))
(sa-fiber-run-all)
(ok "8. putter completed via pairing" (eq? (jolt-fiber-result f8b) #t))
(ok "8. taker got the value" (eq? (jolt-fiber-result f8a) 8))
(ok "8. only the taker parked" (= jolt-fiber-chan-parks p8))
(ok "8. both done" (and (eq? (jolt-fiber-state f8a) 'done) (eq? (jolt-fiber-state f8b) 'done)))

;; --- 9. offer! completes against a parked fiber taker -------------------------
(printf "\n== 9. offer! against a parked fiber taker ==\n")
(define ch9 (jolt-async-chan))
(define f9 (sa-fiber-spawn (lambda () (jolt-fiber-<! ch9))))
(sa-fiber-run-all)
(ok "9. fiber taker parked" (eq? (jolt-fiber-state f9) 'parked))
(define p9 jolt-fiber-chan-parks)
(ok "9. offer! completed" (eq? (jolt-async-offer! ch9 9) #t))
(ok "9. no capture" (= jolt-fiber-chan-parks p9))
(sa-fiber-run-all)
(ok "9. fiber got the value" (eq? (jolt-fiber-result f9) 9))

;; --- 10. stress: a fiber drains a pumping thread, no lost wakeups ------------
;; Bounded: a lost wakeup leaves the fiber parked and the carrier loop times
;; out — a FAIL, never a hang.
(printf "\n== 10. stress: fiber drains a pumping thread ==\n")
(define STRESS-TOTAL 2000)
(define ch10 (jolt-async-chan 16))
(define f10
  (sa-fiber-spawn
    (lambda ()
      (let loop ((n 0))
        (if (fx=? n STRESS-TOTAL)
            'drained
            (begin (jolt-fiber-<! ch10) (loop (fx+ n 1))))))))
(sa-fiber-run-all)
(fork-thread
  (lambda ()
    (let loop ((n 0))
      (when (fx<? n STRESS-TOTAL)
        (jolt-async-give ch10 n)
        (loop (fx+ n 1))))))
(run-all-until f10 15.0 "fiber drained all pumped values")
(ok "10. fiber drained every value" (eq? (jolt-fiber-result f10) 'drained))
(ok "10. fiber done" (eq? (jolt-fiber-state f10) 'done))

;; --- 11. numbers: immediate < parked, both as RATIOS against a call ----------
;; The immediate take must be strictly cheaper than a parked take (which pays
;; everything the immediate does PLUS a context switch), and both must sit
;; within a generous multiple of a bare procedure call. All three are measured
;; in this same process — no absolute ceilings.
(printf "\n== 11. immediate vs parked (ratios vs a bare call) ==\n")
(define CAL-N 2000000)
(define (cal-op x) x)
(define cal-t0 (mono-nanos))
(define cal-sink
  (let loop ((i CAL-N) (acc 0))
    (if (fx>? i 0) (loop (fx- i 1) (cal-op i)) acc)))
(define cal-ns (/ (exact->inexact (- (mono-nanos) cal-t0)) CAL-N))

;; immediate: take from a pre-filled buffered channel (no park, no capture)
(define IMM-N 200000)
(define ch11 (jolt-async-chan IMM-N))
(let loop ((n 0)) (when (fx<? n IMM-N) (jolt-async-give ch11 1) (loop (fx+ n 1))))
(define imm-t0 (mono-nanos))
(define imm-sink
  (let loop ((n 0))
    (if (fx<? n IMM-N)
        (begin (jolt-fiber-<! ch11) (loop (fx+ n 1)))
        0)))
(define imm-ns (/ (exact->inexact (- (mono-nanos) imm-t0)) IMM-N))

;; parked: fibers each take one value from an empty channel, woken by a pump
(define PARK-N 2000)
(define ch11p (jolt-async-chan))
(define park-fibs
  (spawn-n PARK-N (lambda (_) (sa-fiber-spawn (lambda () (jolt-fiber-<! ch11p))))))
(sa-fiber-run-all)
(define park-t0 (mono-nanos))
(fork-thread
  (lambda ()
    (let loop ((n 0)) (when (fx<? n PARK-N) (jolt-async-give ch11p n) (loop (fx+ n 1))))))
(run-all-until (list-ref park-fibs (fx- PARK-N 1)) 15.0 "parked takes completed")
(define park-ns (/ (exact->inexact (- (mono-nanos) park-t0)) PARK-N))
(ok "11. calibration loop ran" (fx>=? cal-sink 0))
(ok "11. immediate sink ran" (fx>=? imm-sink 0))
(printf "  immediate take: ~a ns  (bare call ~a ns; ratio ~a, assert < 200x)\n"
        imm-ns cal-ns (/ imm-ns (max 0.2 cal-ns)))
(printf "  parked take:    ~a ns  (ratio ~a; assert immediate < parked)\n"
        park-ns (/ park-ns (max 0.2 cal-ns)))
(ok "11. immediate within 200x a bare call" (< (/ imm-ns (max 0.2 cal-ns)) 200.0))
(ok "11. immediate strictly cheaper than parked" (< imm-ns park-ns))

(printf "\nfibers-chan-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-chan-test: PASS — one waiter protocol, threads and fibers\n") (exit 0))
    (exit 1))
