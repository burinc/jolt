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
(define (expand s) (ev (string-append "(pr-str (macroexpand '" s "))")))

(define x-lex (expand "(go (<! ch))"))
(gate-check "lexical park -> __sm-spawn" (gate-sub? x-lex "__sm-spawn") #t)
(gate-check "lexical park -> __sm-take" (gate-sub? x-lex "__sm-take") #t)

(define x-none (expand "(go (+ 1 2))"))
(gate-check "no park -> go-spawn" (gate-sub? x-none "go-spawn") #t)
(gate-check "no park -> no __sm-" (gate-sub? x-none "__sm-") #f)

;; A park the pass cannot see stays on today's path: the whole body compiles as it
;; always did, and the park captures at run time.
(define x-helper (expand "(go (helper ch))"))
(gate-check "park through a call -> go-spawn" (gate-sub? x-helper "go-spawn") #t)
(gate-check "park through a call -> no __sm-" (gate-sub? x-helper "__sm-") #f)

;; alts! is out of scope this round — assert that plainly rather than leaving it
;; to be discovered.
(define x-alts (expand "(go (alts! [ch]))"))
(gate-check "alts! not rewritten (scoped out)" (gate-sub? x-alts "__sm-") #f)

;; A body whose recur targets the body fn itself: the pass changes that fn's
;; arity, so it declines the whole body.
(define x-brecur (expand "(go (do (<! ch) (recur)))"))
(gate-check "recur on the body fn -> declined" (gate-sub? x-brecur "__sm-") #f)

(define x-loop (expand "(go-loop [] (let [v (<! ch)] (when v (recur))))"))
(gate-check "go-loop park -> __sm-take" (gate-sub? x-loop "__sm-take") #t)

;; --- 2. the counters, on the :fiber backend ---------------------------------
(printf "\n== 2. cheap parks vs captures, per park site ==\n")
;; A helper the pass cannot see through. Its <! parks by capturing.
(ev "(defn helper-take [c] (clojure.core.async/<! c))")
;; Force a park in every case: take from an EMPTY channel, delivered later from
;; this thread. Values arrive through a second channel so the body's own result
;; channel stays the thing under test.
(ev "(def fed (clojure.core.async/chan 1))")

(define (sm-parks) jolt-sm-parks)
(define (cap-parks) jolt-fiber-chan-parks)

;; (fiber-run SRC) evaluates SRC under the :fiber backend and returns
;; [value cheap-delta capture-delta].
(define (fiber-run label src feeder)
  (let ((c0 (sm-parks)) (p0 (cap-parks)))
    (ev (string-append
         "(def __res (clojure.core.async/chan 1))"))
    (ev (string-append
         "(binding [clojure.core.async/*go-backend* :fiber]"
         "  (clojure.core.async/go-spawn (fn* [] nil))"      ; start the carriers
         "  (def __ch (clojure.core.async/chan))"
         "  (def __out " src "))"))
    (feeder)
    (let ((v (ev "(clojure.core.async/<!! __out)")))
      (list v (- (sm-parks) c0) (- (cap-parks) p0)))))

(define (feed! . vs)
  (for-each (lambda (v)
              (ev (string-append "(clojure.core.async/>!! __ch " v ")")))
            vs))

;; a park the pass rewrote: cheap, and nothing captured
(define r-lex
  (fiber-run "lexical" "(clojure.core.async/go (inc (clojure.core.async/<! __ch)))"
             (lambda () (feed! "41"))))
(gate-check "lexical park: value" (car r-lex) 42)
(gate-check "lexical park: one cheap park" (cadr r-lex) 1)
(gate-check "lexical park: no capture" (caddr r-lex) 0)

;; a park the pass could not see: captured, and no cheap park
(define r-helper
  (fiber-run "helper" "(clojure.core.async/go (inc (helper-take __ch)))"
             (lambda () (feed! "41"))))
(gate-check "park through a call: value" (car r-helper) 42)
(gate-check "park through a call: no cheap park" (cadr r-helper) 0)
(gate-check "park through a call: one capture" (caddr r-helper) 1)

;; both in ONE body: the choice really is per park site
(define r-mixed
  (fiber-run "mixed"
             (string-append
              "(clojure.core.async/go"
              "  (let [a (clojure.core.async/<! __ch)"
              "        b (helper-take __ch)"
              "        c (clojure.core.async/<! __ch)]"
              "    [a b c]))")
             (lambda () (feed! "1" "2" "3"))))
(gate-check "mixed body: value" (jolt-pr-str (car r-mixed)) "[1 2 3]")
(gate-check "mixed body: two cheap parks" (cadr r-mixed) 2)
(gate-check "mixed body: one capture" (caddr r-mixed) 1)

;; a go-loop draining a channel: one cheap park per take, recur included
(define r-loop
  (fiber-run "go-loop"
             (string-append
              "(clojure.core.async/go-loop [acc 0]"
              "  (let [v (clojure.core.async/<! __ch)]"
              "    (if (nil? v) acc (recur (+ acc v)))))")
             (lambda () (feed! "1" "2" "3") (ev "(clojure.core.async/close! __ch)"))))
(gate-check "go-loop: summed" (car r-loop) 6)
(gate-check "go-loop: no captures" (caddr r-loop) 0)
(gate-check "go-loop: parked at least once" (> (cadr r-loop) 0) #t)

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
   ;; eval cannot see the local c, on jolt or on the JVM — park through a global
   ;; eval runs with its own current ns and cannot see the local c (nor can it on
   ;; the JVM) — park through a qualified global instead
   (list "park through eval" "(go (inc (eval '(clojure.core.async/<! user/evch))))" "5" "6")
   (list "alts!" "(go (first (alts! [c])))" "5" "5")
   (list "nested go" "(go (<! (go (<! c))))" "4" "4")))

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

(gate-summary "gosm")
