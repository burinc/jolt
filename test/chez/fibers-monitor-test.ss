;; Fibers: monitoring a go block that dies (jolt-atc.5, the observable half of
;; swish's monitors, erlang.ss:434).
;;
;; Before this, a go body that threw and a go body that returned nil were
;; indistinguishable: both reported to async-report-uncaught! at best, closed
;; the result channel, and gave the reader nil. (fiber-monitor g) yields the
;; throwable if the body died and closes (nil) if it did not.
;;
;; Loads the host runtime plus the async overlay, the same combination
;; fibers-go-test uses, because the surface is a jolt-level var.
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(define (ev s) (jolt-compile-eval s "user"))
(define (jv-nth v i) (pvec-nth-d v i jolt-nil))

(define overlay-src
  (call-with-input-file "stdlib/clojure/core/async.clj"
    (lambda (p)
      (let loop ((acc '()))
        (let ((c (read-char p)))
          (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc))))))))
(jolt-load-string overlay-src)
(ev "(require '[clojure.core.async :refer [chan go <! >!! <!! timeout *go-backend* fiber-monitor]])")

(printf "== fiber monitors ==\n")

;; --- 1. a throwing body is distinguishable from a nil one -------------------
;; The bug this closes. Both give nil on the go channel; only the monitor
;; separates them.
(define r1 (ev "
(binding [*go-backend* :fiber]
  (let [boom (go (throw (ex-info \"boom\" {:k 1})))
        nily (go nil)
        bm   (<!! (fiber-monitor boom))
        nm   (<!! (fiber-monitor nily))]
    [(<!! boom) (<!! nily) (ex-message bm) (ex-data bm) (nil? nm)]))"))
(ok "1. both bodies give nil on the go channel"
    (and (jolt-nil? (jv-nth r1 0)) (jolt-nil? (jv-nth r1 1))))
(ok "1. the monitor reports the throwing body's message"
    (jolt=2 (jv-nth r1 2) "boom"))
(ok "1. ex-data survives, so it is the original throwable"
    (jolt=2 (jv-nth r1 3) (jolt-hash-map (keyword #f "k") 1)))
(ok "1. a body that returned nil monitors as nil" (jolt-truthy? (jv-nth r1 4)))

;; --- 2. a body that succeeds monitors as nil --------------------------------
(define r2 (ev "
(binding [*go-backend* :fiber]
  (let [g (go 42)]
    [(<!! g) (nil? (<!! (fiber-monitor g)))]))"))
(ok "2. the value still lands on the go channel" (jolt=2 (jv-nth r2 0) 42))
(ok "2. a successful body monitors as nil" (jolt-truthy? (jv-nth r2 1)))

;; --- 3. registering AFTER the fiber already died still resolves -------------
;; The race nobody can win from outside: a caller cannot check the state and
;; register atomically, so a fiber that finished in between must deliver inline
;; rather than leave the caller waiting forever. This is the job swish's
;; demonitor&flush does at the other end.
(define r3 (ev "
(binding [*go-backend* :fiber]
  (let [g (go (throw (ex-info \"late\" {})))]
    (Thread/sleep 300)
    (ex-message (<!! (fiber-monitor g)))))"))
(ok "3. a monitor registered after death still resolves" (jolt=2 r3 "late"))

;; --- 4. two monitors on one fiber both fire ---------------------------------
(define r4 (ev "
(binding [*go-backend* :fiber]
  (let [g  (go (throw (ex-info \"twice\" {})))
        m1 (fiber-monitor g)
        m2 (fiber-monitor g)]
    [(ex-message (<!! m1)) (ex-message (<!! m2))]))"))
(ok "4. every registered monitor fires"
    (and (jolt=2 (jv-nth r4 0) "twice") (jolt=2 (jv-nth r4 1) "twice")))

;; --- 5. a body that parks and THEN throws ------------------------------------
;; Exercises the resume path: the throw happens after a park, so the failure has
;; to survive the continuation round trip.
(define r5 (ev "
(binding [*go-backend* :fiber]
  (let [c (chan)
        g (go (let [v (<! c)] (throw (ex-info \"after park\" {:v v}))))]
    (Thread/sleep 200)
    (>!! c :go)
    (ex-message (<!! (fiber-monitor g)))))"))
(ok "5. a throw after a park is reported" (jolt=2 r5 "after park"))

;; --- 6. the :thread backend answers nil rather than erroring ----------------
;; Only the fiber backend has a fiber to monitor. Monitoring anything else has
;; to degrade to "not monitorable" (a closed channel), not raise, or callers
;; would have to know which backend produced the channel.
(define r6 (ev "
(binding [*go-backend* :thread]
  (let [g (go 7)]
    [(<!! g) (nil? (<!! (fiber-monitor g)))]))"))
(ok "6. a thread-backend go still returns its value" (jolt=2 (jv-nth r6 0) 7))
(ok "6. monitoring it degrades to nil, not an error" (jolt-truthy? (jv-nth r6 1)))
(ok "6. monitoring a plain channel degrades to nil"
    (jolt-truthy? (ev "(nil? (<!! (fiber-monitor (chan))))")))

(printf "\nfibers-monitor-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "fibers-monitor-test: PASS — a dying fiber is observable\n") (exit 0))
    (exit 1))
