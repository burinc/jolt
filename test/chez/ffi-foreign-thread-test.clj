;; A :collect-safe callback arriving on a library's OWN thread, while the caller
;; is parked in an outbound call to the same library (issue #973).
;;
;; Both rows run the same C round trip (ffi-foreign-thread-helper.c): jolt asks
;; svc_call for an answer, the library's dispatch thread produces it by calling
;; back into jolt, and svc_call returns when it has it. The two rows differ in
;; ONE character of jolt: whether the outbound binding is :blocking.
;;
;; Without it the calling thread stays ACTIVE for the collector all the way
;; through C. The callback allocates — any real handler does — and an allocation
;; that reaches a trip point has to stop the world, which cannot happen while a
;; thread is parked in C and never reaches a safe point. So the callback waits
;; for svc_call, svc_call waits for the callback, and what the caller sees is
;; its own deadline expiring on the FIRST request. That is the whole of #973:
;; the reporter's `-m` path arrived at the call with a fuller heap than `-e`'s
;; did, which is why the collection landed inside the window there and not here.
;;
;; With :blocking the thread deactivates for the duration of the call, the
;; collection runs, and the callback answers.
(ns ffi-foreign-thread-test)

(require '[jolt.ffi :as ffi])

(def failures (atom []))
(defmacro check [label expr]
  `(when-not ~expr (swap! failures conj ~label)))

(ffi/load-library (System/getenv "JOLT_FFI_FOREIGN_THREAD_HELPER"))

(ffi/defcfn svc-start "svc_start" [:pointer] :int)
(ffi/defcfn req-path "req_path" [:pointer] :string)
;; The same C function bound twice. The only difference is the option.
(ffi/defcfn svc-call-active "svc_call" [:pointer :int] :int)
(ffi/defcfn svc-call-blocking "svc_call" [:pointer :int] :int :blocking)

(def served (atom []))

;; The handler allocates the way a handler does — build a response, walk the
;; path, intern some strings. Enough of it to reach a collect trip point, which
;; is the half of the round trip that needs the world stopped.
(defn handle [request]
  (let [path (req-path request)]
    (dotimes [_ 200] (dorun (map str (range 2000))))
    (swap! served conj path)
    200))

(def callback (ffi/foreign-callable handle [:pointer] :int :collect-safe))
(check "the library's dispatch thread started" (zero? (svc-start callback)))

(def path (ffi/string->ptr "/users/1/profile"))

;; ROW 1 — the witness. -1 is svc_call's own deadline: no answer in 1.5s, for a
;; callback whose work is milliseconds. If this row ever starts answering 200,
;; the collector no longer waits on a thread parked in a non-:blocking call, and
;; the advice in jolt/ffi.clj (and on #973) needs rewriting rather than patching.
(def active-answer (svc-call-active path 1500))
(check "a non-:blocking outbound call stalls a re-entrant callback (#973)"
       (= -1 active-answer))

;; ROW 2 — the same round trip, :blocking, and a deadline it has no reason to
;; need. It also drains row 1's stalled callback first (the helper numbers its
;; rounds), which is itself only possible because THIS call deactivates.
(def blocking-answer (svc-call-blocking path 60000))
(check ":blocking lets the callback collect and answer"
       (= 200 blocking-answer))

;; Both callbacks really ran on the foreign thread — row 1's completed once its
;; caller returned and stopped pinning the collector, row 2's straight away. The
;; row-1 timeout is a STALL, not a callback that never arrived.
(check "both requests reached the callback"
       (= ["/users/1/profile" "/users/1/profile"] @served))

(if (empty? @failures)
  (do (println "FFI-FOREIGN-THREAD-TEST OK") (flush) (System/exit 0))
  (do (doseq [failure @failures] (println "FAIL:" failure))
      (flush)
      (System/exit 1)))
