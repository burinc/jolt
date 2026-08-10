;; run-gosm.ss — R7 gate: go bodies that park cheaply (epic jolt-nvpr.9).
;;
;;   chez --script host/chez/run-gosm.ss
;;
;; test/chez/fibers-sm-test.ss gates the runtime with hand-written CPS'd bodies.
;; This gate covers the other half — the CPS pass in stdlib/clojure/core/async.clj
;; — through real `go` forms, and asserts three things:
;;
;;   1. WHICH REPRESENTATION was chosen, on the expansion itself (the way the
;;      devirt and numeric gates assert their transforms): a body that parks where
;;      the pass can see it expands to __sm-spawn/__sm-take, and one that does not
;;      expands to today's go-spawn with no __sm-* anywhere.
;;   2. The park counters: on the :fiber backend a rewritten park moves
;;      jolt-sm-parks and leaves jolt-fiber-chan-parks alone, and a park the pass
;;      could not rewrite does the opposite. Same body, one process.
;;   3. Values are unchanged — every shape gives the same answer on :thread and
;;      :fiber, including the ones that fall back.
;;
;; The fallbacks are gated as CAPABILITIES, not as omissions: a park through a
;; helper, inside a try, through eval, or in an alts! still works. That is what
;; makes the per-park-site choice safe, and it is why this round needs no
;; closed-world analysis and no eval/resolve bail rule.

(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define (ev s) (jolt-compile-eval s "user"))

;; The overlay defines go/go-loop and the pass; load it the way the R4 gate does.
(define overlay-src
  (call-with-input-file "stdlib/clojure/core/async.clj"
    (lambda (p)
      (let loop ((acc '()))
        (let ((c (read-char p)))
          (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc))))))))
(jolt-load-string overlay-src)

(ev "(require '[clojure.core.async
                :refer [go go-loop chan <! >! <!! >!! close! alts! *go-backend*]])")

;; --- 1. the representation, on the expansion --------------------------------
(printf "== 1. which representation the pass chose ==\n")
(define (go-expansion s) (ev (string-append "(pr-str (macroexpand '" s "))")))

(define x-lex (go-expansion "(go (<! ch))"))
(gate-check "lexical park -> __sm-spawn" (gate-sub? x-lex "__sm-spawn") #t)
(gate-check "lexical park -> __sm-take" (gate-sub? x-lex "__sm-take") #t)

(define x-none (go-expansion "(go (+ 1 2))"))
(gate-check "no park -> go-spawn" (gate-sub? x-none "go-spawn") #t)
(gate-check "no park -> no __sm-" (gate-sub? x-none "__sm-") #f)

;; A park the pass cannot see stays on today's path: the whole body compiles as it
;; always did, and the park captures at run time.
(define x-helper (go-expansion "(go (helper ch))"))
(gate-check "park through a call -> go-spawn" (gate-sub? x-helper "go-spawn") #t)
(gate-check "park through a call -> no __sm-" (gate-sub? x-helper "__sm-") #f)

;; alts! is out of scope this round — assert that plainly rather than leaving it
;; to be discovered.
(define x-alts (go-expansion "(go (alts! [ch]))"))
(gate-check "alts! not rewritten (scoped out)" (gate-sub? x-alts "__sm-") #f)

;; A body whose recur targets the body fn itself: the pass changes that fn's
;; arity, so it declines the whole body.
(define x-brecur (go-expansion "(go (do (<! ch) (recur)))"))
(gate-check "recur on the body fn -> declined" (gate-sub? x-brecur "__sm-") #f)

(define x-loop (go-expansion "(go-loop [] (let [v (<! ch)] (when v (recur))))"))
(gate-check "go-loop park -> __sm-take" (gate-sub? x-loop "__sm-take") #t)

;; A recur the pass OWNS, sitting inside a collection literal. The literal is left
;; whole, so the recur would land inside a continuation fn* and target that fn
;; instead of the loop — the same trap the opaque arm bails on, reached through the
;; arm above it. jolt accepts the form (the JVM does not: recur outside tail
;; position), and unfixed the rewritten body looped forever where the ordinary
;; expansion returns. Declining costs nothing here and keeps "the pass may cost a
;; park its cheap representation, never its meaning" true by construction.
(define x-vrecur (go-expansion "(go (loop [i 0] (if (< i 2) [(recur (inc i))] (<! ch))))"))
(gate-check "recur inside a collection literal -> declined" (gate-sub? x-vrecur "__sm-") #f)

;; The same trap reached through the four arms that CPS a subform. A recur emits a
;; bare call to the loop fn and throws k away, which is what a recur MEANS only in
;; tail position; an application argument, a let* init, a non-final do statement
;; and an if test each hand down a fresh continuation, and discarding that one
;; discarded the rest of the computation. Unfixed, each of these rewrote and
;; answered the take (100) where the ordinary expansion answers 102 / :after / :t.
;; Asserted on the EXPANSION, since "declined" is the fix, and on one VALUE below,
;; since agreeing with the ordinary expansion is the property the fix is for.
(define (recur-nontail-expansion shape)
  (go-expansion (string-append "(go (loop [i 0] (if (< i 2) " shape " (<! ch))))")))
(for-each
 (lambda (p)
   (gate-check (string-append "non-tail recur in " (car p) " -> declined")
               (gate-sub? (recur-nontail-expansion (cdr p)) "__sm-") #f))
 '(("an application argument" . "(inc (recur (inc i)))")
   ("a let* init"             . "(let [x (recur (inc i))] (inc x))")
   ("a do statement"          . "(do (recur (inc i)) :after)")
   ("an if test"              . "(if (recur (inc i)) :t :f)")))
;; and it still answers what the ordinary expansion answers
(gate-check "non-tail recur: the value is the ordinary expansion's"
            (ev (string-append
                 "(let [c (clojure.core.async/chan 1)]"
                 "  (clojure.core.async/>!! c 100)"
                 "  (binding [clojure.core.async/*go-backend* :fiber]"
                 "    (clojure.core.async/<!! (clojure.core.async/go"
                 "      (loop [i 0] (if (< i 2) (inc (recur (inc i))) (<! c)))))))"))
            102)

;; A special-form head may arrive clojure.core-QUALIFIED and still be that special
;; form to the analyzer (analyze-list*'s sf-name arm; verified here by evaluating
;; one). The pass must read it the same way, or it rebuilds the form as an
;; application and evaluates a binding vector / a catch clause / a quoted datum as
;; an expression, and hoists a park out of a fn body. Each of these produced
;; exactly that before sm-sf-head existed, so the checks are on the EXPANSION —
;; the values below would not all fail.
(gate-check "the analyzer does treat a qualified head as the special form"
            (ev "(clojure.core/let* [x 1] (+ x 1))") 2)
(define x-qlet (go-expansion "(go (clojure.core/let* [v (<! ch)] v))"))
(gate-check "qualified let*: not rebuilt as an application"
            (gate-sub? x-qlet "clojure.core/let*") #f)
(gate-check "qualified let*: rewritten like let*" (gate-sub? x-qlet "__sm-take") #t)
;; try / fn* are opaque, so the body is still CPS'd (__sm-spawn) but the form goes
;; through WHOLE: the catch clause and the fn body must survive verbatim and the
;; park must be left to the capture, not rewritten.
(define x-qtry (go-expansion "(go (clojure.core/try (<! ch) (catch Throwable e :c)))"))
(gate-check "qualified try: catch clause not evaluated"
            (gate-sub? x-qtry "(clojure.core/try (<! ch) (catch Throwable e :c))") #t)
(gate-check "qualified try: park left to capture" (gate-sub? x-qtry "__sm-take") #f)
(define x-qfn (go-expansion "(go (clojure.core/fn* [] (<! ch)))"))
(gate-check "qualified fn*: body not hoisted out of the closure"
            (gate-sub? x-qfn "(clojure.core/fn* [] (<! ch))") #t)
(gate-check "qualified fn*: park stays inside the closure" (gate-sub? x-qfn "__sm-take") #f)
;; quote has no children, so the pass never sees the park and declines the body
(define x-qquote (go-expansion "(go (clojure.core/quote (<! ch)))"))
(gate-check "qualified quote: datum not evaluated" (gate-sub? x-qquote "__sm-") #f)

;; A BACKTICK is jolt's other quoting special form. jolt's reader leaves it as
;; (syntax-quote datum) for the analyzer, where the JVM's reader expands it during
;; read — so it is absent from clojure.core/special-syms, which is where sm-opaque
;; came from. Missing, the datum fell to sm-cps's :else arm and was rebuilt as an
;; application: the park inside it became a REAL take and the value came back as a
;; syntax-quoted gensym. Both spellings, since the reader's is unqualified and a
;; macro's syntax-quote can qualify it.
(define x-sq (go-expansion "(go (list `(<! ch) :done))"))
(gate-check "syntax-quote: datum not evaluated" (gate-sub? x-sq "__sm-take") #f)
(gate-check "syntax-quote: datum survives whole" (gate-sub? x-sq "(<! ch)") #t)
(define x-qsq (go-expansion "(go (list (clojure.core/syntax-quote (<! ch)) :done))"))
(gate-check "qualified syntax-quote: datum not evaluated" (gate-sub? x-qsq "__sm-take") #f)
;; and the value, on both backends, against a channel that stays UNDRAINED
(define sq-val
  (ev (string-append
       "(let [c (clojure.core.async/chan 1)]"
       "  (clojure.core.async/>!! c 99)"
       "  (binding [clojure.core.async/*go-backend* :fiber]"
       "    (let [v (clojure.core.async/<!! (clojure.core.async/go (list `(<! c) :done)))]"
       "      (pr-str [v (clojure.core.async/poll! c)]))))")))
(gate-check "syntax-quote: datum is data, channel untouched" sq-val
            "[((clojure.core.async/<! user/c) :done) 99]")

;; A macro named inside a syntax-quoted datum must not be EXPANDED either. The
;; datum is data: the analyzer never expands it, so neither may the pass, and it
;; used to — sm-children stopped at `quote` and walked straight into a backtick,
;; and sm-targets-recur? macroexpands what it walks. An expander with a side
;; effect ran on a template; one that throws (a template holding a call the macro
;; rejects, which is legal inside a backtick) took the whole `go` form down with
;; it. Gated with a macro that throws, so the failure is unambiguous — unfixed
;; this line does not report a failed check, it kills the gate with the macro's
;; own message, which is the point.
(ev "(defmacro gosm-boom [] (throw (ex-info \"gosm-boom expanded\" {})))")
(define x-sqm (go-expansion "(go (list `(user/gosm-boom) (<! ch)))"))
(gate-check "syntax-quote: a macro in the datum is not expanded"
            (gate-sub? x-sqm "gosm-boom") #t)

;; --- 1b. the pass expands under the analyzer's &env ---------------------------
;; sm-cps does not merely classify with an expansion, it REBUILDS the body out of
;; it, so the expansion the pass takes has to be the one the analyzer would have
;; taken. The one-argument macroexpand binds &env to {}, and a macro that reads
;; &env then expanded one way inside a park-bearing go body and another way
;; everywhere else — silently, and only when the body happened to park where the
;; pass could see it. clojure.core/__macroexpand-env is the seam that carries the
;; locals through; the pass's :env is the &env map, extended as it binds.
;;
;; env-has? is expanded by the PASS (its argument parks, so the form is not
;; emitted whole) and reports whether the enclosing let's local was in scope at
;; expansion time. Under {} it answers false, which is the bug. Named qualified
;; because this file runs with the current namespace left at clojure.core.async
;; by the overlay load above, and the def lands in user.
(ev "(defmacro env-has? [s x] (list 'vector (contains? &env s) x))")
;; the contrast: the public one-argument macroexpand has no env to pass, so it
;; sees no locals at all. That is the answer the pass must NOT take.
(gate-check "&env: the env-less macroexpand sees no locals"
            (ev "(pr-str (macroexpand '(user/env-has? outer :v)))")
            "(vector false :v)")
(define x-env (go-expansion "(go (let [outer 1] (user/env-has? outer (<! ch))))"))
(gate-check "&env: the pass expands with the enclosing local in scope"
            (gate-sub? x-env "true") #t)
(gate-check "&env: and never reports it absent"
            (gate-sub? x-env "false") #f)
(gate-check "&env: the value agrees"
            (ev (string-append
                 "(let [c (clojure.core.async/chan 1)]"
                 "  (clojure.core.async/>!! c :v)"
                 "  (binding [clojure.core.async/*go-backend* :fiber]"
                 "    (pr-str (clojure.core.async/<!! (clojure.core.async/go"
                 "      (let [outer 1] (user/env-has? outer (<! c))))))))"))
            "[true :v]")
;; the same form outside go — what the pass has to agree with
(gate-check "&env: the ordinary expansion says the same"
            (ev "(pr-str (let [outer 1] (user/env-has? outer :v)))")
            "[true :v]")

;; loop* bindings are SEQUENTIAL — analyze-bindings threads each into the env the
;; next is analyzed in — so a later init means the name above it, not whatever the
;; enclosing scope calls that name. Built as a flat argument list to the loop fn,
;; every init landed outside the loop's scope instead. Pinned with an outer `a` in
;; scope, because that is the shape that comes back wrong rather than failing to
;; compile: unfixed this reads :outer-a and answers [:wrong :outer-a-inc].
(ev "(def a :outer-a)")
(define seq-init
  (ev (string-append
       "(let [c (clojure.core.async/chan 1)]"
       "  (clojure.core.async/>!! c 100)"
       "  (binding [clojure.core.async/*go-backend* :fiber]"
       "    (pr-str (clojure.core.async/<!! (clojure.core.async/go"
       "      (loop [a 1 b (inc a)]"
       "        (if (= b 2) [b (clojure.core.async/<! c)] [:wrong a])))))))")))
(gate-check "loop: a later init sees the binding above it" seq-init "[2 100]")
;; the same, with the init that the next one depends on PARKING
(define seq-init-park
  (ev (string-append
       "(let [c (clojure.core.async/chan 1)]"
       "  (clojure.core.async/>!! c 5)"
       "  (binding [clojure.core.async/*go-backend* :fiber]"
       "    (pr-str (clojure.core.async/<!! (clojure.core.async/go"
       "      (loop [a (clojure.core.async/<! c) b (inc a)] [a b]))))))")))
(gate-check "loop: a later init sees a PARKING binding above it" seq-init-park "[5 6]")

;; The set sm-opaque has to complement is the ANALYZER's, not the portable
;; clojure.core/special-syms it was written from. Every head analyze-list*
;; dispatches to a special form and the pass does not rewrite must be opaque to
;; it, or that head falls to sm-cps's :else arm and is rebuilt as an ordinary
;; application. Asserted against the live vars rather than restated here, so a
;; special form added to the analyzer fails THIS check on the day it lands
;; instead of miscompiling a go body later. syntax-quote is how the gap was
;; found: jolt lowers a backtick as a special form, the JVM's reader expands it
;; during read, so special-syms never named it.
(ev "(def sm-rewrites #{\"do\" \"let*\" \"if\" \"loop*\" \"recur\"})")
(gate-check "every analyzer special form is rewritten or opaque to the pass"
            (ev (string-append
                 "(pr-str (sort (remove (fn [s] (contains? clojure.core.async/sm-opaque (symbol s)))"
                 "                      (remove sm-rewrites jolt.analyzer/handled))))"))
            "()")
;; and the other direction is not asserted on purpose: sm-opaque names heads the
;; analyzer handles elsewhere (new, ., case*, deftype*, reify*, import*, catch,
;; finally), and listing extras only ever costs a park its cheap representation.
(gate-check "the pass rewrites exactly the five heads it claims"
            (ev (string-append
                 "(pr-str (sort (filter (fn [s] (contains? clojure.core.async/sm-opaque (symbol s)))"
                 "                      sm-rewrites)))"))
            "()")

;; --- 2. the counters, on the :fiber backend ---------------------------------
(printf "\n== 2. cheap parks vs captures, per park site ==\n")
;; A helper the pass cannot see through. Its <! parks by capturing.
(ev "(defn helper-take [c] (clojure.core.async/<! c))")
;; Force a park in every case: take from an EMPTY channel, delivered later from
;; this thread. Values arrive through a second channel so the body's own result
;; channel stays the thing under test.
;; Feeding a value and then asserting "that park happened" is a RACE: on a slower
;; machine the value can already be waiting when the take runs, which completes it
;; inline with no park at all — CI caught exactly that on the mixed body. So each
;; step WAITS for the counter it expects to move before feeding the next value, and
;; the wait is itself the assertion: if the mechanism regressed, it times out.
(define (mono-ns)
  (let ((t (current-time (quote time-monotonic))))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))

(define (wait-counter label get target)
  (let ((deadline (+ (mono-ns) (* 10 1000000000))))
    (let loop ()
      (cond ((>= (get) target) #t)
            ((> (mono-ns) deadline)
             (gate-check (string-append label " (timed out at " (number->string (get))
                         " waiting for " (number->string target) ")")
                         #f #t)
             #f)
            (else (sleep (make-time (quote time-duration) 2000000 0)) (loop))))))

(define (feed1 v) (ev (string-append "(clojure.core.async/>!! __ch " v ")")))

;; Spawn SRC on the :fiber backend against a fresh empty channel __ch, run STEPS
;; (each a thunk that waits for a counter then feeds), and return
;; [value cheap-delta capture-delta].
(define (fiber-run label src steps)
  (let ((c0 (jolt-sm-parks)) (p0 (jolt-fiber-chan-parks)))
    (ev (string-append
         "(binding [clojure.core.async/*go-backend* :fiber]"
         "  (clojure.core.async/go-spawn (fn* [] nil))"      ; start the carriers
         "  (def __ch (clojure.core.async/chan))"
         "  (def __out " src "))"))
    (for-each (lambda (st) (st c0 p0)) steps)
    ;; BOUNDED: with the pass broken a value may never arrive, and a bare <!! would
    ;; hang the gate instead of failing it — which is the one thing a gate must
    ;; never do.
    (let ((v (ev (string-append
                  "(first (clojure.core.async/alts!! "
                  "[__out (clojure.core.async/timeout 10000)]))"))))
      (list v (- (jolt-sm-parks) c0) (- (jolt-fiber-chan-parks) p0)))))

;; a step: wait for N cheap parks so far, then feed v
(define (after-cheap label n v)
  (lambda (c0 p0)
    (when (wait-counter (string-append label ": cheap park #" (number->string n))
                        jolt-sm-parks (+ c0 n))
      (when v (feed1 v)))))

;; a step: wait for N captures so far, then feed v
(define (after-capture label n v)
  (lambda (c0 p0)
    (when (wait-counter (string-append label ": capture #" (number->string n))
                        jolt-fiber-chan-parks (+ p0 n))
      (when v (feed1 v)))))

;; a park the pass rewrote: cheap, and nothing captured
(define r-lex
  (fiber-run "lexical" "(clojure.core.async/go (inc (clojure.core.async/<! __ch)))"
             (list (after-cheap "lexical" 1 "41"))))
(gate-check "lexical park: value" (car r-lex) 42)
(gate-check "lexical park: one cheap park" (cadr r-lex) 1)
(gate-check "lexical park: no capture" (caddr r-lex) 0)

;; a park the pass could not see: captured, and no cheap park
(define r-helper
  (fiber-run "helper" "(clojure.core.async/go (inc (helper-take __ch)))"
             (list (after-capture "helper" 1 "41"))))
(gate-check "park through a call: value" (car r-helper) 42)
(gate-check "park through a call: no cheap park" (cadr r-helper) 0)
(gate-check "park through a call: one capture" (caddr r-helper) 1)

;; both in ONE body: the choice really is per park site. Each value is fed only
;; once the park it belongs to has happened, so the counts are exact.
(define r-mixed
  (fiber-run "mixed"
             (string-append
              "(clojure.core.async/go"
              "  (let [a (clojure.core.async/<! __ch)"
              "        b (helper-take __ch)"
              "        c (clojure.core.async/<! __ch)]"
              "    [a b c]))")
             (list (after-cheap "mixed" 1 "1")
                   (after-capture "mixed" 1 "2")
                   (after-cheap "mixed" 2 "3"))))
(gate-check "mixed body: value" (jolt-pr-str (car r-mixed)) "[1 2 3]")
(gate-check "mixed body: two cheap parks" (cadr r-mixed) 2)
(gate-check "mixed body: one capture" (caddr r-mixed) 1)

;; a go-loop draining a channel: cheap parks only, however the feeding interleaves
(define r-loop
  (fiber-run "go-loop"
             (string-append
              "(clojure.core.async/go-loop [acc 0]"
              "  (let [v (clojure.core.async/<! __ch)]"
              "    (if (nil? v) acc (recur (+ acc v)))))")
             (list (after-cheap "go-loop" 1 "1")
                   (lambda (c0 p0) (feed1 "2") (feed1 "3")
                           (ev "(clojure.core.async/close! __ch)")))))
(gate-check "go-loop: summed" (car r-loop) 6)
(gate-check "go-loop: no captures" (caddr r-loop) 0)
(gate-check "go-loop: parked cheaply" (> (cadr r-loop) 0) #t)

;; --- 3. same values on both backends ----------------------------------------
(printf "\n== 3. the same answers on :thread and :fiber ==\n")
;; Each case is (label src) evaluated with a pre-filled channel, on both backends.
(define cases
  (list
   (list "lexical" "(go (inc (<! c)))" "5" "6")
   (list "let" "(go (let [v (<! c)] (* v 2)))" "5" "10")
   (list "if with a parking test" "(go (if (<! c) :yes :no))" "true" ":yes")
   (list "park through a call" "(go (inc (helper-take c)))" "5" "6")
   (list "park inside try" "(go (try (<! c) (catch Throwable e :caught)))" "5" "5")
   (list "park in a vector literal" "(go (vector (<! c) :b))" "1" "[1 :b]")
   ;; eval runs with its own current ns and cannot see the local c (nor can it on
   ;; the JVM) — park through a qualified global instead
   (list "park through eval" "(go (inc (eval '(clojure.core.async/<! user/evch))))" "5" "6")
   (list "alts!" "(go (first (alts! [c])))" "5" "5")
   (list "nested go" "(go (<! (go (<! c))))" "4" "4")
   ;; A local shadows a macro for the analyzer, so it has to shadow it for the
   ;; pass. sm-park-kind was always right here (resolve consults &env); the trap
   ;; is sm-expand, which calls the one-argument macroexpand and so has to be told
   ;; the enclosing locals. Unshadowed this reads 5 through the `or` MACRO, which
   ;; is what a pass with an empty :locals produces.
   (list "a local shadowing a macro name"
         "(let [or (fn [a b] :fn-called)] (go (or (<! c) :b)))" "5" ":fn-called")))

(for-each
 (lambda (cs)
   (let ((label (car cs)) (src (cadr cs)) (fill (caddr cs)) (want (cadddr cs)))
     (for-each
      (lambda (backend)
         (let ((got (ev (string-append
                         "(let [c (clojure.core.async/chan 1)]"
                         "  (def evch c)"
                         "  (clojure.core.async/>!! c " fill ")"
                         "  (binding [clojure.core.async/*go-backend* " backend "]"
                         "    (pr-str (clojure.core.async/<!! " src "))))"))))
           (gate-check (string-append label " on " backend) got want)))
      '(":thread" ":fiber"))))
 cases)

;; --- 4. finally does not run on a park --------------------------------------
;; R4's rule, restated for a CPS'd body: a park inside a try uses the capture
;; path, and the park-unwinding flag keeps the after-thunk from firing. The
;; finally must still run on a normal exit.
(printf "\n== 4. finally: not on a park, yes on exit ==\n")
(ev "(def ran (atom 0))")
(define fin
  (ev (string-append
       "(let [c (clojure.core.async/chan)]"
       "  (binding [clojure.core.async/*go-backend* :fiber]"
       "    (let [o (clojure.core.async/go"
       "              (try (clojure.core.async/<! c) (finally (swap! ran inc))))]"
       "      (Thread/sleep 60)"
       "      (let [mid @ran]"
       "        (clojure.core.async/>!! c 1)"
       "        (let [v (clojure.core.async/<!! o)]"
       "          (pr-str [mid @ran v]))))))")))
(gate-check "finally skipped on the park, ran once on exit" fin "[0 1 1]")

;; --- 5. what a park must not disturb ----------------------------------------
(printf "\n== 5. dynamic state across a park, and a blocking thread body ==\n")

;; A dynamic binding has to survive a CHEAP park. It does, but only because
;; jolt's `binding` expands through a try/finally, which is opaque to the pass —
;; so the park inside it takes the capture and the frame rides the continuation.
;; If that expansion ever loses its try, the pass would start rewriting across
;; the push/pop and the value here would come back :outer with nothing else
;; failing. Pin it: the park is forced (empty channel, fed after a wait) so this
;; cannot pass by completing inline.
(ev "(def ^:dynamic *gosm-x* :outer)")
(define dynv
  (fiber-run "binding"
             (string-append
              "(clojure.core.async/go"
              "  (binding [user/*gosm-x* :inner]"
              "    (let [v (clojure.core.async/<! __ch)] [v user/*gosm-x*])))")
             (list (after-capture "binding" 1 "1"))))
(gate-check "binding survives the park" (jolt-pr-str (car dynv)) "[1 :inner]")
(gate-check "binding: the park really happened" (caddr dynv) 1)

;; The :thread backend arm of __sm-take is the one case 3 never exercises: every
;; channel there is pre-filled, so the take completes without blocking. Force it
;; to block, and check the continuation still runs and the value is right.
(define thr
  (ev (string-append
       "(let [c (clojure.core.async/chan)]"
       "  (binding [clojure.core.async/*go-backend* :thread]"
       "    (let [o (clojure.core.async/go (inc (clojure.core.async/<! c)))]"
       "      (Thread/sleep 60)"
       "      (clojure.core.async/>!! c 41)"
       "      (pr-str (first (clojure.core.async/alts!! "
       "                       [o (clojure.core.async/timeout 10000)]))))))")))
(gate-check "a CPS'd body that BLOCKS on the thread backend" thr "42")

(gate-summary "gosm")
