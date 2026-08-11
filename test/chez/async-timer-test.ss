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
(define (pending-count) (jolt-with-mutex timeout-mu (length timeout-pending)))

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

(printf "\n~a checks, ~a failed\n" total fails)
(when (> fails 0) (exit 1))
(printf "async-timer gate: PASS\n")
