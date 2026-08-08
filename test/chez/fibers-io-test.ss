;; test/chez/fibers-io-test.ss — R8 gate: transparent IO parking (sockets +
;; poller half, epic jolt-nvpr.8). Run: chez --script test/chez/fibers-io-test.ss
;; (wired into `make fibers` after the R5 pool gate).
;;
;; R8 (fibers-r8-io.md) delivers the JDK's trick: every blocking socket call with
;; a non-blocking OS equivalent uses the non-blocking one when called from a
;; fiber, and blocks the OS thread otherwise. Same user-facing code either way.
;; stdlib/jolt/socket.clj sets O_NONBLOCK on every fd it hands out; on EAGAIN it
;; asks jolt.io-poller to wait for readiness — parking the fiber (jolt.host
;; seams from fibers-async.ss) when there is a current fiber, and blocking in a
;; private kevent/epoll_wait on this thread when there is not. One poller thread
;; per process (kqueue on macOS, epoll on Linux), its blocking wait declared
;; :blocking (__collect_safe).
;;
;; Why this matters HERE more than on the JVM: a blocking call PINTS its carrier,
;; and since continuations cannot migrate (R0(d)), the fibers queued behind it
;; are stranded and adding carriers cannot rescue them. Gate 1 is the whole
;; round in one check; gate 3 is the collect-safety check — a poller whose wait
;; is not collect-safe stops the WHOLE PROCESS from collecting for as long as it
;; waits, which is nearly always.
;;
;; Gate checks (spec, in order; item 6 — file offload — is the other half of the
;; round and is NOT in scope here):
;;   1. a fiber reading a socket with no data available PARKS, and a sibling
;;      fiber on the SAME carrier makes progress while it waits — the whole
;;      round in one check (red without the R8 socket layer).
;;   2. the same code path on a plain OS thread still blocks and still works.
;;   3. a FULL COLLECT succeeds while the poller is blocked in kevent/
;;      epoll_wait (the __collect_safe check — asserted, not assumed).
;;   4. 8 fibers each doing a socket round trip concurrently on ONE carrier:
;;      all 8 park at once, then all 8 complete with their own payloads — real
;;      parking, not serialized blocking.
;;   5. accept parks too: a fiber blocked in accept resumes when a connection
;;      arrives.
;;   6. existing jolt.socket behaviour off a fiber is untouched: a thread-mode
;;      round trip + close semantics, unchanged (the full socket-test.clj suite
;;      keeps running under `make test` / smoke).
;;
;; The gate loads the REAL loader (gate-boot + loader.ss + ffi.ss, in cli.ss's
;; order) so `require 'jolt.socket` resolves the real stdlib stack with its
;; transitive requires — the same combination the production CLI has. Timing is
;; only ever a floor relative to an in-run delay (gate 2), never an absolute
;; ceiling — see the flake history note at the top of fibers-test.ss.
;;
;; Unlike the R1-R5 gates (which pin the pool to 1 for determinism and drive
;; everything through sa-fiber-run-all), this gate runs with the R4/R5 carrier
;; THREAD live (jolt-fiber-ensure-carrier!): the poller's wake resumes a parked
;; fiber by enqueueing it on its carrier, and only the live carrier loop will
;; pick it up. It never pumps sa-fiber-run-all once the carrier is live.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
;; The real loader, in cli.ss's order: loader.ss seeds its loaded-ns from the
;; vars that exist AT LOAD TIME, so jolt.ffi's host vars (java/ffi.ss) must come
;; AFTER it, or a (require '[jolt.ffi]) skips stdlib/jolt/ffi.clj and the
;; defcfn macro never exists. gate-boot's image (target/dev/gate.so, when fresh)
;; already bakes both — the delete below makes the require pull the Clojure
;; side in that case too, so the gate behaves identically with and without the
;; image.
(load "host/chez/loader.ss")
(hashtable-delete! loaded-ns "jolt.ffi")
(set-source-roots!* '("jolt-core" "stdlib" "vendor/fs/src" "vendor/process/src" "vendor/grenadine/src"))
(load "host/chez/java/ffi.ss")

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

;; Bounded wait: a bug must FAIL the gate, never hang it.
(define (wait-until pred secs what)
  (let ((deadline (+ (now-secs) secs)))
    (let loop ()
      (if (pred)
          #t
          (if (> (now-secs) deadline)
              (begin (set! fails (+ fails 1))
                     (printf "  FAIL: ~a (timed out)\n" what) #f)
              (begin (sleep (make-time 'time-duration 1000000 0)) (loop)))))))

;; Compile+eval one jolt form in the "user" ns and return its value.
(define (ev s) (jolt-compile-eval s "user"))
(define (jv-nth v i) (pvec-nth-d v i jolt-nil))
(define (all-done? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'done) (all-done? (cdr fs)))))
(define (all-parked? fs)
  (or (null? fs) (and (eq? (jolt-fiber-state (car fs)) 'parked) (all-parked? (cdr fs)))))
(define (spawn-n n mk)
  (let loop ((i 0) (acc '()))
    (if (fx<? i n)
        (loop (fx+ i 1) (cons (mk i) acc))
        (reverse acc))))

(ev "(require 'jolt.socket)")
(ev "(require 'jolt.io-poller)")
(ev "(require '[clojure.core.async :refer [go chan <!! >!! *go-backend*]])")

;; One carrier, started as a real carrier thread — the R8 wake path (poller ->
;; sa-fiber-resume -> carrier run queue) needs it live. Never reset mid-file.
(jolt-fiber-carrier-count-set! 1)
(jolt-fiber-pool-reset!)
(jolt-fiber-ensure-carrier!)

(printf "== fibers-io: transparent socket parking on a fiber ==\n")

;; --- 1. THE whole round: a read with no data parks; a sibling progresses ------
(printf "\n== 1. a fiber read with no data parks; a sibling on the same carrier runs ==\n")
(ev "(def r8-ss (java.net.ServerSocket. 0))")
(ev "(def r8-port (.getLocalPort r8-ss))")
(ev "(def r8-client (java.net.Socket. \"127.0.0.1\" r8-port))")
(ev "(def r8-srv (.accept r8-ss))")
(ev "(def r8-srv-out (.getOutputStream r8-srv))")
;; the read thunk: one recv on a socket with NOTHING in it -> EAGAIN -> park
(define read-thunk
  (ev "(fn [] (let [c r8-client b (byte-array 64) n (.read (.getInputStream c) b 0 64)] (String. b 0 n \"UTF-8\")))"))
(define fa (sa-fiber-spawn read-thunk))
(define fb (sa-fiber-spawn (lambda () 4242)))
(ok "1. the two fibers share one carrier" (eq? (jolt-fiber-carrier fa) (jolt-fiber-carrier fb)))
(define fa-parked
  (wait-until (lambda () (eq? (jolt-fiber-state fa) 'parked)) 15.0 "1. the read fiber parked"))
(ok "1. the socket read parked the fiber (no data available)" fa-parked)
(define fb-done
  (wait-until (lambda () (eq? (jolt-fiber-state fb) 'done)) 15.0 "1. the sibling completed"))
(ok "1. the sibling fiber on the SAME carrier made progress while the read was parked"
    (and fb-done (eq? (jolt-fiber-state fa) 'parked)))
(ok "1. the sibling ran to completion" (eqv? (jolt-fiber-result fb) 4242))
(ev "(.write r8-srv-out (.getBytes \"pong\" \"UTF-8\") 0 4)")
(define fa-done
  (wait-until (lambda () (eq? (jolt-fiber-state fa) 'done)) 15.0 "1. the read resumed"))
(ok "1. the parked read resumed with the data"
    (and fa-done (string=? (jolt-fiber-result fa) "pong")))

;; --- 2. the same code path on a plain OS thread blocks and works --------------
(printf "\n== 2. the thread path still blocks and still works ==\n")
(ev "(def r8-ss2 (java.net.ServerSocket. 0))")
(ev "(def r8-port2 (.getLocalPort r8-ss2))")
(ev "(def r8-client2 (java.net.Socket. \"127.0.0.1\" r8-port2))")
(ev "(def r8-srv2 (.accept r8-ss2))")
;; a real OS thread delivers the data 300 ms late
(ev "(def r8-w (future (Thread/sleep 300) (.write (.getOutputStream r8-srv2) (.getBytes \"threaded\" \"UTF-8\") 0 8)))")
(define t2 (mono-nanos))
(define r2
  (ev "(let [b (byte-array 64) n (.read (.getInputStream r8-client2) b 0 64)] (String. b 0 n \"UTF-8\"))"))
(define el2 (/ (exact->inexact (- (mono-nanos) t2)) 1000000.0))
(ok "2. the thread-mode read returned the delayed data" (string=? r2 "threaded"))
;; floor, relative to the in-run writer delay: a read that returned without
;; waiting for the data would clock in well under this (a spin, or a wrong
;; EAGAIN-as-EOF); a slow machine only makes the wait longer
(ok "2. it actually waited for the writer (>= half the 300 ms delay)"
    (> el2 150.0))
(printf "   thread-path read took ~,1f ms for a 300 ms delayed write\n" el2)

;; --- 3. a full collect succeeds while the poller is blocked -------------------
(printf "\n== 3. a full collect succeeds while the poller is blocked in kevent/epoll_wait ==\n")
(ev "(def r8-ss3 (java.net.ServerSocket. 0))")
(ev "(def r8-port3 (.getLocalPort r8-ss3))")
(ev "(def r8-client3 (java.net.Socket. \"127.0.0.1\" r8-port3))")
(ev "(def r8-srv3 (.accept r8-ss3))")
(define read3
  (ev "(fn [] (let [c r8-client3 b (byte-array 64) n (.read (.getInputStream c) b 0 64)] (String. b 0 n \"UTF-8\")))"))
(define fc (sa-fiber-spawn read3))
(define fc-parked
  (wait-until (lambda () (eq? (jolt-fiber-state fc) 'parked)) 15.0 "3. the read fiber parked"))
(ok "3. the read fiber parked" fc-parked)
;; the poller entered its blocking wait (jolt.io-poller/waits increments each
;; round, immediately before kevent/epoll_wait) — so the collect below races a
;; thread that is (about to be / already) inside the blocking foreign call
(define w3
  (wait-until (lambda () (> (ev "@jolt.io-poller/waits") 0)) 15.0 "3. the poller entered its wait"))
(ok "3. the poller entered its blocking wait" w3)
(sleep (make-time 'time-duration 50000000 0))  ; let it settle into the wait
(define collect-ok
  (guard (e (#t (printf "  FAIL detail: collect raised ~a\n" (condition-message e)) #f))
    (collect (collect-maximum-generation))
    #t))
(ok "3. a full collect succeeded while the poller was blocked (wait is collect-safe)"
    collect-ok)
(ok "3. the parked fiber survived the collection" (eq? (jolt-fiber-state fc) 'parked))
(ev "(.write (.getOutputStream r8-srv3) (.getBytes \"z\" \"UTF-8\") 0 1)")
(define fc-done
  (wait-until (lambda () (eq? (jolt-fiber-state fc) 'done)) 15.0 "3. the read resumed after the collect"))
(ok "3. the fiber completed after the collect"
    (and fc-done (string=? (jolt-fiber-result fc) "z")))

;; --- 4. 8 fibers, one carrier: all park at once, all round-trip ---------------
(printf "\n== 4. 8 fibers, one carrier, all parked simultaneously, all round-trip ==\n")
(define r8-n 8)
(ev "(def r8-ss4 (java.net.ServerSocket. 0))")
(ev "(def r8-port4 (.getLocalPort r8-ss4))")
(ev "(def r8-clients (atom []))")
(ev "(dotimes [i 8] (swap! r8-clients conj (java.net.Socket. \"127.0.0.1\" r8-port4)))")
(ev "(def r8-srvs (atom []))")
(ev "(dotimes [i 8] (swap! r8-srvs conj (.getOutputStream (.accept r8-ss4))))")
(define r8-worker
  (ev "(fn [i] (let [c (nth @r8-clients i) b (byte-array 64) n (.read (.getInputStream c) b 0 64)] (String. b 0 n \"UTF-8\")))"))
(define f4s (spawn-n r8-n (lambda (i) (sa-fiber-spawn (lambda () (r8-worker i))))))
;; serialized blocking could never get here: with the carrier pinned by one
;; blocking recv, at most ONE fiber is 'parked at a time and the rest sit
;; 'ready behind it. All eight 'parked at one instant proves real parking.
(define all-parked4
  (wait-until (lambda () (all-parked? f4s)) 20.0 "4. all 8 fibers parked on their reads"))
(ok "4. all 8 fibers parked simultaneously on one carrier (real parking, not serialized blocking)"
    all-parked4)
(ev "(dotimes [i 8] (.write (nth @r8-srvs i) (.getBytes (str \"m\" i) \"UTF-8\") 0 2))")
(define all-done4
  (wait-until (lambda () (all-done? f4s)) 20.0 "4. all 8 round trips completed"))
(ok "4. all 8 round trips completed" all-done4)
(ok "4. every fiber got its own payload"
    (let loop ((i 0))
      (or (fx=? i r8-n)
          (and (string=? (jolt-fiber-result (list-ref f4s i))
                         (string-append "m" (number->string i)))
               (loop (fx+ i 1))))))

;; --- 5. accept parks too -------------------------------------------------------
(printf "\n== 5. a fiber blocked in accept parks and resumes on a connection ==\n")
(ev "(def r8-ss5 (java.net.ServerSocket. 0))")
(ev "(def r8-port5 (.getLocalPort r8-ss5))")
(define accept-thunk
  (ev "(fn [] (let [s (.accept r8-ss5)] (if (.isConnected s) :accepted :no)))"))
(define fd (sa-fiber-spawn accept-thunk))
(define fd-parked
  (wait-until (lambda () (eq? (jolt-fiber-state fd) 'parked)) 15.0 "5. accept parked"))
(ok "5. a fiber blocked in accept parked" fd-parked)
(ev "(java.net.Socket. \"127.0.0.1\" r8-port5)")   ; the arriving connection
(define fd-done
  (wait-until (lambda () (eq? (jolt-fiber-state fd) 'done)) 15.0 "5. accept resumed"))
(ok "5. accept resumed with a connection"
    (and fd-done (eq? (jolt-fiber-result fd) (keyword #f "accepted"))))

;; --- 6. jolt.socket off a fiber is unchanged ----------------------------------
(printf "\n== 6. existing socket behaviour off a fiber is untouched ==\n")
(define r6 (ev "
(let [ss (java.net.ServerSocket. 0)
      port (.getLocalPort ss)
      c (java.net.Socket. \"127.0.0.1\" port)
      s (.accept ss)
      out (.getOutputStream c)
      b1 (byte-array 16) b2 (byte-array 16)]
  (.write out (.getBytes \"hello over tcp\" \"UTF-8\") 0 14)
  (let [n1 (.read (.getInputStream s) b1 0 16)
        m1 (String. b1 0 n1 \"UTF-8\")]
    (.write (.getOutputStream s) (.getBytes \"pong\" \"UTF-8\") 0 4)
    (let [n2 (.read (.getInputStream c) b2 0 16)
          m2 (String. b2 0 n2 \"UTF-8\")]
      (let [r [m1 m2 (.isConnected c) (.isConnected s)
               (do (.close s) (.close c) (.close ss)
                   [(.isClosed c) (.isClosed s) (.isClosed ss)])]]
        r))))"))
(ok "6. client->server round trip" (string=? (jv-nth r6 0) "hello over tcp"))
(ok "6. server->client round trip" (string=? (jv-nth r6 1) "pong"))
(ok "6. both sides connected" (and (eq? (jv-nth r6 2) #t) (eq? (jv-nth r6 3) #t)))
(ok "6. close marks the sockets closed"
    (jolt=2 (jv-nth r6 4) (jolt-vector #t #t #t)))

(printf "\nfibers-io: ~a checks, ~a failures\n" total fails)
(exit (if (zero? fails) 0 1))
