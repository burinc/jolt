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

;; the profile chosen at generation time (make gambitweb PROFILE=...); regenerate
;; with gen-boot.ss to change what the bundle carries
(##include "boot-active.ss")

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
  ;; record renders as Class: message. A host-level failure goes through the same
  ;; class mapping and one-line folding the rest of the runtime uses
  ;; (gambit-error-tostring, host-vars.ss), so the REPL never prints a bare
  ;; "error" or a multi-line Gambit description.
  (or (guard (ee (#t #f))
        (let ((v (jolt-unwrap-throw e)))
          (and (jolt-ex-info-record? v)
               (string-append (jolt-ex-info-record-class-name v) ": "
                              (let ((m (jolt-ex-info-record-message v)))
                                (if (string? m) m (jolt-pr-readable m)))))))
      (guard (ee (#t #f)) (and (gambit-host-error? e) (gambit-error-tostring e)))
      (guard (ee (#t #f)) (let ((v (jolt-unwrap-throw e))) (jolt-pr-readable v)))
      "error"))

;; An expression's printed output belongs in the terminal that ran it, not in the
;; browser console, so each evaluation runs with stdout captured and the text is
;; emitted before the value (or before the error, if it printed and then threw).
(define (repl-step src)
  (let ((printed "") (value #f) (failure #f))
    (set! printed
      (call-with-output-string
        (lambda (port)
          (parameterize ((current-output-port port))
            (guard (e (#t (set! failure (throw-text e))))
              (set! value (jolt-eval-str src)))))))
    (when (> (string-length printed) 0) (js-emit "out" printed))
    (if failure (js-emit "error" failure) (js-emit "result" value))))

(js-ready!)
(let loop ()
  (let ((src (js-poll)))
    (if src
        (repl-step src)
        (thread-sleep! 0.05))
    (loop)))
