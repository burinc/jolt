;; run-trace-emit.ss — under tracing, the ring save/restore goes around calls that
;; can PUSH A FRAME, and nowhere else.
;;
;; The tail-frame history needs a save/restore pair around every non-tail call so a
;; returned subproblem's ribs stop showing up in a later backtrace (run-trace's
;; stale-frame case, and trace-smoke.sh's app.stale). That wrapper was applied in
;; emit-invoke-maybe-clone, which sits DOWNSTREAM of every branch of emit-invoke —
;; so it also wrapped the branches that lower to a single Chez primitive and can
;; therefore never enter a jolt fn prologue at all:
;;
;;   (aget ^doubles a ^long i)  ->  (flvector-ref (jolt-array-vec a) i)
;;
;; became
;;
;;   (let ((_tu$ (jolt-trace-save)))
;;     (let ((_tr$ (flvector-ref (jolt-array-vec a) i))) (jolt-trace-unwind! _tu$) _tr$))
;;
;; — two procedure calls and a let-bound flonum around one machine instruction. The
;; let binding is the expensive half: holding a flonum across a call forces it onto
;; the heap, so the whole surrounding unboxed fl+ chain re-boxes. Measured 19x on a
;; (dotimes [i n] (aset b i (+ (aget a i) 0.5))) loop, and 4.5-8.6x across every
;; phase of a real image pipeline, against ~3% for the ring push itself.
;;
;; So: a site that lowers to a primitive gets NO wrapper, and a site that really
;; applies a jolt fn still gets one. The second half is what keeps this from being
;; a silent revert of the stale-frame fix — run-trace-emit checks both directions.
;;
;;   chez --script host/chez/run-trace-emit.ss
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(define analyze (var-deref "jolt.analyzer" "analyze"))
(define numeric-annotate (var-deref "jolt.passes.numeric" "annotate"))
(define emit (var-deref "jolt.backend-scheme" "emit"))
(define set-trace-frames! (var-deref "jolt.backend-scheme" "set-trace-frames!"))
(define U ((var-deref "jolt.passes.types" "new-unit")))
((var-deref "jolt.backend-scheme" "set-emit-unit!") U)
((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)
(define (anode src) (analyze (make-analyze-ctx "user") (jolt-ce-read src)))
(define (emit-num src) (emit (numeric-annotate (anode src))))
(define (ev s) (jolt-compile-eval s "user"))
;; every check below is about what tracing emits, so tracing is ON throughout
(set-trace-frames! #t)
(define (saves? e) (gate-sub? e "jolt-trace-save"))
(define (unwinds? e) (gate-sub? e "jolt-trace-unwind!"))

;; NOTE every primitive case below is written in NON-TAIL position (the operand of
;; an enclosing form). A tail call never took the wrapper to begin with — see (8) —
;; so a case in tail position would pass no matter what the fix does.

;; --- (1) primitive-lowering sites take NO wrapper --------------------------------
;; Each of these is a single Chez primitive after lowering. None can reach a jolt
;; prologue, so none can leave a rib behind, so none needs the save/restore.
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (+ (aget a i) (aget a i))))")))
  (gate-check "(1) proven aget still lowers inline" (gate-sub? e "(flvector-ref (jolt-array-vec") #t)
  (gate-check "(1) proven aget takes no trace-save" (saves? e) #f)
  (gate-check "(1) proven aget takes no trace-unwind" (unwinds? e) #f))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (do (aset a i 7.25) 1.0)))")))
  (gate-check "(2) proven aset still lowers inline" (gate-sub? e "(flvector-set! (jolt-array-vec") #t)
  (gate-check "(2) proven aset takes no trace-save" (saves? e) #f))
;; the aget/aset pair inside a loop — the shape the regression was measured on
(let ((e (emit-num "(def _ (fn [^doubles a ^doubles b ^long n] (dotimes [i n] (aset b i (+ (aget a i) 0.5)))))")))
  (gate-check "(3) aget+aset+fl arithmetic loop still unboxes" (gate-sub? e "fl+") #t)
  (gate-check "(3) ...and takes no trace-save anywhere in it" (saves? e) #f))
;; proven flonum arithmetic (:num-kind) and a proven Math static (:fl-op)
(let ((e (emit-num "(def _ (fn [^double x ^double y] (+ (* x y) 1.0)))")))
  (gate-check "(4) proven fl arithmetic emits fl ops" (gate-sub? e "fl*") #t)
  (gate-check "(4) ...and takes no trace-save" (saves? e) #f))
(let ((e (emit-num "(def _ (fn [^double x] (+ (Math/sqrt x) 1.0)))")))
  (gate-check "(5) proven Math/sqrt emits flsqrt" (gate-sub? e "flsqrt") #t)
  (gate-check "(5) ...and takes no trace-save" (saves? e) #f))

;; --- (5b) UNTYPED numeric ops: the registry's :leaf? fact -------------------------
;; The branches above all need the inference to have proven a type. Untyped code
;; falls to the generic `nop` branch, where the op registry decides: a numeric op
;; only ever handles numbers, so jolt-n< / jolt-n+ / jolt-n-inc can't reach a
;; prologue either. This is most of what a loop over unhinted locals emits, and
;; leaving it out left the array loop still ~4.6x.
(let ((e (emit-num "(def _ (fn [a b] (if (< a b) (+ a 1) (dec b))))")))
  (gate-check "(5b) untyped < emits the generic numeric op" (gate-sub? e "jolt-n<") #t)
  (gate-check "(5b) ...and takes no trace-save" (saves? e) #f))
;; the counterexample the fact is drawn against: a COLLECTION op keeps its wrapper,
;; because a custom Indexed/Counted/ILookup impl is a user method with a prologue.
(let ((e (emit-num "(def _ (fn [c] (+ 1 (count c))))")))
  (gate-check "(5c) count over a collection emits jolt-count" (gate-sub? e "jolt-count") #t)
  (gate-check "(5c) ...and KEEPS its trace-save (may reach a user Counted impl)" (saves? e) #t))
(let ((e (emit-num "(def _ (fn [c i] (+ 1 (nth c i))))")))
  (gate-check "(5d) nth over a collection keeps its trace-save" (saves? e) #t))
;; `=` is excluded from :leaf? on purpose — jolt= on a deftype reaches a user equals.
(let ((e (emit-num "(def _ (fn [x y] (if (= x y) 1 2)))")))
  (gate-check "(5e) = keeps its trace-save (may reach a user equals)" (saves? e) #t))

;; --- (6) a real call still gets the wrapper --------------------------------------
;; The other direction, and the reason this gate exists in both halves: an ordinary
;; invoke of an unknown fn CAN enter a prologue and push a rib, so it must keep the
;; save/restore or a returned call's frames come back into later backtraces.
(let ((e (emit-num "(def _ (fn [f x] (+ 1 (f x))))")))
  (gate-check "(6) non-tail invoke of an unknown fn keeps trace-save" (saves? e) #t)
  (gate-check "(6) ...and its paired unwind" (unwinds? e) #t))
;; a non-tail call to a named user fn, the shape trace-smoke's app.stale exercises
(ev "(def user-fn (fn [x] x))")
(let ((e (emit-num "(def _ (fn [x] (+ 1 (user-fn x))))")))
  (gate-check "(7) non-tail call to a user fn keeps trace-save" (saves? e) #t))
;; TAIL position never took a wrapper (consuming the result would defeat TCO) —
;; unchanged by this fix, pinned so it stays that way.
(let ((e (emit-num "(def _ (fn [f x] (f x)))")))
  (gate-check "(8) tail call takes no trace-save (TCO)" (saves? e) #f))

;; --- (9) tracing OFF emits neither, on any shape ---------------------------------
(set-trace-frames! #f)
(let ((e (emit-num "(def _ (fn [f x] (+ 1 (f x))))")))
  (gate-check "(9) tracing off: no trace-save" (saves? e) #f)
  (gate-check "(9) tracing off: no trace-unwind" (unwinds? e) #f))
(set-trace-frames! #t)

(gate-summary "trace-emit")
