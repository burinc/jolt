;; run-directcall.ss — the call shapes a --direct-link build lowers to a direct
;; Scheme call, and the guards that keep them sound (backend_scheme emit):
;;   * a SEED var (clojure.core and the other namespaces the runtime image boots
;;     with) is called through its root procedure, bound once at load — no
;;     var-cell-deref, no jolt-invokeN — when jolt.host/seed-callable? says so:
;;     the root is a procedure whose arity mask admits the call, the var is not
;;     ^:dynamic/^:redef, and the app has not redefined it. Off direct-link, and
;;     for a wrong arity, a non-procedure root or an app var, the site keeps the
;;     var-routed jolt-invoke.
;;   * an interop call on an UNPROVEN receiver tests the receiver at the site and
;;     takes the string/keyword direct form, with record-method-dispatch as the
;;     slow arm; a method with no direct form keeps the plain dispatch.
;;   * the unchecked-* family lowers to its helpers (jolt-uncadd2, jolt-uncinc)
;;     and unchecked-long/-int are casts that type their result :long, so a loop
;;     written in the hinted-Clojure idiom keeps fixnum counters.
;;   * `case` compares keyword/nil/boolean constants with identical?.
;;
;;   chez --script host/chez/run-directcall.ss
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define analyze          (var-deref "jolt.analyzer" "analyze"))
(define numeric-annotate (var-deref "jolt.passes.numeric" "annotate"))
(define emit-top-form    (var-deref "jolt.backend-scheme" "emit-top-form"))
(define set-direct-link! (var-deref "jolt.backend-scheme" "set-direct-link!"))
(define seed-callable?   (var-deref "jolt.host" "seed-callable?"))
(define U ((var-deref "jolt.passes.types" "new-unit")))
((var-deref "jolt.backend-scheme" "set-emit-unit!") U)
((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)

(define (anode src) (analyze (make-analyze-ctx "user") (jolt-ce-read src)))
(define (emit-dl src)
  (set-direct-link! #t)
  (let ((e (emit-top-form (numeric-annotate (anode src)))))
    (set-direct-link! #f)
    e))
(define (emit-nodl src) (emit-top-form (numeric-annotate (anode src))))
(define (run-emit scm) (eval (read (open-input-string scm)) (interaction-environment)))
(define (ev s) (jolt-compile-eval s "user"))
(define (call name . args) (apply jolt-invoke (var-deref "user" name) args))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

;; ---- seed direct-link ------------------------------------------------------
(let ((e (emit-dl "(def usetrue (fn [x] (true? x)))")))
  (gate-check "seed call binds the root at load" (gate-sub? e "(jolt-seed-root (jolt-var \"clojure.core\" \"true?\"))") #t)
  (gate-check "seed call is a direct application, not jolt-invoke1" (gate-sub? e "jolt-invoke1") #f)
  (gate-check "seed call does not deref the var cell" (gate-sub? e "var-cell-deref") #f)
  (run-emit e)
  (gate-check "direct seed call answers true" (call "usetrue" #t) #t)
  (gate-check "direct seed call answers false" (call "usetrue" 1) #f))
(let ((e (emit-nodl "(def usetrue2 (fn [x] (true? x)))")))
  (gate-check "off direct-link the site stays var-routed" (gate-sub? e "jolt-invoke1") #t)
  (gate-check "off direct-link no root is bound" (gate-sub? e "jolt-seed-root") #f))
(let ((e (emit-dl "(def wrongarity (fn [x] (true? x 1)))")))
  (gate-check "a wrong arity keeps jolt-invoke (it owns the ArityException)" (gate-sub? e "jolt-invoke2") #t)
  (gate-check "a wrong arity binds no root" (gate-sub? e "jolt-seed-root") #f))
(let ((e (emit-dl "(def nonproc (fn [] (*print-length*)))")))
  (gate-check "a non-procedure root keeps jolt-invoke" (gate-sub? e "jolt-invoke0") #t)
  (gate-check "a non-procedure root binds no root" (gate-sub? e "jolt-seed-root") #f))
(ev "(defn helper [x] (+ x 1))")
(let ((e (emit-dl "(def useapp (fn [] (helper 1)))")))
  (gate-check "an app var is not a seed var" (gate-sub? e "jolt-seed-root") #f))
(gate-check "seed-callable?: clojure.core/true? at 1 arg" (seed-callable? jolt-nil "clojure.core" "true?" 1) #t)
(gate-check "seed-callable?: wrong arity refused" (jolt-nil? (seed-callable? jolt-nil "clojure.core" "true?" 3)) #t)
(gate-check "seed-callable?: a dynamic var refused" (jolt-nil? (seed-callable? jolt-nil "clojure.core" "*print-length*" 0)) #t)
(gate-check "seed-callable?: an app var refused" (jolt-nil? (seed-callable? jolt-nil "user" "helper" 1)) #t)
(gate-check "seed-callable?: an unknown var refused" (jolt-nil? (seed-callable? jolt-nil "clojure.core" "no-such-fn-here" 1)) #t)
(gate-check "jolt-seed-root raises on a non-procedure root"
            (raises? (lambda () (jolt-seed-root (jolt-var "clojure.core" "*print-length*")))) #t)

;; ---- the unhinted interop guard --------------------------------------------
(let ((e (emit-dl "(def uselen (fn [s] (.length s)))")))
  (gate-check "unhinted .length tests for a string at the site" (gate-sub? e "(string? _ht$") #t)
  (gate-check "unhinted .length takes the direct form" (gate-sub? e "(string-length _ht$") #t)
  (gate-check "unhinted .length keeps the generic slow arm" (gate-sub? e "record-method-dispatch") #t)
  (run-emit e)
  (gate-check "a string receiver answers" (call "uselen" "abcd") 4)
  (gate-check "a StringBuilder receiver still reaches the generic arm"
              (ev "(user/uselen (doto (StringBuilder.) (.append \"ab\")))") 2))
(let ((e (emit-dl "(def usecharat (fn [s i] (.charAt s i)))")))
  (gate-check "unhinted .charAt takes the direct form" (gate-sub? e "(string-ref _ht$") #t)
  (run-emit e)
  (gate-check "unhinted .charAt on a string answers" (call "usecharat" "abc" 1) #\b))
(let ((e (emit-dl "(def usename (fn [k] (.getName k)))")))
  (gate-check "unhinted .getName tests for a keyword" (gate-sub? e "(keyword-t? _ht$") #t)
  (gate-check "unhinted .getName takes the keyword direct form" (gate-sub? e "(keyword-t-name _ht$") #t)
  (run-emit e)
  (gate-check "a keyword receiver answers" (call "usename" (keyword "a" "b")) "b"))
(let ((e (emit-dl "(def usefoo (fn [x] (.frobnicate x)))")))
  (gate-check "a method with no direct form keeps the plain dispatch" (gate-sub? e "_ht$") #f)
  (gate-check "...as record-method-dispatch" (gate-sub? e "record-method-dispatch") #t))
;; receiver and args are evaluated once each, in order
(ev "(def calls (atom []))")
(ev "(defn note [v] (swap! calls conj v) v)")
(let ((e (emit-dl "(def order (fn [] (.indexOf (note \"hello\") (note \"l\"))))")))
  (run-emit e)
  (gate-check "guarded site evaluates receiver then args once" (call "order") 2)
  (gate-check "...in source order" (jolt=2 (ev "@user/calls") (jolt-vector "hello" "l")) #t))

;; ---- the unchecked family --------------------------------------------------
(let ((e (emit-dl "(def uadd (fn [a b] (unchecked-add a b)))")))
  (gate-check "unchecked-add lowers to jolt-uncadd2" (gate-sub? e "(jolt-uncadd2 a b)") #t)
  (gate-check "unchecked-add is not a var call" (gate-sub? e "var-cell-deref") #f)
  (run-emit e)
  (gate-check "unchecked-add wraps at 64 bits" (call "uadd" 9223372036854775807 1) -9223372036854775808))
(let ((e (emit-dl "(def uinc (fn [a] (unchecked-inc a)))")))
  (gate-check "unchecked-inc lowers to jolt-uncinc" (gate-sub? e "(jolt-uncinc a)") #t))
(let ((e (emit-dl "(def scan (fn [^String s] (let [n (long (.length s))] (loop [i (unchecked-long 0) acc 0] (if (>= i n) acc (recur (unchecked-inc i) (unchecked-add acc (unchecked-long (unchecked-int (.charAt s (unchecked-int i)))))))))))")))
  (gate-check "unchecked-long init types the loop counter :long" (gate-sub? e "jolt-l>=") #t)
  (gate-check "the counter's unchecked-inc stays on the wrapping helper" (gate-sub? e "jolt-uncinc") #t)
  (gate-check "no cast in the loop is a var call" (gate-sub? e "var-cell-deref") #f)
  (gate-check "the long casts pass a fixnum through inline" (gate-sub? e "(fixnum? _lc$") #t)
  (run-emit e)
  (gate-check "the scan sums code points" (call "scan" "abc") 294))

;; ---- case on interned constants ---------------------------------------------
(let ((e (emit-dl "(def kcase (fn [x] (case x :a 1 :b 2 nil 0 3)))")))
  (gate-check "keyword/nil case clauses compare by identity" (gate-sub? e "jolt-identical?") #t)
  (gate-check "...and not by =" (gate-sub? e "jolt=2") #f)
  (run-emit e)
  (gate-check "case hits a keyword" (call "kcase" (keyword #f "b")) 2)
  (gate-check "case hits nil" (call "kcase" jolt-nil) 0)
  (gate-check "case fed a symbol takes the default" (call "kcase" (jolt-symbol #f "a")) 3))
(let ((e (emit-dl "(def scase (fn [x] (case x \"s\" :str q :sym 7 :num :other)))")))
  (gate-check "string/symbol/number clauses keep =" (gate-sub? e "jolt=2") #t)
  (run-emit e)
  (gate-check "case hits a string" (call "scase" "s") (keyword #f "str"))
  (gate-check "case hits a symbol" (call "scase" (jolt-symbol #f "q")) (keyword #f "sym"))
  (gate-check "case fed a keyword takes the default" (call "scase" (keyword #f "s")) (keyword #f "other")))

(gate-summary "directcall")
