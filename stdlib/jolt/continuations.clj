;; jolt.continuations — one-shot escape continuations.
;;
;; Chez captures continuations natively and jolt's runtime already runs on
;; them: the fiber park/resume switch, the throw site a backtrace is walked
;; from, the state image. This namespace hands the capability to jolt programs.
;; JVM Clojure has no equivalent and cannot have one — the JVM cannot capture
;; its stack — so code here is JOLT-ONLY by design, like jolt.scheme. It is
;; purely additive: no Clojure program is affected by its existence.
;;
;; What you get is an ESCAPE, not a re-entrant continuation:
;;
;;   (call-cc (fn [escape] ...))   ;; (escape v) makes call-cc answer v
;;   (letcc [escape] ...)          ;; the same, macro-shaped
;;
;; ONE-SHOT, and only inward. An escape is valid at most once, and only while
;; its own call-cc is still running. It is the `return` a Clojure program
;; otherwise writes with reduced/some or an exception, and it unwinds from any
;; depth — including out of a callback a library invoked, where reduced cannot
;; reach. It is not free: a capture costs about 86ns (host/chez/
;; continuations.ss records the breakdown), paid once per call-cc rather than
;; per iteration of whatever the capture wraps.
;;
;; Re-entrancy (resuming a computation that already finished, generators built
;; by re-invoking a saved continuation) is NOT supported and never silently half-works: every misuse
;; raises IllegalStateException naming the rule it broke.
;;
;;   (escape v) twice                      -> \"already been invoked\"
;;   (escape v) after call-cc returned     -> \"no longer live\"
;;   (escape v) from another thread/fiber  -> \"captured on another ...\"
;;
;; The third is not pedantry. Invoking a continuation captured on another
;; fiber transfers control into a stack segment this thread is not running;
;; unguarded it HANGS the process with no error at all.
;;
;; UNWINDING. An escape is a real exit, so everything between the capture and
;; the escape unwinds on the way out: a `finally` runs, innermost first, and a
;; `binding` is restored. This is the opposite of a fiber park, which
;; deliberately drops the `finally` winders because a park is not an exit.
;;
;; FIBERS. A park between the capture and the escape is fine — inside ONE
;; fiber. Yield, a channel op, a parked deref, jolt.socket IO: the scheduler
;; captures and restores the fiber's whole stack segment, so the escape is
;; still the same frame when the fiber resumes. What is refused is crossing
;; fibers or threads with an escape, which is the hang above.
(ns jolt.continuations)

(defn call-cc
  "Call f with an escape continuation and return f's value, or the value the
  escape was given.

  (call-cc (fn [escape] body...)) runs body. If body calls (escape v), call-cc
  answers v immediately, unwinding out of body — running any `finally` in
  between and restoring any `binding`. (escape) with no argument answers nil.
  If body returns normally instead, call-cc answers what body returned.

  The escape is ONE-SHOT and scoped to this call: valid at most once, and only
  while this call-cc is still running, only on the thread and fiber that
  captured it. Every other use raises IllegalStateException — see the
  namespace docs."
  [f]
  (jolt.host/call-cc f))

(defmacro letcc
  "(letcc [escape] body...) — call-cc with the escape bound by name.

  Equivalent to (call-cc (fn [escape] body...)); body's last form is the value
  when nothing escapes.

      (letcc [return]
        (doseq [x xs]
          (when (pred x) (return x)))
        nil)"
  [binding & body]
  (when-not (and (vector? binding) (= 1 (count binding)) (symbol? (first binding)))
    (throw (ex-info "jolt.continuations/letcc requires a [escape] binding of one symbol"
                    {:binding binding})))
  (list 'jolt.host/call-cc (concat (list 'fn binding) body)))

(defn escape-fn?
  "True when x is an escape continuation handed out by call-cc or letcc.

  Answers for an escape from any thread — asking about one is always allowed,
  even where invoking it would be refused."
  [x]
  (jolt.host/escape-fn? x))
