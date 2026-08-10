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
;;   switch: depth-independent (40 frames within 3x of 1) — the property,
;;            not the speed; two absolute forms flaked on CI, see below
;;   per-fiber live < 8KB (measured ~3.5KB)
;; Memory is measured the R0-corrected way: retain the fibers in a global,
;; force (collect (collect-maximum-generation)), read ABSOLUTE live bytes.
;; Per-phase bytes-allocated deltas produced both of R0's wrong findings and
;; are never used here. The switch bench raises the GC trip threshold for the
;; timed region so segment churn (3.5KB per park) does not pollute the number.

(import (chezscheme))
(load "host/chez/locks.ss")   ; fibers.ss locks through it; jolt-with-mutex is a macro
(load "host/chez/fibers.ss")
;; R5 (jolt-nvpr.6): fibers now live on a POOL of N carriers (N defaults to
;; the processor count). This gate drives the scheduler SYNCHRONOUSLY with
;; sa-fiber-run-all on one carrier, so it pins the pool to exactly one — the
;; documented "pin it to 1 for determinism" use of the count knob.
(jolt-fiber-carrier-count-set! 1)

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

;; --- switch: depth-independence (the property, not the speed) -----------------
;; N fibers round-robin, each yielding M times: every park costs one switch out
;; and one switch in, so switches = 2*N*M. The trip threshold is raised for the
;; timed region so the ~3.5KB per captured segment does not trigger GC mid-run.
;; Warm up the machinery first, then settle the nursery with a full collect.
(define SW-N 32)
(define SW-M 500)
(define (sw-yield-at-depth d)                ; yield d frames down
  (if (fx=? d 0) (sa-fiber-yield) (begin (sw-yield-at-depth (fx- d 1)) (void))))
(define (sw-bench-n) (sw-bench-depth 0))
(define (sw-bench-depth depth)
  (define fibers
    (spawn-n SW-N
      (lambda (i)
        (sa-fiber-spawn
          (lambda ()
            (let loop ((m SW-M))
              (when (fx>? m 0)
                (sw-yield-at-depth depth)
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

;; What is asserted here is the PROPERTY, not the speed: a continuation capture
;; on Chez is O(1), so yielding 40 frames down must cost the same as yielding 1
;; frame down. Both halves are measured in this same process on this same
;; machine, so the comparison is immune to how fast or busy the runner is.
;;
;; Two absolute forms were tried and both were flakes. A 100ns ceiling passed
;; locally at 53ns and failed CI at 124ns. A ratio against a bare-procedure-call
;; calibration then failed CI at 73x against a 60x ceiling — because a tight loop
;; calling a trivial procedure is cache-resident and does NOT slow down on a
;; shared runner (2.14ns on CI vs 2.39ns locally) while continuation capture
;; allocates and touches memory and does (157ns vs 53ns). Wrong proxy: the
;; calibration has to share the workload's characteristics, and nothing simple
;; does. Depth-independence needs no proxy.
;;
;; This still catches the regression that matters — a capture that starts copying
;; the stack becomes O(depth) and the ratio explodes. The absolutes are printed
;; for the record and asserted only against a ceiling loose enough to be
;; meaningless as noise (a 20x blowup, not a 2x one).
(define old-trip (collect-trip-bytes))
(collect-trip-bytes 100000000000)          ; no gen-0 during the timed region
(collect (collect-maximum-generation))
(define sw-t0 (mono-nanos))
(ok "switch: timed run (1 frame)" (sw-bench-depth 0))
(define switch-ns
  (/ (exact->inexact (- (mono-nanos) sw-t0)) (* 2.0 SW-N SW-M)))
(collect (collect-maximum-generation))
(define deep-t0 (mono-nanos))
(ok "switch: timed run (40 frames)" (sw-bench-depth 40))
(define deep-switch-ns
  (/ (exact->inexact (- (mono-nanos) deep-t0)) (* 2.0 SW-N SW-M)))
(collect-trip-bytes old-trip)
(define depth-ratio (/ deep-switch-ns (max 1.0 switch-ns)))
(printf "  switch: ~a ns at 1 frame, ~a ns at 40 frames (depth ratio ~a)\n"
        switch-ns deep-switch-ns depth-ratio)
(ok "capture is depth-independent (40 frames within 3x of 1)" (< depth-ratio 3.0))
(ok "switch not catastrophically slow (< 5us)" (< switch-ns 5000.0))

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

;; --- what this gate does NOT cover, asserted so it cannot be misread ---------
;; This file loads fibers.ss ON ITS OWN, with no adapter and no value layer, to
;; keep that file honestly self-contained. The consequence is easy to forget:
;; every adapter-backed feature in it is captured by guarded reference and
;; DEGRADES TO A NO-OP here. So a pass from this gate says nothing whatever
;; about the winder-drop path — jolt-park-drop-finallys! does not do anything in
;; this process, and could be arbitrarily broken without a single check moving.
;;
;; That is not hypothetical. A stack-truncation attempt (jolt-atc.3) was wrong
;; enough to kill every fiber under the full boot and this gate passed clean,
;; because the primitive it needed was absent and the call degraded to nothing.
;;
;; So the degradation is asserted rather than assumed. Two things follow: the
;; no-op path stays deliberately exercised (a target without these primitives
;; must still run fibers), and if fibers.ss ever gains a HARD dependency on the
;; adapter these checks fail loudly instead of the gate quietly covering less
;; than it appears to.
;;
;; The real coverage for this path is fibers-state-test.ss section 7, which
;; loads rt.ss and asserts the behaviour (a finally skipped on a park, a
;; with-mutex released, a parameterize unwound). Mutation-checked: disabling the
;; predicate there fails 4 of its checks.
(ok "degradation: no marker without the value layer" (not jolt-finally-marker))
(ok "degradation: no winder rtd without the adapter" (not jolt-winder-rtd))
(ok "degradation: the chain reader answers empty" (null? (jolt-sa-winders)))
(ok "degradation: dropping finallys is inert here, and does not raise"
    (begin (jolt-park-drop-finallys!) #t))
;; A fiber still has to run and park with the whole mechanism absent — that is
;; the portability claim the fallbacks exist to make.
(define degr-f (sa-fiber-spawn (lambda () (sa-fiber-yield) 'ok)))
(sa-fiber-run-all)
(ok "degradation: a fiber still completes with no winder support"
    (eq? 'done (jolt-fiber-state degr-f)))

(printf "\nfibers-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-test: PASS — fiber primitive + scheduler\n") (exit 0))
    (exit 1))
