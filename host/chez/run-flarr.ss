;; run-flarr.ss — (aget ^doubles a i) reads the array's backing flvector unboxed
;; and typed :double, so surrounding arithmetic unboxes to fl+. A PROVEN-:long (or
;; fixnum-literal) index is emitted INLINE — (flvector-ref (jolt-array-vec a) i) —
;; so the value stays unboxed across the procedure boundary; an unproven index
;; keeps the (jolt-flaget a i) call, which owns the fixnum?/na-idx coercion. aset
;; mirrors it: a proven index AND a :double value inline (flvector-set! ... v),
;; returning the stored value (JVM contract); an int value keeps (jolt-flaset ...)
;; (it owns exact->inexact). Covers both ^doubles PARAMS and ^doubles LET bindings.
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")
(define analyze (var-deref "jolt.analyzer" "analyze"))
(define numeric-annotate (var-deref "jolt.passes.numeric" "annotate"))
(define emit (var-deref "jolt.backend-scheme" "emit"))
(define U ((var-deref "jolt.passes.types" "new-unit")))
((var-deref "jolt.backend-scheme" "set-emit-unit!") U)
((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)
(define (anode src) (analyze (make-analyze-ctx "user") (jolt-ce-read src)))
(define (emit-num src) (emit (numeric-annotate (anode src))))
;; how many times sub occurs in s (non-overlapping)
(define (gate-count s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0) (c 0))
      (cond ((> (+ i m) n) c)
            ((string=? (substring s i (+ i m)) sub) (loop (+ i m) (+ c 1)))
            (else (loop (+ i 1) c))))))
;; A ^doubles PARAM's backing flvector is bound once at the arity's entry
;; ((_av$N (jolt-array-vec-of a)), inside the named let so a fn-level recur
;; rebinds it) and every proven read/write indexes THAT — the accessor is not
;; re-read per access. A ^doubles LET binding (row 4) keeps the accessor.
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (aget a i)))")))
  (gate-check "(1) aget ^doubles,^long idx -> inline flvector-ref on the hoisted vector" (gate-sub? e "(flvector-ref _av$") #t)
  (gate-check "(1) ...the vector is bound at entry from the param" (gate-sub? e "(jolt-array-vec-of a)") #t)
  (gate-check "(1) ...and not re-read per access" (gate-sub? e "(flvector-ref (jolt-array-vec") #f)
  (gate-check "(1) ...proven idx NOT the jolt-flaget call" (gate-sub? e "jolt-flaget") #f)
  (gate-check "(1) ...not the generic jolt-nth" (gate-sub? e "jolt-nth") #f))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (+ (aget a i) (aget a i))))")))
  (gate-check "(2) arithmetic over ^doubles param reads -> fl+" (gate-sub? e "fl+") #t)
  (gate-check "(2) ...reading via the hoisted vector" (gate-sub? e "(flvector-ref _av$") #t))
;; shadowing: a let, a loop var or a nested fn param reusing the name reads ITS
;; array through the accessor, never the outer param's hoisted vector.
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (let [^doubles a (double-array 4)] (aget a i))))")))
  (gate-check "(2a) a ^doubles let shadowing the param reads its own array" (gate-sub? e "(flvector-ref (jolt-array-vec a)") #t)
  (gate-check "(2a) ...and not the hoisted vector" (gate-sub? e "(flvector-ref _av$") #f))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (loop [^doubles a (double-array 4) j 0] (if (< j 1) (recur a (inc j)) (aget a i)))))")))
  ;; the numeric pass does not type a ^doubles LOOP var, so this read is the
  ;; generic one; the property is that it never reaches the hoisted vector.
  (gate-check "(2b) a loop var shadowing the param never reads the hoisted vector" (gate-sub? e "(flvector-ref _av$") #f))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] ((fn [^doubles a] (aget a i)) (double-array 4))))")))
  (gate-check "(2c) a nested fn's own ^doubles param gets its own hoist" (gate-sub? e "(flvector-ref _av$") #t)
  (gate-check "(2c) ...bound from ITS param, twice in all" (gate-count e "(jolt-array-vec-of a)") 2))
(let ((e (emit-num "(def _ (fn [a i] (aget a i)))")))
  (gate-check "(3) untyped aget stays native jolt-nth (not flaget)" (gate-sub? e "jolt-flaget") #f)
  (gate-check "(3) ...uses jolt-nth" (gate-sub? e "jolt-nth") #t))
(let ((e (emit-num "(def _ (fn [^doubles a i] (aget a i)))")))
  (gate-check "(3b) ^doubles aget, UNTYPED idx keeps jolt-flaget call" (gate-sub? e "jolt-flaget") #t)
  (gate-check "(3b) ...untyped idx NOT inlined to flvector-ref" (gate-sub? e "(flvector-ref (jolt-array-vec") #f))
(let ((e (emit-num "(def _ (fn [m ^long i] (let [^doubles a (:pixels m)] (aget a i))))")))
  (gate-check "(4) ^doubles LET-binding aget,^long idx -> inline flvector-ref" (gate-sub? e "(flvector-ref (jolt-array-vec") #t))
(let ((e (emit-num "(def _ (fn [m ^long i] (let [^doubles a (:pixels m)] (+ (aget a i) (aget a i)))))")))
  (gate-check "(5) arithmetic over ^doubles let read -> fl+" (gate-sub? e "fl+") #t))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (aset a i 7.25)))")))
  (gate-check "(5a) aset ^doubles,^long idx,double val -> inline flvector-set! on the hoisted vector" (gate-sub? e "(flvector-set! _av$") #t)
  (gate-check "(5a) ...NOT the jolt-flaset call" (gate-sub? e "jolt-flaset") #f))
(let ((e (emit-num "(def _ (fn [m ^long i] (let [^doubles a (:pixels m)] (aset a i 7.25))))")))
  (gate-check "(5a-let) aset on a ^doubles LET binding keeps the accessor" (gate-sub? e "(flvector-set! (jolt-array-vec") #t))
(let ((e (emit-num "(def _ (fn [^doubles a ^long i] (aset a i 4)))")))
  (gate-check "(5b) aset ^doubles,int val keeps jolt-flaset (exact->inexact)" (gate-sub? e "jolt-flaset") #t))

;; --- runtime value semantics of jolt-flaget/jolt-flaset ---------------------------
;; Pin both index paths: the fixnum fast path (the hot case — loop counters are
;; :long) and the coercing slow path (flonum index floors via na-idx). Guards the
;; fast-path change against behavior drift: aset returns the stored value (JVM
;; contract), an int value stores as its double, and an out-of-range or negative
;; index raises (flvector-ref's range check = the array bounds contract).
(define (ev s) (jolt-compile-eval s "user"))
(gate-check "(6) aget fixnum index reads the stored double"
            (ev "(let [^doubles a (double-array 3)] (aset a 1 7.25) (aget a 1))") 7.25)
;; the hoisted vector follows a fn-level recur that passes a different array,
;; and a non-array ^doubles argument raises the JVM's checkcast on entry.
(ev "(defn flarr-recur [^doubles a ^long i] (if (< i 1) (recur (double-array 2 3.5) (inc i)) (aget a 0)))")
(gate-check "(6a) fn-level recur rebinds the hoisted vector" (ev "(flarr-recur (double-array 2 1.0) 0)") 3.5)
(gate-check "(6b) a non-array ^doubles arg raises ClassCastException on entry"
            (ev "(try (flarr-recur [1.0 2.0] 5) (catch ClassCastException e :cce))") (keyword #f "cce"))
(gate-check "(6c) a ^doubles param shadowed by a let reads the let's array"
            (ev "(let [f (fn [^doubles a ^long i] (let [^doubles a (double-array 2 9.0)] (aget a i)))] (f (double-array 2 1.0) 1))") 9.0)
(gate-check "(6) aset returns the stored value"
            (ev "(let [^doubles a (double-array 3)] (aset a 1 7.25))") 7.25)
(gate-check "(6) aset of an int value stores its double"
            (ev "(let [^doubles a (double-array 3)] (aset a 0 4) (aget a 0))") 4.0)
(gate-check "(6) aget flonum index 1.0 floors to slot 1"
            (ev "(let [^doubles a (double-array 3)] (aset a 1 7.25) (aget a 1.0))") 7.25)
(gate-check "(6) aget flonum index 1.5 floors to slot 1"
            (ev "(let [^doubles a (double-array 3)] (aset a 1 7.25) (aget a 1.5))") 7.25)
(gate-check "(6) aget out-of-range fixnum index raises (catchable)"
            (jolt-truthy? (ev "(try (let [^doubles a (double-array 3)] (aget a 5) false) (catch Throwable e true))")) #t)
(gate-check "(6) aget negative index raises (catchable)"
            (jolt-truthy? (ev "(try (let [^doubles a (double-array 3)] (aget a -1) false) (catch Throwable e true))")) #t)
(gate-check "(6) aset out-of-range index raises (catchable)"
            (jolt-truthy? (ev "(try (let [^doubles a (double-array 3)] (aset a 9 1.0) false) (catch Throwable e true))")) #t)

;; --- OOB exception class (JVM: ArrayIndexOutOfBoundsException) --------------
;; The proven ^doubles path relies on flvector-ref's own range check (a pre-check
;; costs ~1ns/access); the escaping Chez condition classifies at inspection time
;; as java.lang.ArrayIndexOutOfBoundsException. The generic path throws typed
;; with the JVM message. Both dispatch precisely: the parent class catches, an
;; unrelated exception class does not.
(gate-check "(7) typed-path OOB class is AIOOBE"
            (ev "(try (let [^doubles a (double-array 3)] (aget a 5)) (catch Throwable e (str (class e))))")
            "class java.lang.ArrayIndexOutOfBoundsException")
(gate-check "(7) typed-path OOB caught by (catch ArrayIndexOutOfBoundsException ...)"
            (ev "(try (let [^doubles a (double-array 3)] (aget a 5) :no) (catch ArrayIndexOutOfBoundsException e :aioobe))")
            (keyword #f "aioobe"))
(gate-check "(7) typed-path OOB caught by parent IndexOutOfBoundsException"
            (ev "(try (let [^doubles a (double-array 3)] (aset a 9 1.0) :no) (catch IndexOutOfBoundsException e :ioobe))")
            (keyword #f "ioobe"))
(gate-check "(7) typed-path OOB NOT caught by NullPointerException"
            (ev "(try (try (let [^doubles a (double-array 3)] (aget a 5) :no) (catch NullPointerException e :npe)) (catch Throwable t :outer))")
            (keyword #f "outer"))
(gate-check "(8) generic-path OOB class is AIOOBE"
            (ev "(try (aget (int-array 3) 5) (catch Throwable e (str (class e))))")
            "class java.lang.ArrayIndexOutOfBoundsException")
(gate-check "(8) generic-path OOB carries the JVM message"
            (ev "(try (aget (int-array 3) 5) (catch ArrayIndexOutOfBoundsException e (ex-message e)))")
            "Index 5 out of bounds for length 3")
(gate-check "(8) generic-path negative index"
            (ev "(try (aget (object-array 2) -1) (catch ArrayIndexOutOfBoundsException e (ex-message e)))")
            "Index -1 out of bounds for length 2")
(gate-check "(8) generic aset OOB throws AIOOBE"
            (ev "(try (aset (long-array 2) 9 1) (catch ArrayIndexOutOfBoundsException e :aioobe))")
            (keyword #f "aioobe"))
(gate-check "(8) byte-array aset OOB throws AIOOBE"
            (ev "(try (aset (byte-array 2) 5 (byte 1)) (catch ArrayIndexOutOfBoundsException e :aioobe))")
            (keyword #f "aioobe"))
(gate-check "(8) get on an array stays non-throwing OOB (returns default)"
            (ev "(get (int-array 3) 99 :d)") (keyword #f "d"))
(gate-summary "flarr")
