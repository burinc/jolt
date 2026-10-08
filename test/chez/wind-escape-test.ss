;; An interrupt must not skip a wind's cleanup. Run from repo root:
;;   chez --script test/chez/wind-escape-test.ss
;;
;; run-interruptible ends its body by jumping out of a timer interrupt, and Chez
;; checks for one at the edges of a dynamic-wind: between state set up outside the
;; wind and the winder's push, and between the body's return and the after-thunk,
;; the winder already popped. This sweeps run-interruptible's own handler across
;; every tick of each wind below (monitor-escape-test.ss does the monitors and
;; jolt-with-mutex) and checks the state the wind protects afterwards, plus this
;; thread's interrupt-disable and counted-lock depths.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "FAIL: ~a~n" name)))

(define sweep-ticks 300)

;; Run thunk under run-interruptible, interrupted from the start, with its handler
;; due after t ticks. 'interrupted when it escaped.
(define (interrupt-at t thunk)
  (let ((token (jolt-make-interrupt)))
    (jolt-interrupt! token)
    (guard (e ((let ((v (jolt-unwrap-throw e)))
                 (and (jolt-ex-info-record? v)
                      (string=? "Evaluation interrupted" (jolt-ex-info-record-message v))))
               'interrupted))
      (jolt-run-interruptible token (lambda () (set-timer t) (thunk))))))

;; Sweep thunk over every tick; good? is asked after each run. Reports the first
;; bad tick and answers #f, or answers #t once some tick has interrupted.
(define (sweep label thunk good?)
  (let loop ((t 1) (interrupted 0))
    (if (> t sweep-ticks)
        (or (positive? interrupted) (begin (printf "  ~a: never interrupted~n" label) #f))
        (let* ((d0 (sa-disable-count))
               (l0 (jolt-locks-held))
               (s0 (dyn-binding-stack))
               (r (guard (e (#t (list 'raised (let ((v (jolt-unwrap-throw e)))
                                                (if (condition? v)
                                                    (call-with-string-output-port (lambda (p) (display-condition v p)))
                                                    v)))))
                    (interrupt-at t thunk)))
               (good (and (not (and (pair? r) (eq? (car r) 'raised)))
                          (good?)
                          (= d0 (sa-disable-count))
                          (= l0 (jolt-locks-held))
                          (eq? s0 (dyn-binding-stack)))))
          (if good
              (loop (+ t 1) (if (eq? r 'interrupted) (+ interrupted 1) interrupted))
              (begin
                (printf "  ~a: tick ~a: disable ~a->~a locks ~a->~a bindings ~a result ~s~n"
                        label t d0 (sa-disable-count) l0 (jolt-locks-held)
                        (if (eq? s0 (dyn-binding-stack)) "kept" "LEFT CHANGED") r)
                #f))))))

(define (jeval src) (jolt-compile-eval src "user"))

;; 1. A user finally, as the back end emits it. Its own code runs unmasked (it may
;; park), so an escape can land inside it like anywhere else; what must not happen
;; is an escape between the body and the finally. The emitted text is taken as is
;; and a marker is set as the after-thunk's first act, right after the mask drop:
;; then "the body started" must imply "the finally was entered".
(define started #f)
(define fin-entered #f)
(jeval "(def ^:dynamic *x* 0)")
(def-var! "jolt.host" "scheme-started!" (lambda () (set! started #t) jolt-nil))
(def-var! "jolt.host" "scheme-noop" (lambda () jolt-nil))
(define finally-fn
  (let* ((scm (jolt-analyze-emit-form
                (jolt-ce-read "(fn [] (try (do (jolt.host/scheme-started!) :body) (finally (jolt.host/scheme-noop))))")
                "user"))
         (drop "(set-virtual-register! 7 (fx- (virtual-register 7) 1)))")
         (after-head "(lambda () (if (fx>? (virtual-register 7)")
         (i (let find ((k 0))
              (cond ((> (+ k (string-length after-head)) (string-length scm)) #f)
                    ((string=? after-head (substring scm k (+ k (string-length after-head)))) k)
                    (else (find (+ k 1))))))
         (j (and i (let find ((k i))
                     (cond ((> (+ k (string-length drop)) (string-length scm)) #f)
                           ((string=? drop (substring scm k (+ k (string-length drop))))
                            (+ k (string-length drop)))
                           (else (find (+ k 1))))))))
    (unless j (error 'wind-escape-test "the emitted finally no longer has the masked shape" scm))
    (eval (read (open-input-string
                  (string-append (substring scm 0 j) " (set! fin-entered #t)" (substring scm j (string-length scm)))))
          (interaction-environment))))
(ok "a user finally is never skipped between the body and the finally"
    (sweep "finally"
           (lambda () (set! started #f) (set! fin-entered #f) (jolt-invoke finally-fn))
           (lambda () (or (not started) fin-entered))))

;; 2. binding: push-thread-bindings, then the try/finally that pops. The sweep
;; checks the binding stack is back as it was after every run.
(define binding-fn (jeval "(fn [] (binding [*x* 1] (+ *x* 1)))"))
(ok "binding never leaves its frame"
    (sweep "binding" (lambda () (jolt-invoke binding-fn)) (lambda () #t)))

;; 3. dyn-with-frame, the runtime's own binding scope.
(ok "dyn-with-frame never leaves its frame"
    (sweep "dyn-with-frame" (lambda () (dyn-with-frame '() (lambda () 1))) (lambda () #t)))

;; 4. with-out-str binds *out* to a string port for its body.
(define out-cell (var-cell-lookup "clojure.core" "*out*"))
(define wos-fn (jeval "(fn [] (with-out-str (print 1)))"))
(ok "with-out-str never leaves *out* bound"
    (sweep "with-out-str" (lambda () (jolt-invoke wos-fn)) (lambda () #t)))

;; 5. pr's print-readably override, a per-thread register.
(define pr-fn (jeval "(fn [] (pr-str [1 \"a\"]))"))
(ok "pr never leaves the thread printing non-readably"
    (let ((before (virtual-register jolt-vreg-print-readably)))
      (sweep "print-readably" (lambda () (jolt-invoke pr-fn))
             (lambda () (equal? before (virtual-register jolt-vreg-print-readably))))))

;; 6. dosync's transaction marker.
(ok "dyn-with-txn never leaves *txn* set"
    (sweep "*txn*" (lambda () (dyn-with-txn 'txn (lambda () 1))) (lambda () (not (*txn*)))))

;; 7. A lazy seq's realization claim. A claim left behind makes every other
;; forcer wait on an owner that is gone; the next force here, from this thread,
;; would take it for its own and hide that, so the claim is read directly.
(define lazy-fn (jeval "(fn [] (let [s (lazy-seq (cons 1 (lazy-seq (cons 2 nil))))] [s (doall s)]))"))
(define last-seq #f)
(ok "forcing a lazy seq never leaves it claimed"
    (sweep "lazy-seq claim"
           (lambda () (let ((v (jolt-invoke lazy-fn))) (set! last-seq (jolt-nth v 0 jolt-nil)) v))
           (lambda ()
             ;; a fresh thread must be able to realize it
             (let ((m (make-mutex)) (c (make-condition)) (done #f))
               (when last-seq
                 (fork-thread (lambda () (jolt-invoke (jeval "doall") last-seq)
                                (with-mutex m (set! done #t) (condition-broadcast c))))
                 (with-mutex m
                   (let wait ((n 0))
                     (unless (or done (> n 20))
                       (condition-wait c m (make-time 'time-duration 50000000 0))
                       (wait (+ n 1))))))
               (or (not last-seq) done)))))

(printf "~a/~a wind escape assertions passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
