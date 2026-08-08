;; bench/fibers/bench-fibers.ss — Fibers R6 measurement harness (jolt-nvpr.7).
;;
;; One phase per invocation:  chez --script bench/fibers/bench-fibers.ss <phase> [arg]
;; Run the full set (and get the comparison table) via bench/fibers/run.sh,
;; wired in as `make fibersbench`. Opt-in; NOT part of make test / make ci.
;;
;; Every memory and per-switch figure is produced the R0-corrected way: objects
;; RETAINED in a global, a forced (collect (collect-maximum-generation)),
;; ABSOLUTE live bytes, cross-checked against peak RSS from /usr/bin/time -l
;; (the run.sh wrapper). Per-phase bytes-allocated deltas on unretained objects
;; are never used — that method produced two wrong findings earlier in this
;; epic (fibers-r0-findings.md, CORRECTIONS).
;;
;; The :thread backend here is today's go = one OS thread per go block
;; (async-go-spawn-thread); :fiber is the fiber backend (jolt-fiber-go-spawn /
;; sa-fiber-spawn). Both are exactly what the `go` macro dispatches to at
;; runtime, called at the host level so the timed region measures the runtime,
;; not compile-eval.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(printf "bench: chez ~a threaded ~a cpus ~a\n"
        (scheme-version) (threaded?) (guard (e (#t 1)) (jolt-available-processors)))
(flush-output-port (current-output-port))

(define argv (command-line))
(define (a i) (and (fx<? i (length argv)) (list-ref argv i)))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))

;; Bounded wait: a bug must print a TIMEOUT, never hang the phase.
(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((pred) #t)
            ((> (now-secs) deadline)
             (printf "  TIMEOUT waiting for ~a (~a s)\n" what secs) #f)
            (else (sleep (make-time 'time-duration 1000000 0)) (loop))))))

(define (spawn-n n mk)
  (let loop ((i 0) (acc '()))
    (if (fx<? i n) (loop (fx+ i 1) (cons (mk i) acc)) (reverse acc))))

(define (all-done? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'done) (all-done? (cdr fs)))))

(define (flush!) (flush-output-port (current-output-port)))

;; --- 1. spawn cost -----------------------------------------------------------
;; K processes that immediately park, one K per process (so a failed run cannot
;; contaminate the next K with its leftover blocked threads). The thread body
;; blocks on a shared empty channel take — the go/thread park. The fiber body
;; parks at the primitive (the R1 shape the plan's 0.84us spawn number came
;; from); the go-fiber body parks on a fresh channel (the go path, minus the
;; O(K^2) shared-channel waiter registration that would pollute a spawn number
;; with channel cost — that cost is a property of the channel, not the spawn).
;; Pool (fiber backends): started before the timed region — a real process pays
;; the one-time carrier start once.
(define (spawn-phase backend k)
  (define parked-mu (make-mutex))
  (define parked 0)
  (define park-ch (jolt-async-chan 0))
  (define t0 0) (define t1 0) (define t2 0)
  (define created 0)
  (define fail-msg #f)
  (define got-all #f)
  (define (bump-parked!)
    (mutex-acquire parked-mu)
    (set! parked (+ parked 1))
    (mutex-release parked-mu))
  (define (spawn-one)
    (case backend
      ((thread)
       (async-go-spawn-thread
        (lambda () (bump-parked!) (jolt-async-take park-ch))))
      ((fiber)
       (sa-fiber-spawn (lambda () (bump-parked!) (jolt-fiber-park!) 'x)))
      ((fiber-go)
       (jolt-fiber-go-spawn
        (lambda () (bump-parked!) (jolt-fiber-<! (jolt-async-chan 0)))))
      (else (error 'spawn-phase "bad backend" backend))))
  ;; Pool (fiber backends): start BEFORE the timed region, then let the fresh
  ;; carrier threads reach their first safepoint (condition-wait) before the
  ;; baseline collect — a collect in the fork window races "cannot collect when
  ;; multiple threads are active" (probe: .dirge/probes/fibers-r6/gc-with-carriers.ss).
  (when (memq backend '(fiber fiber-go))
    (jolt-fiber-ensure-carrier!)
    (sleep (make-time 'time-duration 200000000 0)))
  (set! parked 0)
  (collect (collect-maximum-generation))
  (set! t0 (mono-nanos))
  (let loop ((i 0))
    (cond
      (fail-msg #f)
      ((fx=? i k) #f)
      ((> (- (now-secs) (/ (exact->inexact t0) 1000000000.0)) 20.0)
       (set! fail-msg
             (string-append "budget: only " (number->string i)
                            " created in 20 s (machine swapping?)")))
      (else
       (guard (e (#t (set! fail-msg
                           (if (condition? e) (condition-message e)
                               (format "~a" e)))))
         (spawn-one))
       (unless fail-msg (set! created (fx+ i 1)))
       (loop (fx+ i 1)))))
  (set! t1 (mono-nanos))
  (set! got-all
        (wait-until (lambda () (fx=? parked k)) 30.0
                    (string-append (symbol->string backend) " spawns to park")))
  (set! t2 (mono-nanos))
  (when (and (fx=? created k) (not got-all))
    (set! fail-msg (string-append "hang: " (number->string created)
                                  " created but not all parked in 30 s")))
  (printf "backend: ~a\n" backend)
  (printf "k: ~a\n" k)
  (printf "created: ~a/~a\n" created k)
  (printf "create-ms: ~a\n" (exact->inexact (/ (- t1 t0) 1000000.0)))
  (printf "per-create-us: ~a\n"
          (if (fx>? created 0) (exact->inexact (/ (- t1 t0) 1000.0 created)) 0.0))
  (printf "all-parked: ~a\n" (if got-all #t #f))
  (printf "park-ms: ~a\n" (exact->inexact (/ (- t2 t1) 1000000.0)))
  (printf "fail: ~a\n" (or fail-msg "none"))
  (flush!))

;; --- 2. memory per parked process --------------------------------------------
;; The R0 way: retain in a global, force (collect (collect-maximum-generation)),
;; read ABSOLUTE live bytes. run.sh wraps each phase in /usr/bin/time -l and
;; diffs peak RSS against the mem-baseline phase for the cross-check.
(define (mem-baseline)
  (collect (collect-maximum-generation))
  (printf "count: 0\n")
  (printf "live-delta: 0\n")
  (flush!))

(define (mem-fiber-raw)
  ;; R0's exact shape: 200k sa-fiber-spawn'd fibers run once and park, retained.
  (define k 200000)
  (define mem-held '())
  (define baseline 0)
  (define live-delta 0)
  (define parked-n 0)
  (jolt-fiber-carrier-count-set! 1)          ; run-all drains carrier 0 only
  (collect (collect-maximum-generation))
  (set! baseline (bytes-allocated))
  (set! mem-held
        (spawn-n k (lambda (i) (sa-fiber-spawn (lambda () (jolt-fiber-park!) 'x)))))
  (sa-fiber-run-all)
  (set! parked-n
        (let loop ((fs mem-held) (n 0))
          (if (null? fs) n
              (loop (cdr fs)
                    (if (eq? (jolt-fiber-state (car fs)) 'parked) (+ n 1) n)))))
  (collect (collect-maximum-generation))
  (set! live-delta (- (bytes-allocated) baseline))
  (printf "backend: fiber-raw\n")
  (printf "count: ~a\n" k)
  (printf "live-delta: ~a\n" live-delta)
  (printf "per-live-bytes: ~a\n" (/ (exact->inexact (max 0 live-delta)) k))
  (printf "parked: ~a/~a\n" parked-n k)
  (flush!))

(define (mem-fiber-go)
  ;; A fiber parked on a CHANNEL TAKE (what a go body actually does), measured by
  ;; retaining the FIBER RECORDS.
  ;;
  ;; Two earlier shapes of this phase both under-reported by ~20x, and both were
  ;; retention bugs rather than anything about fibers:
  ;;   - spawning through jolt-fiber-go-spawn retains only the RESULT channel it
  ;;     returns, not the fiber; with each body parking on a channel of its own,
  ;;     fiber and channel form a cycle nothing else points at, so the collector
  ;;     took all of them and the figure described the retained channels.
  ;;   - the `parked` counter was bumped on ENTRY to the body, before the take, so
  ;;     it read 100000/100000 while fibers were still queued; pool-reset then
  ;;     dropped the queues holding them.
  ;; The RSS cross-check disagreed by 22x both times and was the honest number.
  ;; Retaining what you are weighing is the whole method.
  ;;
  ;; This drains on the CALLING thread with sa-fiber-run-all and never starts the
  ;; pool, because a forced full collect cannot run while carrier threads are
  ;; alive (Chez: "cannot collect when multiple threads are active").
  (define k 10000)
  (define mem-held '())
  (define park-ch #f)
  (define baseline 0)
  (define live-delta 0)
  ;; Pin the pool to ONE carrier before spawning. R5 round-robins placement across
  ;; N carriers, and sa-fiber-run-all on the calling thread drains only carrier 0's
  ;; queue — so on this 10-core machine exactly a tenth of the fibers ever parked
  ;; (1000 of 10000, 10000 of 100000: the ratio was the giveaway) and the figure
  ;; described a tenth of the population.
  (jolt-fiber-carrier-count-set! 1)
  (jolt-fiber-pool-reset!)
  (collect (collect-maximum-generation))
  (set! baseline (bytes-allocated))
  (set! park-ch (jolt-async-chan 1))
  (set! mem-held (cons park-ch mem-held))
  (do ((i 0 (fx+ i 1))) ((fx=? i k))
    (set! mem-held (cons (sa-fiber-spawn (lambda () (jolt-fiber-<! park-ch))) mem-held)))
  (sa-fiber-run-all)                       ; each fiber runs until it parks on the take
  (let ((n-parked (let loop ((l mem-held) (n 0))
                    (cond ((null? l) n)
                          ((and (jolt-fiber? (car l))
                                (eq? (jolt-fiber-state (car l)) (quote parked)))
                           (loop (cdr l) (fx+ n 1)))
                          (else (loop (cdr l) n))))))
    (collect (collect-maximum-generation))
    (set! live-delta (- (bytes-allocated) baseline))
    (printf "backend: fiber-chan-park\n")
    (printf "count: ~a\n" k)
    (printf "live-delta: ~a\n" live-delta)
    (printf "per-live-bytes: ~a\n" (/ (exact->inexact (max 0 live-delta)) k))
    (printf "parked: ~a/~a\n" n-parked k)
    (flush!)))

(define (mem-thread)
  ;; go threads: one OS thread per go, body blocked on a shared empty channel
  ;; take. Thread stacks are NATIVE memory — bytes-allocated captures only the
  ;; Scheme-side (thread records, result channels); the stack commit shows up in
  ;; the RSS cross-check (per-thread RSS = (rss - baseline) / K).
  (define k 2000)
  (define parked-mu (make-mutex))
  (define parked 0)
  (define park-ch (jolt-async-chan 0))
  (define mem-held '())
  (define baseline 0)
  (define live-delta 0)
  (collect (collect-maximum-generation))
  (set! baseline (bytes-allocated))
  (do ((i 0 (fx+ i 1))) ((fx=? i k))
    (set! mem-held
          (cons (async-go-spawn-thread
                 (lambda ()
                   (mutex-acquire parked-mu)
                   (set! parked (+ parked 1))
                   (mutex-release parked-mu)
                   (jolt-async-take park-ch)))
                mem-held)))
  (wait-until (lambda () (fx=? parked k)) 60.0 "threads to park")
  (collect (collect-maximum-generation))
  (set! live-delta (- (bytes-allocated) baseline))
  (printf "backend: thread\n")
  (printf "count: ~a\n" k)
  (printf "live-delta: ~a\n" live-delta)
  (printf "per-live-bytes: ~a\n" (/ (exact->inexact (max 0 live-delta)) k))
  (printf "parked: ~a/~a\n" parked k)
  (flush!))

;; --- 3. channel throughput ---------------------------------------------------
(define (backend-ops backend)
  (if (eq? backend 'thread)
      (list jolt-async-take jolt-async-give async-go-spawn-thread)
      (list jolt-fiber-<! jolt-fiber->! jolt-fiber-go-spawn)))

(define ping-last-ms 0.0)

;; One ping-pong run, N round trips (each = A gives, B returns). Result in
;; ping-last-ms so a caller can average runs without re-spawning the boot.
(define (ping-pong-timed backend n)
  (let ((ops (backend-ops backend)))
    (define take (car ops)) (define give (cadr ops)) (define spawn (caddr ops))
    (let ((ping (jolt-async-chan 0)) (pong (jolt-async-chan 0)))
      (define t0 0) (define t1 0)
      (define ra #f) (define rb #f)
      (set! t0 (mono-nanos))
      (set! ra (spawn (lambda () (let loop ((i 0))
                                   (when (fx<? i n)
                                     (give ping i) (take pong) (loop (fx+ i 1)))))))
      (set! rb (spawn (lambda () (let loop ((i 0))
                                   (when (fx<? i n)
                                     (take ping) (give pong i) (loop (fx+ i 1)))))))
      (jolt-async-take ra)                   ; blocks until A's go closes
      (set! t1 (mono-nanos))
      (set! ping-last-ms (exact->inexact (/ (- t1 t0) 1000000.0))))))

(define (ping-phase backend pin-one?)
  (define n 10000)
  (define per-run '())
  (define mean 0.0)
  (define best 0.0)
  (printf "backend: ~a\n" backend)
  (printf "pool-carriers: ~a\n"
          (if (eq? backend 'thread) 'n/a
              (begin (if pin-one? (jolt-fiber-carrier-count-set! 1)
                         (jolt-fiber-carrier-count-set! (jolt-available-processors)))
                     (jolt-fiber-ensure-carrier!)
                     (jolt-fiber-carrier-count))))
  (set! per-run
        (let loop ((i 0) (acc '()))
          (if (fx=? i 3)
              (reverse acc)
              (begin (ping-pong-timed backend n) (loop (fx+ i 1) (cons ping-last-ms acc))))))
  (set! mean (/ (apply + per-run) (length per-run)))
  (set! best (apply min per-run))
  (printf "runs-ms: ~a\n"
          (apply string-append
                 (map (lambda (x) (string-append (number->string x) " ")) per-run)))
  (printf "mean-ms: ~a\n" mean)
  (printf "per-roundtrip-us: ~a\n" (/ (* mean 1000.0) n))
  (printf "per-handoff-us: ~a\n" (/ (* mean 1000.0) (* 2.0 n)))
  (printf "handoffs-per-sec: ~a\n" (/ (* 2.0 n) (/ mean 1000.0)))
  (flush!))

(define fanin-last-ms 0.0)

(define (fanin-phase backend)
  (define p 8) (define m 2500)
  (define per-run '())
  (define mean 0.0)
  (printf "backend: ~a\n" backend)
  (set! per-run
        (let loop ((i 0) (acc '()))
          (if (fx=? i 3)
              (reverse acc)
              (begin
                (let ((ops (backend-ops backend)))
                  (define take (car ops)) (define give (cadr ops)) (define spawn (caddr ops))
                  (let ((c (jolt-async-chan 0)))
                    (define t0 0) (define rc #f)
                    (set! t0 (mono-nanos))
                    (set! rc (spawn (lambda () (let loop ((k 0))
                                                 (when (fx<? k (* p m))
                                                   (take c) (loop (fx+ k 1)))))))
                    (do ((j 0 (fx+ j 1))) ((fx=? j p))
                      (spawn (lambda () (let loop ((j 0))
                                          (when (fx<? j m)
                                            (give c j) (loop (fx+ j 1)))))))
                    (jolt-async-take rc)
                    (set! fanin-last-ms (exact->inexact (/ (- (mono-nanos) t0) 1000000.0)))))
                (loop (fx+ i 1) (cons fanin-last-ms acc))))))
  (set! mean (/ (apply + per-run) (length per-run)))
  (printf "runs-ms: ~a\n"
          (apply string-append
                 (map (lambda (x) (string-append (number->string x) " ")) per-run)))
  (printf "mean-ms: ~a\n" mean)
  (printf "values-per-sec: ~a\n" (/ (* p m) (/ mean 1000.0)))
  (flush!))

;; --- 4. context-switch cost --------------------------------------------------
(define (switch-phase)
  ;; (a) bare continuation switch — R0's self-roundtrip, 12.5 ns.
  (define N 1000000)
  (define t0 0) (define t1 0)
  (define bare-ns 0.0)
  (define SW-N 64) (define SW-M 10000)
  (define sched-ns 0.0)
  (define old-trip 0)
  (define (self-roundtrip n)
    (if (= n 0) #f
        (let ((v (call/cc (lambda (k) (k n)))))
          (self-roundtrip (- v 1)))))
  (define (sw-fiber)
    (sa-fiber-spawn
      (lambda () (let loop ((m SW-M)) (when (fx>? m 0) (sa-fiber-yield) (loop (fx- m 1)))))))
  (define (run-sw)
    (define fs (spawn-n SW-N (lambda (i) (sw-fiber))))
    (sa-fiber-run-all)
    fs)
  (self-roundtrip 1000)
  (collect (collect-maximum-generation))
  (set! t0 (mono-nanos))
  (self-roundtrip N)
  (set! t1 (mono-nanos))
  (set! bare-ns (/ (exact->inexact (- t1 t0)) N))
  (printf "bare-switch-ns: ~a\n" bare-ns)
  ;; (b) the current scheduler yield round trip WITH the slice swap — the R2
  ;;     "64 ns" shape, on today's (R1+R2+R5) scheduler. 2 switches per yield.
  (jolt-fiber-carrier-count-set! 1)
  (run-sw)                                 ; warmup
  (set! old-trip (collect-trip-bytes))
  (collect-trip-bytes 100000000000)        ; no gen-0 in the timed region
  (collect (collect-maximum-generation))
  (set! t0 (mono-nanos))
  (run-sw)
  (set! t1 (mono-nanos))
  (collect-trip-bytes old-trip)
  (set! sched-ns (/ (exact->inexact (- t1 t0)) (* 2.0 SW-N SW-M)))
  (printf "scheduler-switch-ns: ~a\n" sched-ns)
  (printf "scheduler-switches: ~a\n" (* 2 SW-N SW-M))
  (flush!))

;; --- 5. scaling with carriers -------------------------------------------------
(define (scaling-phase)
  (define n-cpu (jolt-fiber-carrier-count))
  (define M 40)
  (define iters 10000000)
  (define (work i)
    (let loop ((j 0) (acc 0)) (if (fx<? j i) (loop (fx+ j 1) (fx+ acc j)) acc)))
  (define (run-batch c)
    (define t0 0) (define t1 0)
    (define fs #f)
    (define got #f)
    (define secs 0.0)
    (jolt-fiber-carrier-count-set! c)
    (jolt-fiber-pool-reset!)
    (jolt-fiber-ensure-carrier!)
    (set! t0 (mono-nanos))
    (set! fs (spawn-n M (lambda (i) (sa-fiber-spawn (lambda () (work iters))))))
    (set! got (wait-until (lambda () (all-done? fs)) 60.0
                          (string-append (number->string c) "-carrier batch")))
    (set! t1 (mono-nanos))
    (set! secs (/ (exact->inexact (- t1 t0)) 1000000000.0))
    (printf "carriers: ~a\n" c)
    (printf "ms: ~a\n" (* secs 1000.0))
    (printf "mops-per-sec: ~a\n" (/ (* M iters) secs 1000000.0))
    (printf "completed: ~a\n" (if got #t #f))
    (flush!))
  (printf "cpu-count: ~a\n" n-cpu)
  (for-each run-batch '(1 2 4))
  (run-batch n-cpu)
  ;; uneven lifetimes: at n-cpu carriers, fiber 0 does 10x the work. Fibers do
  ;; not migrate (R0(d)), so the long fiber pins its carrier and the total time
  ;; is bounded by it — a property of the design, not a defect.
  (let ((c n-cpu))
    (define t0 0) (define t1 0)
    (define fs #f)
    (define got #f)
    (define secs 0.0)
    (jolt-fiber-carrier-count-set! c)
    (jolt-fiber-pool-reset!)
    (jolt-fiber-ensure-carrier!)
    (set! t0 (mono-nanos))
    (set! fs (spawn-n c
                      (lambda (i)
                        (sa-fiber-spawn
                          (lambda () (work (* iters (if (fx=? i 0) 10 1))))))))
    (set! got (wait-until (lambda () (all-done? fs)) 120.0 "uneven batch"))
    (set! t1 (mono-nanos))
    (set! secs (/ (exact->inexact (- t1 t0)) 1000000000.0))
    (printf "uneven-carriers: ~a\n" c)
    (printf "uneven-ms: ~a\n" (* secs 1000.0))
    (printf "uneven-mops-per-sec: ~a\n" (/ (* iters (+ 10 (- c 1))) secs 1000000.0))
    (printf "uneven-completed: ~a\n" (if got #t #f))
    (flush!)))


;; --- 2b. cheap park vs continuation park -------------------------------------
;; The R7 pair. Both arms are the SAME shape — K processes, each spawned with its
;; own buffered(1) result channel, each parked on a take from ONE shared empty
;; channel, every fiber record AND result channel retained — so the only
;; difference between the two numbers is the park mechanism:
;;
;;   sm  : the body was CPS'd, so the park stored a resume closure and captured
;;         nothing (jolt-sm-park!)
;;   cap : the park captured a continuation, which retains a Chez stack segment
;;         for as long as the process stays parked (jolt-fiber-to-scheduler!)
;;
;; Neither arm can use the real spawn (__sm-spawn / jolt-fiber-go-spawn): both
;; call jolt-fiber-ensure-carrier!, and a forced full collect cannot run with
;; carrier threads alive. So each arm replicates its spawn minus that one call and
;; drains on the calling thread, exactly as mem-fiber-go does.
;;
;; These are NOT comparable to mem-fiber-go's figure: that arm has no result
;; channel. Compare sm against cap, in one run.
(define (mem-park-pair kind)
  (define k 10000)
  (define mem-held '())
  (define park-ch #f)
  (define baseline 0)
  (define live-delta 0)
  (define fibers '())
  (jolt-fiber-carrier-count-set! 1)
  (jolt-fiber-pool-reset!)
  (collect (collect-maximum-generation))
  (set! baseline (bytes-allocated))
  (set! park-ch (jolt-async-chan 1))
  (set! mem-held (cons park-ch mem-held))
  (do ((i 0 (fx+ i 1))) ((fx=? i k))
    (let* ((w (jolt-async-chan 1))
           (f (if (eq? kind (quote sm))
                  ;; jolt-sm-fiber-spawn minus ensure-carrier!
                  (sa-fiber-spawn
                   (lambda ()
                     (jolt-sm-drive w (lambda (kk) (jolt-sm-take park-ch kk)))))
                  ;; jolt-fiber-go-spawn minus ensure-carrier!
                  (sa-fiber-spawn
                   (lambda ()
                     (let ((r (guard (e (#t (cons #f e)))
                                (cons #t (jolt-fiber-<! park-ch)))))
                       (if (car r)
                           (when (not (jolt-nil? (cdr r))) (jolt-async-give w (cdr r)))
                           (async-report-uncaught! "bench body" (cdr r)))
                       (jolt-async-close! w)))))))
      (set! fibers (cons f fibers))
      (set! mem-held (cons w (cons f mem-held)))))
  (sa-fiber-run-all)
  (let ((n-parked (let loop ((l fibers) (n 0))
                    (cond ((null? l) n)
                          ((eq? (jolt-fiber-state (car l)) (quote parked))
                           (loop (cdr l) (fx+ n 1)))
                          (else (loop (cdr l) n)))))
        (n-captured (let loop ((l fibers) (n 0))
                      (cond ((null? l) n)
                            ((jolt-fiber-k (car l)) (loop (cdr l) (fx+ n 1)))
                            (else (loop (cdr l) n))))))
    (collect (collect-maximum-generation))
    (set! live-delta (- (bytes-allocated) baseline))
    (printf "backend: ~a-park\n" kind)
    (printf "count: ~a\n" k)
    (printf "live-delta: ~a\n" live-delta)
    (printf "per-live-bytes: ~a\n" (/ (exact->inexact (max 0 live-delta)) k))
    (printf "parked: ~a/~a\n" n-parked k)
    ;; the representation, in the same run as the number: a cheap park holds no
    ;; continuation, a capture holds one for every process
    (printf "holding-a-continuation: ~a/~a\n" n-captured k)
    (printf "cheap-parks: ~a\n" (jolt-sm-parks))
    (printf "captures: ~a\n" (jolt-fiber-chan-parks))
    (flush!)))


;; --- 2c. park/resume round trip: cheap vs continuation ------------------------
;; One fiber, one carrier, K park/resume round trips. Each iteration: the fiber
;; parks on an empty channel, this thread delivers a value (the parked alt-taker
;; takes it directly), and sa-fiber-run-all resumes the fiber.
;;
;; The deliver + drain is the SAME harness in both arms, and it dominates — so
;; these are upper bounds on the park itself, and only the DIFFERENCE between the
;; two arms is about the park mechanism. Reported both ways rather than pretending
;; the absolute number is the switch cost.
(define (park-switch-phase kind)
  (define k 20000)
  (define (arm kind)
    (let* ((ch (jolt-async-chan))
           (w (jolt-async-chan 1))
           (f (if (eq? kind (quote sm))
                  (sa-fiber-spawn
                   (lambda ()
                     (jolt-sm-drive
                      w
                      (lambda (kk)
                        (let loop ((i 0))
                          (if (fx=? i k)
                              (kk (quote done))
                              (jolt-sm-take ch (lambda (v) (loop (fx+ i 1))))))))))
                  (sa-fiber-spawn
                   (lambda ()
                     (let loop ((i 0))
                       (if (fx=? i k)
                           (quote done)
                           (begin (jolt-fiber-<! ch) (loop (fx+ i 1))))))))))
      (sa-fiber-run-all)                    ; run to the first park
      (let ((t1 (mono-nanos)))
        (do ((i 0 (fx+ i 1))) ((fx=? i k))
          (jolt-async-give ch i)
          (sa-fiber-run-all))
        (let ((t2 (mono-nanos)))
          (list (/ (exact->inexact (- t2 t1)) k)
                (eq? (jolt-fiber-state f) (quote done)))))))
  ;; ONE arm per process. Run in the same process the second arm read 25% slower
  ;; than the first whichever order they went in, so the ordering bias was larger
  ;; than the effect — the memory phases are split for the same reason.
  (jolt-fiber-carrier-count-set! 1)
  (jolt-fiber-pool-reset!)
  (let* ((c0 (jolt-sm-parks))
         (p0 (jolt-fiber-chan-parks))
         (r (arm kind))
         (c1 (jolt-sm-parks))
         (p1 (jolt-fiber-chan-parks)))
    (printf "arm: ~a\n" kind)
    (printf "round-trips: ~a\n" k)
    (printf "ns-per-round-trip: ~a\n" (car r))
    (printf "completed: ~a\n" (cadr r))
    (printf "cheap-parks: ~a\n" (- c1 c0))
    (printf "captures: ~a\n" (- p1 p0))
    (flush!)))

;; --- dispatch ----------------------------------------------------------------
(let ((phase (and (a 1) (string->symbol (a 1)))))
  (case phase
    ((spawn-thread)  (spawn-phase 'thread (or (and (a 2) (string->number (a 2))) 1000)))
    ((spawn-fiber)   (spawn-phase 'fiber (or (and (a 2) (string->number (a 2))) 1000)))
    ((spawn-fiber-go) (spawn-phase 'fiber-go (or (and (a 2) (string->number (a 2))) 1000)))
    ((mem-baseline)  (mem-baseline))
    ((mem-fiber-raw) (mem-fiber-raw))
    ((mem-fiber-go)  (mem-fiber-go))
    ((mem-sm-park)   (mem-park-pair (quote sm)))
    ((mem-cap-park)  (mem-park-pair (quote cap)))
    ((park-switch-sm)  (park-switch-phase (quote sm)))
    ((park-switch-cap) (park-switch-phase (quote cap)))
    ((mem-thread)    (mem-thread))
    ((ping-thread)   (ping-phase 'thread #f))
    ((ping-fiber)    (ping-phase 'fiber #f))
    ((ping-fiber-1)  (ping-phase 'fiber #t))
    ((fanin-thread)  (fanin-phase 'thread))
    ((fanin-fiber)   (fanin-phase 'fiber))
    ((switch)        (switch-phase))
    ((scaling)       (scaling-phase))
    (else
     (printf "usage: bench-fibers.ss <phase> [arg]\n")
     (printf "  spawn-thread K | spawn-fiber K | spawn-fiber-go K\n")
     (printf "  mem-baseline | mem-fiber-raw | mem-fiber-go | mem-thread\n")
     (printf "  mem-sm-park | mem-cap-park\n")
     (printf "  park-switch-sm | park-switch-cap\n")
     (printf "  ping-thread | ping-fiber | fanin-thread | fanin-fiber\n")
     (printf "  switch | scaling\n")
     (exit 1))))
(exit 0)
