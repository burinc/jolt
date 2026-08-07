;; test/chez/fibers-state-test.ss — R2 gate for per-fiber dynamic state
;; (epic jolt-nvpr.3). Run: chez --script test/chez/fibers-state-test.ss
;; (wired in as part of `make fibers`).
;;
;; R0 settled the scope: `guard` and `parameterize` need nothing (a resumed
;; fiber's own handler catches; parameterize unwinds on park and reinstates on
;; resume). The one real bug: dyn-binding.ss pushes a binding frame by calling
;; the dyn-binding-stack thread parameter as a SETTER, and a setter write is
;; not undone by a continuation escape — a fiber that parks inside a binding
;; leaves its frames on the carrier, visible to the scheduler and to every
;; other fiber, and a second fiber popping its own frame can pop the parked
;; fiber's. set-chez-ns! leaks the same way. R2 fixes it by saving and
;; restoring the fiber's dynamic slice (dyn-binding-stack, current ns, *txn*)
;; in the switch.
;;
;; This file loads the FULL host runtime (rt.ss), because the slice tests need
;; the real dyn-binding-stack / chez-current-ns-param / *txn* parameters plus
;; the push/bind and STM seams. It drives them at host level
;; (jolt-push-thread-bindings / jolt-sync / jolt-ref-* / set-chez-ns!) rather
;; than through the overlay macros, so it stays a chez --script gate like
;; fibers-test.ss. The assert conventions match fibers-test.ss.
;;
;; Gate scenarios (spec, in order):
;;   1. `binding` in one fiber is invisible to another fiber on the same carrier.
;;   2. A parked fiber's binding frame is invisible to the scheduler — the exact
;;      R0 leak, as a regression test.
;;   3. A fiber's bindings are intact on resume after other fibers have pushed
;;      and popped their own.
;;   4. Two fibers on one carrier cannot join each other's transaction: a fiber
;;      inside a dosync parks, another fiber runs and sees no transaction.
;;   5. Spawn conveys the parent's bindings (and does NOT convey its *txn*).
;;   6. The current namespace follows the fiber, not the carrier.

(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(printf "== per-fiber dynamic state ==\n")

;; --- 1. binding in one fiber invisible to another on the same carrier -------
(define *x* (def-dynvar! "app" "*x*" 0))
(define vis-log '())
(define vis-f1
  (sa-fiber-spawn
    (lambda ()
      (jolt-push-thread-bindings (jolt-hash-map *x* 42))
      (set! vis-log (cons (jolt-var-get *x*) vis-log))     ; 42, its own binding
      (sa-fiber-yield)
      (set! vis-log (cons (jolt-var-get *x*) vis-log))     ; still 42 after f2 ran
      (jolt-pop-thread-bindings))))
(define vis-f2
  (sa-fiber-spawn
    (lambda ()
      (set! vis-log (cons (jolt-var-get *x*) vis-log)))))  ; must be the root 0
(sa-fiber-run-all)
(ok "1. binding invisible to a sibling fiber" (equal? vis-log '(42 0 42)))
(ok "1. no frame left on the carrier after both done" (eq? (dyn-binding-stack) '()))

;; --- 2. a parked fiber's frame is invisible to the scheduler (R0 leak) ------
;; Without the slice swap, (dyn-binding-stack) after the drain would be
;; ((FIBER-FRAME)) — the fiber parks INSIDE the binding, the setter write
;; survives the continuation escape, and the leak is visible to the caller.
(define *y* (def-dynvar! "app" "*y*" 0))
(define leak-f
  (sa-fiber-spawn
    (lambda ()
      (jolt-push-thread-bindings (jolt-hash-map *y* 7))
      (jolt-fiber-park!)            ; park inside the binding
      (jolt-pop-thread-bindings))))
(sa-fiber-run-all)
(ok "2. parked fiber's frame invisible to the scheduler" (eq? (dyn-binding-stack) '()))
(ok "2. parked fiber's value not visible to the caller" (= (jolt-var-get *y*) 0))
(sa-fiber-resume leak-f)
(sa-fiber-run-all)
(ok "2. fiber that parked inside a binding completes"
    (eq? (jolt-fiber-state leak-f) 'done))

;; --- 3. bindings intact on resume after other fibers pushed and popped ------
(define *z* (def-dynvar! "app" "*z*" 0))
(define intact-log '())
(define z-f1
  (sa-fiber-spawn
    (lambda ()
      (jolt-push-thread-bindings (jolt-hash-map *z* 100))
      (set! intact-log (cons (jolt-var-get *z*) intact-log))   ; 100
      (sa-fiber-yield)
      ;; z-f2 has pushed and popped its own 200-frame meanwhile
      (set! intact-log (cons (jolt-var-get *z*) intact-log))   ; still 100
      (jolt-pop-thread-bindings))))
(define z-f2
  (sa-fiber-spawn
    (lambda ()
      (jolt-push-thread-bindings (jolt-hash-map *z* 200))
      (set! intact-log (cons (jolt-var-get *z*) intact-log))   ; 200
      (jolt-pop-thread-bindings))))
(sa-fiber-run-all)
(ok "3. bindings intact on resume after sibling push/pop"
    (equal? intact-log '(100 200 100)))
(ok "3. top-level stack clean after the round" (eq? (dyn-binding-stack) '()))

;; --- 4. two fibers on one carrier cannot join each other's transaction ------
;; t1 parks INSIDE a dosync (ref-set r 1, park, ref-set r 2). On park the
;; parameterize unwinds *txn* and with-mutex releases stm-lock, and the slice
;; swap keeps the carrier's *txn* #f — t2 runs and sees NO transaction; if it
;; had inherited t1's *txn*, t2's jolt-sync would have joined it (ref-set into
;; t1's log) instead of starting its own.
(define r (jolt-ref-new 0))
(define t1
  (sa-fiber-spawn
    (lambda ()
      (jolt-sync
        (lambda ()
          (jolt-ref-set r 1)
          (jolt-fiber-park!)
          (jolt-ref-set r 2)))
      't1-committed)))
(sa-fiber-run-all)
(ok "4. t1 parked inside its txn" (eq? (jolt-fiber-state t1) 'parked))
(ok "4. no txn on the carrier while t1 is parked" (eq? (*txn*) #f))
(ok "4. t1's write not committed while parked" (= (jolt-ref-val r) 0))
(define txn-log '())
(define t2
  (sa-fiber-spawn
    (lambda ()
      (set! txn-log (cons (jolt-txn-running?) txn-log))        ; #f — cannot join
      (jolt-sync (lambda () (jolt-ref-set r 9)))               ; its OWN txn
      (set! txn-log (cons (jolt-txn-running?) txn-log)))))     ; #f — over, not joined
(sa-fiber-run-all)
(ok "4. t2 sees no transaction while t1 is parked" (equal? txn-log '(#f #f)))
(ok "4. t2's own txn committed" (= (jolt-ref-val r) 9))
(sa-fiber-resume t1)
(sa-fiber-run-all)
(ok "4. t1 resumed inside ITS txn and committed last" (= (jolt-ref-val r) 2))
(ok "4. t1 completed" (eq? (jolt-fiber-state t1) 'done))

;; --- 5. spawn conveys the parent's bindings (and NOT its *txn*) ------------
(define *w* (def-dynvar! "app" "*w*" 0))
(define conv-log '())
(define conv-f
  (sa-fiber-spawn
    (lambda ()
      (jolt-push-thread-bindings (jolt-hash-map *w* 5))
      (let ((child
             (sa-fiber-spawn
               (lambda () (set! conv-log (cons (jolt-var-get *w*) conv-log))))))
        (sa-fiber-yield)                                    ; let the child run
        (set! conv-log (cons 'parent-ok conv-log)))
      (jolt-pop-thread-bindings))))
(sa-fiber-run-all)
(ok "5. spawn conveys the parent's bindings" (equal? conv-log '(parent-ok 5)))
(ok "5. parent's frame popped at the end" (= (jolt-var-get *w*) 0))
(define conv-txn #t)
(define txn-parent
  (sa-fiber-spawn
    (lambda ()
      (jolt-sync
        (lambda ()
          (let ((child
                 (sa-fiber-spawn
                   (lambda () (set! conv-txn (jolt-txn-running?))))))
            (sa-fiber-yield)))))))
(sa-fiber-run-all)
(ok "5. spawn does NOT convey the parent's txn" (eq? conv-txn #f))

;; --- 6. the current namespace follows the fiber, not the carrier ------------
(define ns-log '())
(define ns-f1
  (sa-fiber-spawn
    (lambda ()
      (set-chez-ns! "app.a")
      (set! ns-log (cons (chez-current-ns) ns-log))
      (sa-fiber-yield)
      (set! ns-log (cons (chez-current-ns) ns-log)))))
(define ns-f2
  (sa-fiber-spawn
    (lambda ()
      (set! ns-log (cons (chez-current-ns) ns-log))      ; must be the carrier's "user"
      (set-chez-ns! "app.b"))))
(sa-fiber-run-all)
(ok "6. namespace follows the fiber, not the carrier"
    (equal? ns-log '("app.a" "user" "app.a")))
(ok "6. carrier ns restored to the scheduler's after the round"
    (string=? (chez-current-ns) "user"))

(printf "\nfibers-state-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-state-test: PASS — per-fiber dynamic state\n") (exit 0))
    (exit 1))
