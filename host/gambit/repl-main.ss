;; repl-main.ss — the browser REPL entry for the js target (jolt-mj95 G5).
;;
;; Build (from host/gambit/):
;;   $(brew --prefix gambit-scheme)/bin/gsc -target js -exe -o jolt-web.js repl-main.ss
;;
;; Design: JS never calls INTO Scheme (crossing the trampoline from a JS event
;; handler is fragile); instead the page pushes input strings onto a JS queue
;; and a Scheme green thread polls it. Gambit's js runtime schedules
;; thread-sleep! via setTimeout, so the poll loop yields to the browser event
;; loop and the page stays responsive. Results go back through a JS callback.
;;
;; Page contract (define these BEFORE loading the bundle):
;;   globalThis.joltQueue = []            // page pushes source strings
;;   globalThis.joltOut(kind, text)       // "ready" | "result" | "error"

(##include "boot.ss")

(define (js-ready!)
  (##inline-host-statement
   "globalThis.joltOut && globalThis.joltOut('ready','');"))

(define (js-poll)
  ;; next queued source string, or #f
  (##inline-host-expression
   "@host2scm@((globalThis.joltQueue && globalThis.joltQueue.length) ? globalThis.joltQueue.shift() : false)"))

(define (js-emit kind text)
  (##inline-host-statement
   "globalThis.joltOut && globalThis.joltOut(@scm2host@(@1@), @scm2host@(@2@));"
   kind text))

(define (jolt-eval-str src)
  (jolt-pr-readable (jolt-compile-eval src "user")))

(define (throw-text e)
  ;; a jolt throw is a condition wrapping the jolt value (rt-core); an ex-info
  ;; record renders as Class: message. Plain conditions carry a message.
  (or (guard (ee (#t #f))
        (let ((v (jolt-unwrap-throw e)))
          (and (jolt-ex-info-record? v)
               (string-append (jolt-ex-info-record-class-name v) ": "
                              (let ((m (jolt-ex-info-record-message v)))
                                (if (string? m) m (jolt-pr-readable m)))))))
      (guard (ee (#t #f))
        (let ((m (condition-message e))) (and (string? m) m)))
      "error"))

(define (repl-step src)
  (guard (e (#t (js-emit "error" (throw-text e))))
    (js-emit "result" (jolt-eval-str src))))

(js-ready!)
(let loop ()
  (let ((src (js-poll)))
    (if src
        (repl-step src)
        (thread-sleep! 0.05))
    (loop)))
