;; test/chez/fibers-test.ss — R1 gate for the fiber primitive + single-carrier
;; scheduler (epic jolt-nvpr.2). Run: chez --script test/chez/fibers-test.ss
;; (wired in as `make fibers`; detection-free, no jolt boot needed).
;;
;; Correctness: spawn/yield/resume round trip; a fiber that finishes; a fiber
;; that raises with the scheduler surviving and the other fibers still running;
;; N fibers round-robin in order; a fiber yielding from 40 frames down.
;;
;; Numbers as assertions with generous ceilings (pinned by R0's findings):
;;   spawn  < 5us     (measured 0.84us)
;;   switch < 100ns   (measured 12.5ns bare)
;;   per-fiber live < 8KB (measured ~3.5KB)
;; Memory is measured the R0-corrected way: retain the fibers in a global,
;; force (collect (collect-maximum-generation)), read ABSOLUTE live bytes.
;; Per-phase bytes-allocated deltas produced both of R0's wrong findings and
;; are never used here. The switch bench raises the GC trip threshold for the
;; timed region so segment churn (3.5KB per park) does not pollute the number.

(import (chezscheme))
(load "host/chez/fibers.ss")

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

(define (all-done? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'done) (all-done? (cdr fs)))))
(define (all? pred ls)
  (or (null? ls) (and (pred (car ls)) (all? pred (cdr ls)))))
;; spawn N fibers via (mk i) for i = 0..N-1, IN THAT ORDER, returning them in
;; order (an explicit loop, so the enqueue order is unambiguous).
(define (spawn-n n mk)
  (let loop ((i 0) (acc '()))
    (if (fx<? i n)
        (loop (fx+ i 1) (cons (mk i) acc))
        (reverse acc))))

(printf "== correctness ==\n")

;; 1. spawn/yield/resume round trip: 'a before the yield, 'b after it
(define rt-log '())
(define rt-f
  (sa-fiber-spawn
    (lambda ()
      (set! rt-log (cons 'a rt-log))
      (sa-fiber-yield)
      (set! rt-log (cons 'b rt-log))
      'rt-done)))
(sa-fiber-run-all)
(ok "round trip: body order" (equal? rt-log '(b a)))
(ok "round trip: fiber done" (eq? (jolt-fiber-state rt-f) 'done))
(ok "round trip: result captured" (eq? (jolt-fiber-result rt-f) 'rt-done))

;; 2. a fiber that finishes without ever yielding
(define done-f (sa-fiber-spawn (lambda () 42)))
(sa-fiber-run-all)
(ok "finish: state done" (eq? (jolt-fiber-state done-f) 'done))
(ok "finish: result" (eq? (jolt-fiber-result done-f) 42))

;; 3. a fiber that raises: the scheduler survives, the others still run, and
;; the error is recorded on the dead fiber
(define raise-log '())
(define raise-fibers
  (spawn-n 6
    (lambda (i)
      (sa-fiber-spawn
        (lambda ()
          (when (fx=? i 2)
            (raise (condition (make-message-condition "boom"))))
          (set! raise-log (cons i raise-log)))))))
(sa-fiber-run-all)
(ok "raise: did not propagate to the caller" #t)
(ok "raise: non-raising fibers ran" (= (length raise-log) 5))
(ok "raise: raising fiber is dead"
    (eq? (jolt-fiber-state (list-ref raise-fibers 2)) 'dead))
(ok "raise: condition recorded"
    (string=? "boom"
              (condition-message (jolt-fiber-error (list-ref raise-fibers 2)))))
(define after-f (sa-fiber-spawn (lambda () 'ok)))
(sa-fiber-run-all)
(ok "raise: scheduler reusable after a dead fiber"
    (eq? (jolt-fiber-result after-f) 'ok))

;; 4. a raise AFTER a park: the resume-path guard must ride the continuation
(define parked-raise-f
  (sa-fiber-spawn (lambda () (sa-fiber-yield) (error 'fiber "late boom"))))
(sa-fiber-run-all)
(ok "raise after park: fiber dead" (eq? (jolt-fiber-state parked-raise-f) 'dead))

;; 5. N fibers round-robin in strict order
(define N 8)
(define M 6)
(define rr-log '())
(define rr-fibers
  (spawn-n N
    (lambda (i)
      (sa-fiber-spawn
        (lambda ()
          (let loop ((m M))
            (when (fx>? m 0)
              (set! rr-log (append rr-log (list i)))
              (sa-fiber-yield)
              (loop (fx- m 1)))))))))
(sa-fiber-run-all)
(ok "round-robin: strict rotation"
    (let loop ((k 0))
      (or (fx>=? k (fx* N M))
          (and (fx=? (list-ref rr-log k) (mod k N)) (loop (fx+ k 1))))))
(ok "round-robin: all fibers done" (all-done? rr-fibers))

;; 6. a fiber yielding from 40 frames down resumes correctly
(define (deep-yield n)
  (if (fx=? n 0) (sa-fiber-yield) (deep-yield (fx- n 1))))
(define deep-finished #f)
(define deep-f
  (sa-fiber-spawn (lambda () (deep-yield 40) (set! deep-finished #t) 'deep-ok)))
(sa-fiber-run-all)
(ok "deep yield: resumed correctly" deep-finished)
(ok "deep yield: result" (eq? (jolt-fiber-result deep-f) 'deep-ok))

;; 7. sa-fiber-resume: a fiber parked without self-enqueue wakes on resume; a
;; double wakeup is a no-op (state 'ready -> skip, the queue stays intact)
(define wake-f
  (sa-fiber-spawn (lambda () (jolt-fiber-park!) 'woke)))
(sa-fiber-run-all)
(ok "resume: parked after the drain" (eq? (jolt-fiber-state wake-f) 'parked))
(sa-fiber-resume wake-f)
(ok "resume: runnable after resume" (eq? (jolt-fiber-state wake-f) 'ready))
(sa-fiber-resume wake-f)
(ok "resume: double wakeup is a no-op" (eq? (jolt-fiber-state wake-f) 'ready))
(sa-fiber-run-all)
(ok "resume: completed" (eq? (jolt-fiber-result wake-f) 'woke))

;; 8. yield outside a fiber is a clean error (the vreg is the dispatcher)
(ok "yield outside a fiber raises"
    (guard (e (#t (string=? (condition-message e) "yield called outside a fiber")))
      (sa-fiber-yield)
      #f))

;; 9. nested spawn: spawning a fiber from inside a fiber is legal
(define inner-result #f)
(define outer-f
  (sa-fiber-spawn
    (lambda ()
      (define inner (sa-fiber-spawn (lambda () 'inner-done)))
      (sa-fiber-yield)
      (set! inner-result (jolt-fiber-result inner)))))
(sa-fiber-run-all)
(ok "nested spawn: inner fiber done" (eq? inner-result 'inner-done))
(ok "nested spawn: outer fiber done" (eq? (jolt-fiber-state outer-f) 'done))

(printf "\n== numbers (generous ceilings) ==\n")

;; --- spawn: per-spawn < 5us (measured 0.84us) --------------------------------
(define SPAWN-N 200000)
(define spawn-t0 (mono-nanos))
(define spawn-fibs
  (let loop ((i 0) (acc '()))
    (if (fx<? i SPAWN-N)
        (loop (fx+ i 1) (cons (sa-fiber-spawn (lambda () #f)) acc))
        acc)))
(define spawn-us
  (/ (exact->inexact (- (mono-nanos) spawn-t0)) 1000.0 SPAWN-N))
(printf "  spawn:  ~a us/fiber (assert < 5us) -- record+enqueue only; the body\n" spawn-us)
(printf "          has not run, so the continuation capture and about 3.5\n")
(printf "          KB segment is NOT in this number (first park pays those)\n")
(ok "spawn < 5us" (< spawn-us 5.0))
;; the spawned-but-never-run fibers complete immediately; drain the queue
(sa-fiber-run-all)

;; --- switch: per switch < 100ns (measured 12.5ns bare) ------------------------
;; N fibers round-robin, each yielding M times: every park costs one switch out
;; and one switch in, so switches = 2*N*M. The trip threshold is raised for the
;; timed region so the ~3.5KB per captured segment does not trigger GC mid-run.
;; Warm up the machinery first, then settle the nursery with a full collect.
(define SW-N 32)
(define SW-M 500)
(define (sw-bench-n)
  (define fibers
    (spawn-n SW-N
      (lambda (i)
        (sa-fiber-spawn
          (lambda ()
            (let loop ((m SW-M))
              (when (fx>? m 0)
                (sa-fiber-yield)
                (loop (fx- m 1)))))))))
  (sa-fiber-run-all)
  (all-done? fibers))
(ok "switch: warmup run" (sw-bench-n))
(define old-trip (collect-trip-bytes))
(collect-trip-bytes 100000000000)          ; no gen-0 during the timed region
(collect (collect-maximum-generation))
(define sw-t0 (mono-nanos))
(ok "switch: timed run" (sw-bench-n))
(define switch-ns
  (/ (exact->inexact (- (mono-nanos) sw-t0)) (* 2.0 SW-N SW-M)))
(collect-trip-bytes old-trip)

;; The assertion is a RATIO against a calibration loop measured in this same
;; process, not an absolute nanosecond ceiling. An absolute one is a flake: this
;; switch measured 53 ns on a dev machine and 124 ns on a shared CI runner, so a
;; 100 ns ceiling failed CI while the code was fine. A ratio scales with the
;; machine — both the baseline and the switch slow down together — so it still
;; catches a real regression (a switch that starts copying stacks, or a slice
;; swap that regresses to thread parameters at 33 ns per write) without
;; measuring the runner's mood.
(define CAL-N 2000000)
(define (cal-op x) x)                       ; a bare procedure call
(define cal-t0 (mono-nanos))
(define cal-sink
  (let loop ((i CAL-N) (acc 0))
    (if (fx>? i 0) (loop (fx- i 1) (cal-op i)) acc)))
(define cal-ns (/ (exact->inexact (- (mono-nanos) cal-t0)) CAL-N))
(define switch-ratio (/ switch-ns (max 0.2 cal-ns)))
(printf "  switch: ~a ns/switch  (bare call ~a ns; ratio ~a, assert < 60x)\n"
        switch-ns cal-ns switch-ratio)
(ok "switch within 60x a bare procedure call" (< switch-ratio 60.0))
(ok "calibration loop ran" (fx>=? cal-sink 0))

;; --- per-fiber memory: < 8KB, absolute-live-bytes method ----------------------
;; R0's corrected measurement: retain the parked fibers in a global, force a
;; maximum-generation collect, and read ABSOLUTE live bytes before and after.
;; Per-phase bytes-allocated deltas (which produced both of R0's wrong
;; findings) are never used.
(define MEM-N 20000)
(define mem-held '())
(define mem-baseline (begin (collect (collect-maximum-generation)) (bytes-allocated)))
(define (make-mem-fibers)
  (let loop ((i 0) (acc '()))
    (if (fx<? i MEM-N)
        (loop (fx+ i 1)
              (cons (sa-fiber-spawn (lambda () (jolt-fiber-park!) 'x)) acc))
        acc)))
(set! mem-held (make-mem-fibers))
(sa-fiber-run-all)     ; every fiber runs once and parks (no self-enqueue)
(collect (collect-maximum-generation))
(define per-fiber-bytes
  (exact->inexact (/ (max 0 (- (bytes-allocated) mem-baseline)) MEM-N)))
(ok "memory: all parked" (all? (lambda (f) (eq? (jolt-fiber-state f) 'parked)) mem-held))
(printf "  per-fiber: ~a bytes live (assert < 8192)\n" per-fiber-bytes)
(ok "per-fiber live < 8KB" (< per-fiber-bytes 8192))

(printf "\nfibers-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-test: PASS — fiber primitive + scheduler\n") (exit 0))
    (exit 1))
