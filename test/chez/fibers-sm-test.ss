;; test/chez/fibers-sm-test.ss — R7 gate: the cheap park (epic jolt-nvpr.9).
;; Run: chez --script test/chez/fibers-sm-test.ss (wired into `make fibers`).
;;
;; The bodies here are hand-written in the shape clojure.core.async.sm emits — a
;; one-argument function of its continuation — so this half is gated with no
;; compiler involvement. The end-to-end gate over real `go` forms is
;; host/chez/run-gosm.ss.
;;
;; What is under test: a park that has a continuation threaded to it stores the
;; rest of the computation and switches WITHOUT call/1cc, while a park that does
;; not — a plain jolt-fiber-<! reached through an ordinary call — still captures.
;; Both inside the same fiber, chosen per park site. The two counters are the
;; measurement: jolt-sm-parks (cheap) and jolt-fiber-chan-parks (captures).
;;
;; Scenarios:
;;   1. a ready channel completes inline — neither counter moves
;;   2. an empty channel parks cheaply, and the value arrives later
;;   3. a chain of N cheap parks
;;   4. MIXING: cheap park, then a park through a helper (captures), then cheap
;;      again — the check the whole per-park-site design rests on
;;   5. a throw after a cheap park kills only its own process
;;   6. two CPS'd bodies interleave on ONE carrier
;;   7. the parked representation itself: k clear + sm set for a cheap park, the
;;      other way round for a capture
;;   8. the put side parks cheaply and a thread take wakes it
;;   9. (>! ch nil) on a fiber throws and leaves the channel USABLE
;;  10. off a fiber the ops are today's blocking ops, k applied inline
;;  11. a long chain of immediate steps stays flat (the tail-call claim)
;;
;; Fibers are driven synchronously here (sa-fiber-run-all on one pinned carrier),
;; so no carrier thread races the assertions. Timing appears nowhere.

(import (chezscheme))
(load "host/chez/rt.ss")
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
(define (now-secs) (/ (exact->inexact (mono-nanos)) 1000000000.0))

(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (if (pred)
          #t
          (if (> (now-secs) deadline)
              (begin (set! fails (+ fails 1)) (printf "  FAIL: ~a (timed out)\n" what) #f)
              (begin (sleep (make-time 'time-duration 1000000 0)) (loop)))))))

;; Pump the carrier until pred holds — a cross-thread wake can land after a drain
;; has already returned, so one drain is not enough (the R3 gate's lesson).
(define (pump-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (cond ((pred) #t)
            ((> (now-secs) deadline)
             (set! fails (+ fails 1)) (printf "  FAIL: ~a (timed out)\n" what) #f)
            (else (sa-fiber-run-all)
                  (sleep (make-time 'time-duration 1000000 0))
                  (loop))))))

(define (settled? f) (memq (jolt-fiber-state f) '(done dead)))

;; Hand the fiber ONE value, but only once it is actually parked — otherwise the
;; producer races the consumer and a take that finds a waiting putter completes
;; without parking, so the park count would depend on the interleaving. A parked
;; alt-taker is already registered, so the give completes on this thread.
(define (feed-parked! f ch v what)
  (and (pump-until (lambda () (eq? (jolt-fiber-state f) 'parked)) 5.0 what)
       (begin (jolt-async-give ch v) (sa-fiber-run-all) #t)))

;; Spawn a CPS'd body the way jolt-sm-fiber-spawn does, minus the carrier start —
;; this gate runs the scheduler itself.
(define (sm-spawn body-fn)
  (let* ((w (ac-make 1 'fixed #f))
         (f (sa-fiber-spawn (lambda () (jolt-sm-drive w body-fn)))))
    (cons f w)))

(define (cheap) (jolt-sm-parks))
(define (caught) (jolt-fiber-chan-parks))

(printf "== R7: the cheap park ==\n")

;; --- 1. a ready channel completes inline -------------------------------------
(printf "\n== 1. ready channel: inline, no park of either kind ==\n")
(define ch1 (ac-make 4 'fixed #f))
(jolt-async-give ch1 7)
(define c1 (cheap))
(define p1 (caught))
(define fw1 (sm-spawn (lambda (k) (jolt-sm-take ch1 (lambda (v) (k (* v 6)))))))
(sa-fiber-run-all)
(ok "1. body finished" (eq? (jolt-fiber-state (car fw1)) 'done))
(ok "1. value threaded through the continuation" (= (jolt-fiber-result (car fw1)) 42))
(ok "1. no cheap park" (= (cheap) c1))
(ok "1. no capture" (= (caught) p1))
(ok "1. result delivered on the channel" (= (ac-poll! (cdr fw1)) 42))

;; --- 2. an empty channel parks cheaply ---------------------------------------
(printf "\n== 2. empty channel: one cheap park, no capture ==\n")
(define ch2 (jolt-async-chan))
(define c2 (cheap))
(define p2 (caught))
(define fw2 (sm-spawn (lambda (k) (jolt-sm-take ch2 (lambda (v) (k (+ v 1)))))))
(sa-fiber-run-all)
(ok "2. parked" (eq? (jolt-fiber-state (car fw2)) 'parked))
(ok "2. one cheap park" (= (cheap) (+ c2 1)))
(ok "2. no capture" (= (caught) p2))
(define t2 'unset)
(fork-thread (lambda () (set! t2 (jolt-async-give ch2 41))))
(pump-until (lambda () (settled? (car fw2))) 5.0 "2. fiber resumed and finished")
(ok "2. thread put completed" (eq? t2 #t))
(ok "2. resumed with the value" (= (jolt-fiber-result (car fw2)) 42))
(ok "2. still no capture" (= (caught) p2))

;; --- 3. a chain of cheap parks ------------------------------------------------
(printf "\n== 3. five cheap parks in a chain ==\n")
(define ch3 (jolt-async-chan))
(define c3 (cheap))
(define p3 (caught))
;; sum five taken values, one park per take
(define fw3
  (sm-spawn
   (lambda (k)
     (let loop ((i 0) (acc 0))
       (if (fx=? i 5)
           (k acc)
           (jolt-sm-take ch3 (lambda (v) (loop (fx+ i 1) (+ acc v)))))))))
(let loop ((i 1))
  (when (fx<=? i 5)
    (feed-parked! (car fw3) ch3 i "3. parked before each value")
    (loop (fx+ i 1))))
(pump-until (lambda () (settled? (car fw3))) 5.0 "3. chain finished")
(ok "3. summed every value" (= (jolt-fiber-result (car fw3)) 15))
(ok "3. five cheap parks, one per take" (= (cheap) (+ c3 5)))
(ok "3. no captures" (= (caught) p3))

;; --- 4. MIXING cheap parks and captures in one body --------------------------
;; The middle take goes through an ordinary Scheme call, so no continuation is
;; threaded to it and it must park the old way. This is what makes the per-park-
;; site choice safe: the pass can miss a park without breaking it.
(printf "\n== 4. mixing: cheap, captured, cheap — in one body ==\n")
(define ch4 (jolt-async-chan))
(define (helper-take ch) (jolt-fiber-<! ch))     ; the pass cannot see this one
(define c4 (cheap))
(define p4 (caught))
(define fw4
  (sm-spawn
   (lambda (k)
     (jolt-sm-take ch4
       (lambda (a)
         (let ((b (helper-take ch4)))            ; captures a continuation
           (jolt-sm-take ch4 (lambda (c) (k (list a b c))))))))))
;; one value per observed park, so the counts are the mechanism and not the race:
;; park 1 is cheap, park 2 is the helper's capture, park 3 is cheap again
(feed-parked! (car fw4) ch4 'a "4. parked on the first (cheap) take")
(feed-parked! (car fw4) ch4 'b "4. parked on the helper's (captured) take")
(feed-parked! (car fw4) ch4 'c "4. parked on the third (cheap) take")
(pump-until (lambda () (settled? (car fw4))) 5.0 "4. mixed body finished")
(ok "4. every park delivered, in order"
    (equal? (jolt-fiber-result (car fw4)) '(a b c)))
(ok "4. two cheap parks" (= (cheap) (+ c4 2)))
(ok "4. exactly one capture" (= (caught) (+ p4 1)))

;; --- 5. a throw after a cheap park --------------------------------------------
;; A cheap park leaves no frames, so the body's error handling has to be
;; re-established on each resume. It is: the resume re-enters through the thunk,
;; which is the driver, whose guard reports the throw and CLOSES the go channel —
;; the contract jolt-fiber-go-spawn has for a throwing body. Drop that guard and
;; "its channel was closed" fails (verified); resume*'s own thunk-path guard still
;; marks the fiber dead, which is why the carrier survives either way.
(printf "\n== 5. a throw after a cheap park kills only its own process ==\n")
(define ch5 (jolt-async-chan))
(define ch5b (ac-make 1 'fixed #f))
(jolt-async-give ch5b 'sib)
(define fw5 (sm-spawn (lambda (k) (jolt-sm-take ch5 (lambda (v) (error 'body "boom"))))))
(define fw5b (sm-spawn (lambda (k) (jolt-sm-take ch5b (lambda (v) (k v))))))
(sa-fiber-run-all)
(ok "5. thrower parked" (eq? (jolt-fiber-state (car fw5)) 'parked))
(fork-thread (lambda () (jolt-async-give ch5 'go)))
(pump-until (lambda () (settled? (car fw5))) 5.0 "5. thrower settled")
(ok "5. thrower is dead" (eq? (jolt-fiber-state (car fw5)) 'dead))
(ok "5. the error was recorded" (condition? (jolt-fiber-error (car fw5))))
(ok "5. its channel was closed" (async-chan-closed? (cdr fw5)))
(pump-until (lambda () (settled? (car fw5b))) 5.0 "5. sibling settled")
(ok "5. the sibling on the same carrier still finished"
    (and (eq? (jolt-fiber-state (car fw5b)) 'done)
         (eq? (jolt-fiber-result (car fw5b)) 'sib)))
;; the carrier is this thread; it survived if we are still running
(ok "5. the carrier survived" #t)

;; --- 6. two CPS'd bodies interleave on one carrier ----------------------------
(printf "\n== 6. two bodies interleave on ONE carrier ==\n")
(define ch6a (jolt-async-chan))
(define ch6b (jolt-async-chan))
(define log6 '())
(define (log6! x) (set! log6 (cons x log6)))
(define fw6a
  (sm-spawn (lambda (k) (jolt-sm-take ch6a (lambda (v) (log6! 'a) (k v))))))
(define fw6b
  (sm-spawn (lambda (k) (jolt-sm-take ch6b (lambda (v) (log6! 'b) (k v))))))
(sa-fiber-run-all)
(ok "6. both parked"
    (and (eq? (jolt-fiber-state (car fw6a)) 'parked)
         (eq? (jolt-fiber-state (car fw6b)) 'parked)))
(fork-thread (lambda () (jolt-async-give ch6b 2) (jolt-async-give ch6a 1)))
(pump-until (lambda () (and (settled? (car fw6a)) (settled? (car fw6b))))
            5.0 "6. both finished")
(ok "6. both produced their value"
    (and (= (jolt-fiber-result (car fw6a)) 1) (= (jolt-fiber-result (car fw6b)) 2)))
(ok "6. b ran before a — resumed in wake order, not spawn order"
    (equal? (reverse log6) '(b a)))

;; --- 7. the parked representation --------------------------------------------
;; The structural version of "which representation was chosen": a cheap park holds
;; a pending step and NO continuation; a capture holds a continuation and no step.
(printf "\n== 7. what a parked process holds ==\n")
(define ch7 (jolt-async-chan))
(define fw7 (sm-spawn (lambda (k) (jolt-sm-take ch7 (lambda (v) (k v))))))
(sa-fiber-run-all)
(ok "7. cheap park: no continuation captured" (eq? (jolt-fiber-k (car fw7)) #f))
(ok "7. cheap park: holds a pending step" (procedure? (jolt-fiber-sm (car fw7))))
(define ch7b (jolt-async-chan))
(define f7b (sa-fiber-spawn (lambda () (jolt-fiber-<! ch7b))))
(sa-fiber-run-all)
(ok "7. capture: holds a continuation" (procedure? (jolt-fiber-k f7b)))
(ok "7. capture: no pending step" (eq? (jolt-fiber-sm f7b) #f))
;; drain both so later scenarios start from an idle carrier
(fork-thread (lambda () (jolt-async-give ch7 1) (jolt-async-give ch7b 1)))
(pump-until (lambda () (and (settled? (car fw7)) (settled? f7b))) 5.0 "7. drained")

;; --- 8. the put side ----------------------------------------------------------
(printf "\n== 8. a put parks cheaply and a thread take wakes it ==\n")
(define ch8 (jolt-async-chan))
(define c8 (cheap))
(define p8 (caught))
(define fw8 (sm-spawn (lambda (k) (jolt-sm-put ch8 99 (lambda (okp) (k okp))))))
(sa-fiber-run-all)
(ok "8. putter parked" (eq? (jolt-fiber-state (car fw8)) 'parked))
(ok "8. one cheap park" (= (cheap) (+ c8 1)))
(ok "8. no capture" (= (caught) p8))
(define t8 'unset)
(fork-thread (lambda () (set! t8 (jolt-async-take ch8))))
(pump-until (lambda () (settled? (car fw8))) 5.0 "8. putter finished")
(ok "8. the thread got the value" (= t8 99))
(ok "8. the put reported success" (eq? (jolt-fiber-result (car fw8)) #t))

;; --- 9. a nil put throws WITHOUT wedging the channel -------------------------
;; ac-try-give!/locked raises on nil, and the fiber put path holds the channel
;; mutex by hand (it has to release before parking, so with-mutex is unavailable).
;; The throw used to escape with the mutex held, and every later op on that
;; channel deadlocked.
(printf "\n== 9. a nil put throws and the channel stays usable ==\n")
(define (nil-put-then-use! label put!)
  (let* ((ch (ac-make 1 'fixed #f))
         (f (sa-fiber-spawn (lambda () (put! ch)))))
    (sa-fiber-run-all)
    (ok (string-append label ": the body died on the nil put")
        (eq? (jolt-fiber-state f) 'dead))
    (let ((got 'unset))
      (fork-thread (lambda () (set! got (guard (e (#t 'threw)) (jolt-async-give ch 5)))))
      (wait-until (lambda () (not (eq? got 'unset))) 5.0
                  (string-append label ": channel still usable after the throw"))
      (ok (string-append label ": the channel mutex was released") (eq? got #t)))))
(nil-put-then-use! "9. jolt-fiber->!" (lambda (ch) (jolt-fiber->! ch jolt-nil)))
(nil-put-then-use! "9. jolt-sm-put"
                   (lambda (ch) (jolt-sm-put ch jolt-nil (lambda (v) v))))

;; --- 10. off a fiber the ops are today's blocking ops -------------------------
(printf "\n== 10. off a fiber: blocking, continuation applied inline ==\n")
(define ch10 (ac-make 2 'fixed #f))
(jolt-async-give ch10 3)
(define c10 (cheap))
(define p10 (caught))
(ok "10. take applies its continuation" (= (jolt-sm-take ch10 (lambda (v) (* v 5))) 15))
(ok "10. put applies its continuation"
    (eq? (jolt-sm-put ch10 1 (lambda (okp) okp)) #t))
(ok "10. no park of either kind off a fiber"
    (and (= (cheap) c10) (= (caught) p10)))

;; --- 11. a long chain of immediate steps -------------------------------------
;; Every (k v) is a tail call, so a chain of steps neither grows the stack nor
;; changes the answer. 20k immediate takes off one buffered channel.
(printf "\n== 11. 20k immediate steps in one body ==\n")
(define n11 20000)
(define ch11 (ac-make n11 'fixed #f))
(let loop ((i 0)) (when (fx<? i n11) (jolt-async-give ch11 1) (loop (fx+ i 1))))
(define c11 (cheap))
(define fw11
  (sm-spawn
   (lambda (k)
     (let loop ((i 0) (acc 0))
       (if (fx=? i n11)
           (k acc)
           (jolt-sm-take ch11 (lambda (v) (loop (fx+ i 1) (+ acc v)))))))))
(sa-fiber-run-all)
(ok "11. finished in one run" (eq? (jolt-fiber-state (car fw11)) 'done))
(ok "11. counted every step" (= (jolt-fiber-result (car fw11)) n11))
(ok "11. no parks — the channel was always ready" (= (cheap) c11))

;; --- 12. an sm op on an ordinary fiber refuses, and refuses CLEANLY -----------
;; The cheap park is only correct under jolt-sm-drive: it clears k and stashes the
;; step, and a fiber whose thunk is anything else would re-run that thunk from the
;; top on the next dispatch — a silent re-take. __sm-take is a def'd var, so a
;; program CAN call it on an ordinary fiber; it must throw.
;;
;; And it must throw with the channel untouched. Checked at the park instead, the
;; op had already appended a waiter to alt-takers and committed the fiber to
;; 'parked under that waiter's wmu, so the throw stranded a registered handler and
;; the next value delivered to it went nowhere. Both halves are asserted: the
;; ordinary fiber dies, AND a later take on the same channel still gets the value.
(printf "\n== 12. an sm op on an ordinary fiber refuses cleanly ==\n")
(define ch12 (jolt-async-chan))
(define c12 (cheap))
(define p12 (caught))
;; an ORDINARY fiber (thunk is not a driver, so sm stays #f), calling __sm-take
(define f12 (sa-fiber-spawn (lambda () (jolt-sm-take ch12 (lambda (v) v)))))
(sa-fiber-run-all)
(ok "12. the fiber died rather than parking" (eq? (jolt-fiber-state f12) 'dead))
(ok "12. no cheap park was counted" (= (cheap) c12))
(ok "12. no capture was counted" (= (caught) p12))
(ok "12. no waiter was left on the channel" (null? (async-chan-alt-takers ch12)))
;; the channel is still usable: a real CPS'd body parks on it and gets the value
(define fw12 (sm-spawn (lambda (k) (jolt-sm-take ch12 (lambda (v) (k (+ v 1)))))))
(sa-fiber-run-all)
(ok "12. a real body parks on the same channel"
    (feed-parked! (car fw12) ch12 41 "12. park"))
(ok "12. and the value still arrives" (= (jolt-fiber-result (car fw12)) 42))
;; the put side takes the same check
(define ch12b (jolt-async-chan))
(define f12b (sa-fiber-spawn (lambda () (jolt-sm-put ch12b 1 (lambda (v) v)))))
(sa-fiber-run-all)
(ok "12. the put side refuses too" (eq? (jolt-fiber-state f12b) 'dead))
(ok "12. and leaves no putter behind" (null? (async-chan-alt-putters ch12b)))

;; --- 13. a resumed step runs at the carrier's baseline interrupt depth --------
;; jolt-sm-commit! disables interrupts to make "mark parked" and "escape" one
;; region, and jolt-sm-park! escapes out of it. The depth is NOT carried across a
;; cheap park the way a continuation park's is (jolt-fiber-sic), and it must not
;; be: a cheap park does not rewind. The disabled region is destroyed by the park
;; exactly as a dynamic-wind would be, so there is no frame left to restore a
;; depth for, and the resume enters the driver fresh at the carrier's baseline.
;;
;; Pinned here because the alternative is a plausible-looking bug in either
;; direction: carrying the depth across would resume the step with interrupts off
;; and never turn them back on, so that fiber would stop being preemptible for as
;; long as it ran, and forgetting to walk the region back on the way OUT would
;; leave the scheduler itself with interrupts disabled (jolt-kkt3).
(printf "\n== 13. a resumed step runs at the carrier's baseline depth ==\n")
(define ch13 (jolt-async-chan))
(define d13-before (jolt-current-disable-count))
(define d13-in-step 'unset)
(define fw13
  (sm-spawn
   (lambda (k)
     (jolt-sm-take ch13
                   (lambda (v)
                     (set! d13-in-step (jolt-current-disable-count))
                     (k v))))))
(sa-fiber-run-all)
(ok "13. the body parked cheaply" (eq? (jolt-fiber-state (car fw13)) 'parked))
(ok "13. and the drain left the carrier at its own depth"
    (= (jolt-current-disable-count) d13-before))
(ok "13. the value arrives" (feed-parked! (car fw13) ch13 5 "13. park"))
(ok "13. the resumed step ran with interrupts ENABLED, at the baseline"
    (eqv? d13-in-step d13-before))
(ok "13. and the fiber completed" (= (jolt-fiber-result (car fw13)) 5))
(ok "13. the carrier is back at its own depth afterwards"
    (= (jolt-current-disable-count) d13-before))
;; The same for a put, whose commit runs through the other branch of
;; jolt-sm-fiber-put.
(define ch13b (jolt-async-chan))
(define d13b-in-step 'unset)
(define fw13b
  (sm-spawn
   (lambda (k)
     (jolt-sm-put ch13b 7
                  (lambda (okp)
                    (set! d13b-in-step (jolt-current-disable-count))
                    (k okp))))))
(sa-fiber-run-all)
(ok "13. the putter parked cheaply" (eq? (jolt-fiber-state (car fw13b)) 'parked))
(define t13 'unset)
(fork-thread (lambda () (set! t13 (jolt-async-take ch13b))))
(pump-until (lambda () (settled? (car fw13b))) 5.0 "13. putter finished")
(ok "13. the taker got the value" (eqv? t13 7))
(ok "13. the resumed put step ran at the baseline too"
    (eqv? d13b-in-step d13-before))
(ok "13. and the carrier is still at its own depth"
    (= (jolt-current-disable-count) d13-before))

(printf "\nfibers-sm-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-sm-test: PASS — the cheap park, chosen per park site\n") (exit 0))
    (exit 1))
