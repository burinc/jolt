;; jolt.ffi errno gate (epic jolt-of08.2) — the public thread-correct errno
;; accessor. errno is a per-thread slot behind a libc function (__error on
;; macOS, __errno_location on Linux), so reading it from the calling thread is
;; the only correct way; a global would be wrong under threads.
;; Run: bin/jolt run test/chez/jolt-ffi-errno-test.clj (smoke.sh greps for
;; "JOLT-FFI-ERRNO-TEST OK").
(ns jolt-ffi-errno-test)

(require '[jolt.ffi :as ffi])
(require '[jolt.fibers :as fib])

(def failures (atom []))

(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; ENOENT is 2 and EBADF is 9 on every platform jolt runs on.
(ffi/defcfn c-access "access" [:string :int] :int)
(ffi/defcfn c-close "close" [:int] :int)

;; a failing syscall sets the calling thread's errno; read it immediately
(let [r (c-access "/definitely/not/here/jolt-errno-gate" 0)]
  (check-eq "access on a missing path fails" r -1)
  (check-eq "errno after ENOENT" (ffi/errno) 2))

(let [r (c-close -1)]
  (check-eq "close(-1) fails" r -1)
  (check-eq "errno after EBADF" (ffi/errno) 9))

;; another thread's failing call reads through ITS slot, not this thread's
(check-eq "a thread reads its own errno"
          @(future (c-access "/also/not/here/jolt-errno-gate" 0) (ffi/errno))
          2)

;; and on a fiber the carrier thread's slot answers (no park between the call
;; and the read)
(check-eq "errno on a fiber"
          (fib/join (fib/spawn (fn [] (c-close -1) (ffi/errno))))
          9)

;; errno-message renders a code, and the 0-arity renders the current errno
(check-eq "errno-message is a string" (string? (ffi/errno-message 2)) true)
(check-eq "errno-message is non-empty" (pos? (count (ffi/errno-message 2))) true)
(let [_ (c-close -1)]
  (check-eq "0-arity errno-message reads the current errno"
            (ffi/errno-message)
            (ffi/errno-message 9)))

(if (empty? @failures)
  (println "JOLT-FFI-ERRNO-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "JOLT-FFI-ERRNO-TEST FAILED:" (count @failures))))
