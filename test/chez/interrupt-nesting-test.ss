;; Nested run-interruptible timer restoration regression. Run from repo root:
;;   chez --script test/chez/interrupt-nesting-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))

(define (interrupted-condition? e)
  (let ((v (jolt-unwrap-throw e)))
    (and (jolt-ex-info-record? v)
         (string=? "Evaluation interrupted" (jolt-ex-info-record-message v))
         (eq? #t (jolt-get (jolt-ex-info-record-data v)
                           jolt-kw-interrupted #f)))))

;; #(ready? done? result mutex condition). Ready is published only after the
;; inner extent exits, so an outer interrupt then requires restored polling.
(define (make-probe-state)
  (vector #f #f #f (make-mutex) (make-condition)))
(define (probe-signal-ready! state)
  (with-mutex (vector-ref state 3)
    (vector-set! state 0 #t)
    (condition-broadcast (vector-ref state 4))))
(define (probe-finish! state result)
  (with-mutex (vector-ref state 3)
    (vector-set! state 2 result)
    (vector-set! state 1 #t)
    (condition-broadcast (vector-ref state 4))))
(define (probe-wait state index ms)
  (let ((deadline (ms->deadline ms)))
    (with-mutex (vector-ref state 3)
      (let loop ()
        (cond ((vector-ref state index) #t)
              ((condition-wait (vector-ref state 4)
                               (vector-ref state 3) deadline)
               (loop))
              (else (and (vector-ref state index) #t)))))))
(define (probe-done? state)
  (with-mutex (vector-ref state 3) (and (vector-ref state 1) #t)))

(define inner-throw-sentinel (list 'inner-throw-sentinel))
(define (spin-forever) (let loop () (loop)))

(define (start-probe mode)
  (let ((outer-token (jolt-make-interrupt))
        (inner-token (jolt-make-interrupt))
        (state (make-probe-state)))
    (let ((thread
           (fork-thread
            (lambda ()
              (let ((result
                     (guard (e (#t e))
                       (jolt-run-interruptible
                        outer-token
                        (lambda ()
                          (case mode
                            ((normal)
                             (unless (eq? 'inner-value
                                          (jolt-run-interruptible
                                           inner-token
                                           (lambda () 'inner-value)))
                               (error 'interrupt-nesting-test
                                      "normal inner result changed")))
                            ((throw)
                             (unless
                                 (guard (e (#t (eq? e inner-throw-sentinel)))
                                   (jolt-run-interruptible
                                    inner-token
                                    (lambda () (raise inner-throw-sentinel)))
                                   #f)
                               (error 'interrupt-nesting-test
                                      "inner throw did not propagate unchanged")))
                            ((interrupt)
                             (jolt-interrupt! inner-token)
                             (unless
                                 (guard (e (#t (interrupted-condition? e)))
                                   (jolt-run-interruptible inner-token spin-forever)
                                   #f)
                               (error 'interrupt-nesting-test
                                      "inner interrupt marker missing")))
                            (else
                             (error 'interrupt-nesting-test
                                    "unknown probe mode" mode)))
                          (probe-signal-ready! state)
                          (spin-forever)))
                       'outer-returned-without-interrupt)))
                (probe-finish! state result))))))
      (vector outer-token state thread))))

(define (probe-token probe) (vector-ref probe 0))
(define (probe-state probe) (vector-ref probe 1))
(define (probe-thread probe) (vector-ref probe 2))

(define (require-ready! label probe)
  (unless (probe-wait (probe-state probe) 0 5000)
    (printf "FAIL: ~a did not reach its post-inner outer extent~n" label)
    ;; Chez has no safe force-stop for a failed spinning worker.
    (exit 1)))
(define (interrupt-and-require-done! label probe)
  (jolt-interrupt! (probe-token probe))
  (unless (probe-wait (probe-state probe) 1 5000)
    (printf "FAIL: ~a outer token was not polled after inner exit~n" label)
    (exit 1))
  (thread-join (probe-thread probe))
  (ok (string-append label " restores outer token polling")
      (interrupted-condition? (vector-ref (probe-state probe) 2))))

;; Every terminal path through an inner dynamic extent restores the outer frame.
(for-each
 (lambda (entry)
   (let* ((mode (car entry)) (label (cdr entry)) (probe (start-probe mode)))
     (require-ready! label probe)
     (interrupt-and-require-done! label probe)))
 '((normal . "normal inner return")
   (throw . "inner throw")
   (interrupt . "inner interruption")))

;; Workers own disjoint timer stacks and tokens. No scheduling fairness beyond
;; each forked OS thread eventually running is assumed.
(let ((a (start-probe 'normal)) (b (start-probe 'normal)))
  (require-ready! "concurrent worker A" a)
  (require-ready! "concurrent worker B" b)
  (jolt-interrupt! (probe-token a))
  (unless (probe-wait (probe-state a) 1 5000)
    (printf "FAIL: concurrent worker A did not observe its token~n")
    (exit 1))
  (thread-join (probe-thread a))
  (sleep (ms->duration 50))
  (ok "interrupting worker A does not interrupt worker B"
      (not (probe-done? (probe-state b))))
  (ok "concurrent worker A reports interruption"
      (interrupted-condition? (vector-ref (probe-state a) 2)))
  (interrupt-and-require-done! "concurrent worker B" b))

;; Thread parameters are inherited. A child can see the raw stack value, but it
;; must not treat the parent's active polling extent as its own.
(let ((child-effective-stack #f))
  (jolt-run-interruptible
   (jolt-make-interrupt)
   (lambda ()
     (let ((child (fork-thread
                   (lambda ()
                     (set! child-effective-stack
                           (current-interrupt-poll-stack))))))
       (thread-join child))))
  (ok "child thread does not inherit effective polling ownership"
      (null? child-effective-stack)))

;; No handler/token state leaks into later work on the test thread.
(ok "normal run-interruptible remains healthy"
    (= 42 (jolt-run-interruptible (jolt-make-interrupt) (lambda () 42))))
(ok "runtime compile/eval remains healthy"
    (= 42 (jnum->exact (jolt-compile-eval "(+ 20 22)" "user"))))

(printf "~a/~a interrupt nesting assertions passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
