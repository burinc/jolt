;; run-degraded-backtrace.ss — PSL R6 gate: with introspection suppressed
;; (sa-introspect-enabled? #f), a throw still surfaces type+message while the
;; introspect entry points return empty/#f and the backtrace renders without
;; continuation frames.
;;
;;   chez --script host/chez/run-degraded-backtrace.ss
;;
(load "host/chez/run-gate-harness.ss")

(define src
  "((fn boomer [x] (if (pos? x) (+ 0 (boomer (dec x)))
                       (throw (ex-info \"degraded-boom\" {:x x})))) 1)\n")

;; Capture a throw's raw value + continuation, exactly as the uncaught
;; reporter would see them.
(define (throw-and-capture)
  (guard (e (#t (list e (jolt-error-continuation e))))
    (jolt-compile-eval src "user")))

(define (render-err raw)
  (let ((p (open-output-string)))
    (jolt-render-throwable raw p)
    (get-output-string p)))

(define (has-sub? s sub) (if (gate-sub? s sub) #t #f))

;; Introspection ON: the walker sees live frames.
(let ((hit (throw-and-capture)))
  (gate-check "continuation frames visible with introspection on"
              (pair? (sa-continuation-frames (cadr hit))) #t)
  (gate-check "type+message with introspection on"
              (has-sub? (render-err (car hit)) "degraded-boom") #t))

;; Introspection OFF: walker empty, procedure info refuses, render survives
;; and still carries type+message.
(parameterize ((sa-introspect-enabled? #f))
  (let ((hit (throw-and-capture)))
    (gate-check "continuation frames suppressed by the flag"
                (null? (sa-continuation-frames (cadr hit))) #t)
    (gate-check "message survives introspection off"
                (has-sub? (render-err (car hit)) "degraded-boom") #t)
    (gate-check "backtrace render survives empty frames"
                (string? (or (jolt-backtrace-string (car hit)) "")) #t)
    (gate-check "procedure info refuses when introspection off"
                (eq? (sa-procedure-info (lambda (x) x)) #f) #t)))

(gate-summary "degraded-backtrace")
