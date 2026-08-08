;; test/chez/fibers-pool-test.ss — R5 gate: the carrier pool + the blocking
;; policy (epic jolt-nvpr.6). Run: chez --script test/chez/fibers-pool-test.ss
;; (wired into `make fibers` after the R4 go gate).
;;
;; R5 (fibers-r5-carriers.md) delivers two things:
;;   1. N carriers — OS threads, each running R4's loop shape (drain its run
;;      queue, park on its condition when empty, check+wait under one mutex) —
;;      started lazily at the first :fiber go spawn. N defaults to the
;;      machine's processor count and is overridable by a var
;;      (clojure.core.async/*fiber-carrier-count*), read once at pool start;
;;      the host setter jolt-fiber-carrier-count-set! (writes the var root) is
;;      what this gate uses. Fibers NEVER migrate (R0(d)): placement is
;;      round-robin at spawn, there is no work stealing, and growing the pool
;;      does not rescue fibers stranded behind a blocked carrier — that is
;;      documented where the pool is sized (fibers.ss), and gate 6 asserts the
;;      pinning behavior itself.
;;   2. The blocking policy: on a fiber, <!! and >!! park the fiber exactly as
;;      <! and >! do (on a fiber there is no difference); off a fiber they keep
;;      today's blocking ops, byte for byte.
;;
;; Gate checks (spec, in order):
;;   1. parallelism: M CPU-bound fibers over N carriers finish faster than the
;;      same M on one carrier — a RATIO measured within this one process.
;;      Timing is never asserted as an absolute duration; the two halves are
;;      measured back-to-back in the same run, so a slow or busy runner slows
;;      both and the ratio survives (see the flake history note at the top of
;;      fibers-test.ss — two absolute ceilings already shipped CI flakes).
;;   2. round-robin placement: fiber i lands on carrier (i mod N) — the
;;      distribution, not timing.
;;   3. <!! on a fiber PARKS: a sibling on the SAME carrier progresses while
;;      the first is blocked in <!! (fails if <!! blocks the carrier — the
;;      pre-change behavior; the gate is red without the policy, section 3).
;;   4. <!! / >!! off a fiber are unchanged: the same blocking semantics on a
;;      plain OS thread.
;;   5. two carriers mid-park simultaneously, each inside a try/finally, each
;;      finally running exactly once at the real exit — the check that
;;      justifies R4 keeping the park-unwinding flag in a virtual register
;;      (per thread) instead of a global (shared across carriers).
;;   6. a fiber that blocks its carrier by other means (a plain Thread/sleep)
;;      does NOT stop other carriers, and its own carrier's queued fibers DO
;;      wait — the documented pinning behavior.
;;
;; The gate mutates the pool size between sections via
;; jolt-fiber-carrier-count-set! + jolt-fiber-pool-reset! (stop threads, drop
;; the pool); each section pins what it needs before its first go/spawn.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

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

;; Bounded wait: a bug must FAIL the gate, never hang it.
(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (if (pred)
          #t
          (if (> (now-secs) deadline)
              (begin (set! fails (+ fails 1))
                     (printf "  FAIL: ~a (timed out)\n" what) #f)
              (begin (sleep (make-time 'time-duration 1000000 0)) (loop)))))))

;; Compile+eval one jolt form in the "user" ns and return its value.
(define (ev s) (jolt-compile-eval s "user"))
(define (jv-nth v i) (pvec-nth-d v i jolt-nil))
(define (jv-index-of v x)
  (let ((n (pvec-count v)))
    (let loop ((i 0))
      (cond ((fx=? i n) #f)
            ((jolt=2 (pvec-nth-d v i jolt-nil) x) i)
            (else (loop (fx+ i 1)))))))

(define (all-done? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'done) (all-done? (cdr fs)))))
(define (spawn-n n mk)
  (let loop ((i 0) (acc '()))
    (if (fx<? i n)
        (loop (fx+ i 1) (cons (mk i) acc))
        (reverse acc))))

;; Load the real async overlay up front, exactly as the production loader does
;; (host async.ss + stdlib/clojure/core/async.clj together), then refer the
;; names the gate uses — the same setup the R4 go gate uses.
(define overlay-src
  (call-with-input-file "stdlib/clojure/core/async.clj"
    (lambda (p)
      (let loop ((acc '()))
        (let ((c (read-char p)))
          (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc))))))))
(jolt-load-string overlay-src)
(ev "(require '[clojure.core.async
                :refer [go chan <! <!! >!! *go-backend*]])")

;; --- 1. parallelism: N carriers beat one carrier (a ratio, one run) ----------
;; M CPU-bound fibers (pure fixnum work, no allocation, no parks) are placed
;; round-robin over the pool; with one carrier they serialize. Both halves are
;; timed in THIS process back-to-back, so the assertion is the ratio T1/T2 —
;; immune to how fast or busy the runner is (per the flake history in
;; fibers-test.ss, absolute ceilings are the CI-flake trap).
(printf "\n== 1. N carriers beat one carrier (ratio within one run) ==\n")
(define (cpu-bound-fiber n)
  (lambda ()
    (let loop ((i 0) (acc 0))
      (if (fx<? i n) (loop (fx+ i 1) (fx+ acc i)) acc))))
(define (run-cpu-batch m iters)
  (let ((t0 (mono-nanos)))
    (define fs (spawn-n m (lambda (i) (sa-fiber-spawn (cpu-bound-fiber iters)))))
    (wait-until (lambda () (all-done? fs)) 60.0 "cpu-bound batch finished")
    (/ (exact->inexact (- (mono-nanos) t0)) 1000000.0)))  ;; ms

(jolt-fiber-carrier-count-set! #f)          ;; restore the machine default
(jolt-fiber-pool-reset!)
(define n-pool (jolt-fiber-carrier-count))
(define m-batch (fx* 2 n-pool))
(define iters 20000000)

(if (fx=? n-pool 1)
    (begin
      (printf "  1 logical CPU — no parallelism to measure; skipping check 1\n")
      (ok "1. pool beats one carrier (skipped on a 1-CPU machine)" #t))
    (begin
      ;; single-carrier baseline: pin to 1, start the pool, time M fibers
      (jolt-fiber-carrier-count-set! 1)
      (jolt-fiber-pool-reset!)
      (jolt-fiber-ensure-carrier!)
      (let* ((t1 (run-cpu-batch m-batch iters))
             ;; the pool at the machine default: same M fibers, N carriers
             (t2 (begin (jolt-fiber-carrier-count-set! n-pool)
                        (jolt-fiber-pool-reset!)
                        (jolt-fiber-ensure-carrier!)
                        (run-cpu-batch m-batch iters)))
             (speedup (/ (max t1 0.001) (max t2 0.001))))
        (printf "  1 carrier: ~,2f ms; ~a carriers: ~,2f ms; speedup ~,2f\n"
                t1 n-pool t2 speedup)
        (ok "1. pool beats one carrier (speedup > 1.25)" (> speedup 1.25)))))

;; --- 2. round-robin placement ------------------------------------------------
;; Spawning K fibers over N carriers puts fiber i on carrier (i mod N) — the
;; distribution, asserted structurally (no timing). The carrier field is fixed
;; at spawn (R0(d)) and never cleared, so reading it after the fiber ran is
;; race-free.
(printf "\n== 2. round-robin placement ==\n")
(jolt-fiber-carrier-count-set! 4)
(jolt-fiber-pool-reset!)
(jolt-fiber-ensure-carrier!)
(define rr-fs (spawn-n 8 (lambda (i) (sa-fiber-spawn (lambda () #t)))))
(ok "2. fiber i is on carrier (i mod 4)"
    (let loop ((i 0))
      (or (fx=? i 8)
          (and (eq? (jolt-fiber-carrier (list-ref rr-fs i))
                    (vector-ref jolt-fiber-carriers (mod i 4)))
               (loop (fx+ i 1))))))
(ok "2. the first 4 spawns are on 4 distinct carriers"
    (let ((a (jolt-fiber-carrier (list-ref rr-fs 0)))
          (b (jolt-fiber-carrier (list-ref rr-fs 1)))
          (c (jolt-fiber-carrier (list-ref rr-fs 2)))
          (d (jolt-fiber-carrier (list-ref rr-fs 3))))
      (and (not (eq? a b)) (not (eq? a c)) (not (eq? a d))
           (not (eq? b c)) (not (eq? b d)) (not (eq? c d)))))
(wait-until (lambda () (all-done? rr-fs)) 10.0 "placement fibers completed")

;; --- 3. <!! on a fiber parks ------------------------------------------------
;; The load-bearing check: pin the pool to 1 so both go bodies land on the
;; SAME carrier. a does <!! on an empty channel; with the R5 policy it PARKS
;; and the sibling b runs its 2000 ticks to completion on the same carrier
;; meanwhile. Without the policy, <!! blocks the carrier (condition-wait on
;; the carrier thread), b never runs, and tick stays 0 — this section goes
;; red. The give after the snapshot always runs, so a pre-change failure
;; cannot hang the gate.
(printf "\n== 3. <!! on a fiber parks ==\n")
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-pool-reset!)
(define r3 (ev "
(binding [*go-backend* :fiber]
  (let [c (chan)
        tick (atom 0)
        a (go (<!! c))
        b (go (dotimes [_ 2000] (swap! tick inc)))]
    (Thread/sleep 250)
    (let [n @tick]
      (>!! c :go)                    ;; unblock a whatever the outcome
      [n (<!! a) @tick])))"))
(ok "3. a sibling on the same carrier ran while the other was parked in <!!"
    (= (jv-nth r3 0) 2000))
(ok "3. <!! on a fiber returned the value" (jolt=2 (jv-nth r3 1) (keyword #f "go")))
(ok "3. the sibling completed" (= (jv-nth r3 2) 2000))

;; --- 4. <!! / >!! off a fiber are unchanged ----------------------------------
;; The dispatch (fibers-async.ss) is `(if (jolt-current-fiber) <fiber path>
;; <thread path>)`; off a fiber the thread path is byte-for-byte today's
;; blocking ops. A full buffer blocks the putter until a taker drains it — the
;; pre-R5 behavior, on a plain OS thread, with the same values and order.
(printf "\n== 4. <!! / >!! off a fiber are unchanged ==\n")
(define c4 (jolt-async-chan 1))
(jolt-async-give c4 11)                 ;; pre-fill: the buffer is now full
(define put4 (vector #f #f))            ;; [done? returned-value]
(fork-thread
 (lambda ()
   (vector-set! put4 1 (if (jolt-async-give c4 22) #t #f))
   (vector-set! put4 0 #t)))
(sleep (make-time 'time-duration 200000000 0))  ;; let the worker reach the give
(ok "4. >!! on a full buffer blocks the thread" (not (vector-ref put4 0)))
(define a4 (jolt-async-take c4))        ;; unblocks the worker
(define b4 (jolt-async-take c4))
(wait-until (lambda () (vector-ref put4 0)) 10.0 "4. worker completed after the take")
(ok "4. <!! off a fiber: both values, in order" (and (eqv? a4 11) (eqv? b4 22)))
(ok "4. >!! off a fiber returned true" (eq? (vector-ref put4 1) #t))

;; --- 5. two carriers mid-park, each try/finally runs exactly once ------------
;; RR at N=2 puts g1 on carrier 0 and g2 on carrier 1; both park inside a
;; try/finally, so both carriers are mid-park simultaneously. The finally must
;; NOT run at the park, and must run exactly once at the real exit — if the
;; park-unwinding flag were a global (shared across carriers) instead of the
;; per-thread vreg R4 chose, one carrier's park could clear the other's flag
;; mid-escape and its finally would fire at the park (or be lost at the exit).
;; Two separate logs keep the assertion free of ordering races between the
;; carriers.
(printf "\n== 5. two carriers mid-park, try/finally exactly once each ==\n")
(jolt-fiber-carrier-count-set! 2)
(jolt-fiber-pool-reset!)
(define r5 (ev "
(binding [*go-backend* :fiber]
  (let [c1 (chan) c2 (chan)
        l1 (atom []) l2 (atom [])
        g1 (go (try (let [v (<! c1)] v) (finally (swap! l1 conj :f1))))
        g2 (go (try (let [v (<! c2)] v) (finally (swap! l2 conj :f2))))]
    (Thread/sleep 300)                  ;; both fibers parked by now
    (let [p1 (count @l1) p2 (count @l2)]
      (>!! c1 :one) (>!! c2 :two)
      (let [r1 (<!! g1) r2 (<!! g2)]
        [p1 p2 r1 r2 @l1 @l2]))))"))
(ok "5. neither finally ran at the park (both carriers mid-park)"
    (and (= (jv-nth r5 0) 0) (= (jv-nth r5 1) 0)))
(ok "5. fiber 1 resumed with its value" (jolt=2 (jv-nth r5 2) (keyword #f "one")))
(ok "5. fiber 2 resumed with its value" (jolt=2 (jv-nth r5 3) (keyword #f "two")))
(ok "5. finally 1 ran exactly once" (jolt=2 (jv-nth r5 4) (jolt-vector (keyword #f "f1"))))
(ok "5. finally 2 ran exactly once" (jolt=2 (jv-nth r5 5) (jolt-vector (keyword #f "f2"))))

;; --- 6. a fiber that blocks its carrier (Thread/sleep) -----------------------
;; RR at N=2: a lands on carrier 0, b on carrier 1, c back on carrier 0 (queued
;; behind a). a sleeps 1500 ms — blocking its OS thread — so b (other carrier)
;; finishes long before a wakes, and c (same carrier, queued) finishes only
;; after. Assert the ORDER in the shared log, which is causal and free of
;; absolute timing: b before a, a before c. The bounded wait inside the body
;; (max 7 s) fails the section cleanly if a fiber never completes.
(printf "\n== 6. a fiber that blocks its carrier (Thread/sleep) ==\n")
(jolt-fiber-carrier-count-set! 2)
(jolt-fiber-pool-reset!)
(define r6 (ev "
(binding [*go-backend* :fiber]
  (let [log (atom [])
        a (go (Thread/sleep 1500) (swap! log conj :awake))
        b (go (swap! log conj :bdone))
        c (go (swap! log conj :cdone))]
    (loop [n 0]
      (when (and (< n 700) (< (count @log) 3))
        (Thread/sleep 10) (recur (inc n))))
    @log))"))
(define ib6 (jv-index-of r6 (keyword #f "bdone")))
(define ia6 (jv-index-of r6 (keyword #f "awake")))
(define ic6 (jv-index-of r6 (keyword #f "cdone")))
(ok "6. the other carrier kept working (b done before a woke)"
    (and ib6 ia6 (< ib6 ia6)))
(ok "6. the blocked carrier's queued fibers wait (c after a woke)"
    (and ia6 ic6 (< ia6 ic6)))

(printf "\nfibers-pool: ~a checks, ~a failures\n" total fails)
(exit (if (zero? fails) 0 1))
