;; fnform-test.ss — R1 (bead jolt-hqpn): unique anon-fn letrec names +
;; source-form registration. A user-ns anon literal must be registered under a
;; deterministic jfn$<ns>$<def>$<n> name, that name must be what Chez's
;; inspector reports for the live closure ((io 'code) 'name), and the registry
;; must carry {form, ns, free-names}. Covers a literal inside a map, a nested
;; literal, a variadic literal, a literal capturing a local ONLY through a
;; nested literal, and the shadow case (fn [x] (+ y (let [y 1] y))). A
;; clojure.core-produced closure (partial) must NOT be jfn$-named (system gate).
;;   chez --script test/chez/fnform-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define (string-prefix? s pre)
  (let ((n (string-length s)) (m (string-length pre)))
    (and (>= n m) (string=? (substring s 0 m) pre))))

;; Compile+eval a Clojure source string in a namespace — the runtime eval path a
;; REPL-defined form goes through — returning the value.
(define (jolt-eval src ns)
  (jolt-compile-eval-form (jolt-ce-read src) ns))

;; The procedure name Chez's inspector reports, or #f for an unnamed procedure.
(define (closure-name c)
  (guard (e (#t #f))
    (let ((io (inspect/object c)))
      (let ((code (guard (e (#t #f)) (io 'code))))
        (and code (guard (e (#t #f)) (code 'name)))))))

;; A jolt vector's elements as a Scheme list.
(define (jvec->list v)
  (let loop ((s (jolt-seq v)) (acc '()))
    (if (jolt-nil? s) (reverse acc)
        (loop (seq-more s) (cons (seq-first s) acc)))))

(define (reg-ns name)
  (let ((e (image-fn-form-lookup name))) (and e (vector-ref e 1))))
(define (reg-frees name)
  (let ((e (image-fn-form-lookup name))) (and e (jvec->list (vector-ref e 2)))))
(define (reg-form-head name)
  (let ((e (image-fn-form-lookup name)))
    (and e (let ((s (jolt-seq (vector-ref e 0))))
             (and (not (jolt-nil? s)) (symbol-t-name (seq-first s)))))))

;; --- fixture: load a small app ns through the runtime eval path ---
(jolt-eval "(def config {:handler (fn [x] (* x 2)) :nested (fn [y] (fn [z] (+ y z)))})" "app")
(jolt-eval "(def v2 {:f (fn [a & more] (apply + a more))})" "app")
(jolt-eval "(def captured (let [base 10] (fn [x] (let [inner (fn [n] (+ n base))] (inner x)))))" "app")
(jolt-eval "(def shadowed (let [y 100] (fn [x] (+ y (let [y 1] y)))))" "app")
(jolt-eval "(def p (partial + 1))" "app")

;; --- registry: one entry per literal, name -> {form, ns, free-names} ---
(ok "config$0 registered with ns" (string=? (reg-ns "jfn$app$config$0") "app"))
(ok "config$0 form is an fn* form" (string=? (reg-form-head "jfn$app$config$0") "fn*"))
(ok "config$0 free-names empty" (equal? (reg-frees "jfn$app$config$0") '()))
(ok "config$1 (outer nested literal) registered"
    (and (string=? (reg-ns "jfn$app$config$1") "app")
         (equal? (reg-frees "jfn$app$config$1") '())))
(ok "config$2 (inner literal) free-names = y"
    (equal? (reg-frees "jfn$app$config$2") '("y")))
(ok "v2$0 (variadic) registered"
    (and (string=? (reg-ns "jfn$app$v2$0") "app")
         (equal? (reg-frees "jfn$app$v2$0") '())))
(ok "captured$0 free-names = base (captured only through the nested literal)"
    (equal? (reg-frees "jfn$app$captured$0") '("base")))
(ok "captured$1 free-names = base"
    (equal? (reg-frees "jfn$app$captured$1") '("base")))
(ok "shadowed$0 free-names = y (shadow case)"
    (equal? (reg-frees "jfn$app$shadowed$0") '("y")))

;; --- the live closure's inspector name equals the registered name ---
(define cfg (var-deref "app" "config"))
(define kh (keyword #f "handler"))
(define kn (keyword #f "nested"))
(ok "handler closure name" (string=? (closure-name (jolt-get cfg kh jolt-nil)) "jfn$app$config$0"))
(ok "nested closure name" (string=? (closure-name (jolt-get cfg kn jolt-nil)) "jfn$app$config$1"))
(ok "inner closure name" (string=? (closure-name ((jolt-get cfg kn jolt-nil) 3)) "jfn$app$config$2"))
(define v2 (var-deref "app" "v2"))
(define kf (keyword #f "f"))
(ok "variadic closure name" (string=? (closure-name (jolt-get v2 kf jolt-nil)) "jfn$app$v2$0"))
(ok "captured closure name" (string=? (closure-name (var-deref "app" "captured")) "jfn$app$captured$0"))
(ok "shadowed closure name" (string=? (closure-name (var-deref "app" "shadowed")) "jfn$app$shadowed$0"))

;; --- the closures still work (the letrec wrapper changed nothing) ---
(ok "handler calls" (eqv? ((jolt-get cfg kh jolt-nil) 5) 10))
(ok "nested calls" (eqv? (((jolt-get cfg kn jolt-nil) 3) 4) 7))
(ok "variadic calls" (eqv? ((jolt-get v2 kf jolt-nil) 1 2 3) 6))
(ok "captured calls" (eqv? ((var-deref "app" "captured") 7) 17))
(ok "shadowed calls" (eqv? ((var-deref "app" "shadowed") 2) 101))

;; --- clojure.core's own literals are registered too ---
;; They used to be excluded, so the seed prelude would stay byte-identical across
;; a mint -- and the consequence was that a closure core made (partial, comp, a
;; lazy seq from an overlay fn) could not be written to a state image at all.
;; Now core carries its source like any other namespace: the closure partial
;; returns is a registered literal, with a name and a registration to match.
(define pn (closure-name (var-deref "app" "p")))
(ok "a partial closure IS named" (and pn (string-prefix? pn "jfn$")))
(ok "...and its name resolves to a registration" (vector? (image-fn-form-lookup pn)))


;; a macro can splice a LIVE value (here the namespace object) into a fn body;
;; emit-quoted has no rendering for it, so the literal compiles UNREGISTERED
;; instead of failing the compilation (the Selmer regression)
(jolt-eval "(defmacro spliced-ns-fn [] (list 'fn '[x] (list 'str 'x *ns*)))" "app")
(jolt-eval "(def spliced {:f (spliced-ns-fn)})" "app")
(define spl (var-deref "app" "spliced"))
(define spl-f (jolt-get spl (keyword #f "f") jolt-nil))
(ok "spliced-live-value literal compiles and runs"
    (string? (jolt-invoke spl-f "pfx")))
(ok "spliced-live-value literal is unregistered (skipped, not fatal)"
    (let ((nm (closure-name spl-f)))
      (or (not nm) (not (image-fn-form-lookup nm)))))

;; --- registrations are SOURCE TEXT, parsed on the first lookup -------------
;; The emitted registration carries the literal's source as text, wrapped in
;; (image-fn-form-src "…"): a UTF-8 bytevector constant in the compiled runtime
;; -- one byte per character, where a Chez string is four and the quoted
;; construction this replaces was a let* of allocations run at every process
;; start. The registry parses the text the first time a lookup asks for it.
(define (emit-src ns str)   ; the emitted Scheme text of one top-level form
  (let-values (((f j) (rdr-read-form str 0 (string-length str))))
    (let ((ctx (make-analyze-ctx ns)))
      (jolt-ce-emit (jolt-ce-run-passes (jolt-ce-analyze ctx f) ctx)))))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))
;; the raw table slot, untouched by any lookup
(define (raw-form name)
  (let ((e (hashtable-ref fn-form-tbl name #f))) (and e (vector-ref e 0))))

(let ((e (emit-src "app" "(def lazy1 {:f (fn [x] (* x 2))})")))
  (ok "a registration is emitted as source text"
      (has? e "(image-register-fn-form! \"jfn$app$lazy1$0\" (image-fn-form-src \"(fn* [x] (* x 2))\") \"app\" (jolt-vector ))"))
  (ok "...and builds no quoted structure at load" (not (has? e "(jolt-symbol "))))
(let ((e (emit-src "app" "(def lazy2 {:a (fn [x] x) :b (fn [y] y)})")))
  (ok "several literals register as sibling calls, no let* header"
      (and (has? e "(begin (image-register-fn-form! \"jfn$app$lazy2$0\"")
           (has? e " (image-register-fn-form! \"jfn$app$lazy2$1\"")
           (not (has? e "(let* ((_q$")))))
(jolt-eval "(def lazy1 {:f (fn [x] (* x 2))})" "app")
(ok "before the first lookup the slot holds the bytes" (bytevector? (raw-form "jfn$app$lazy1$0")))
(ok "the first lookup parses the form" (string=? (reg-form-head "jfn$app$lazy1$0") "fn*"))
(ok "...and caches it in the slot" (not (bytevector? (raw-form "jfn$app$lazy1$0"))))
(ok "the parsed form carries no reader position"
    (let ((form (vector-ref (image-fn-form-lookup "jfn$app$lazy1$0") 0)))
      (jolt-nil? (jolt-get (jolt-meta form) (keyword #f "line") jolt-nil))))

;; Round-trip fidelity: the text reads back to the SAME construction the
;; registration used to carry (emit-quoted, the image writer's view of a form),
;; for every literal kind a fn body can hold. The back end checks exactly this
;; before it emits text, so a form that fails here would fall back instead; the
;; rows pin that the common kinds never do.
(define emit-quoted (var-deref "jolt.backend-scheme" "emit-quoted"))
(define fnsrc-src (var-deref "jolt.backend-scheme" "fnsrc-src"))
(define (quoted-text f) (jolt-invoke1 emit-quoted f))
(define (round-trips? src)
  (let* ((f (jolt-ce-read src))
         (t (jolt-invoke1 fnsrc-src f))
         (back (image-fn-form-parse t)))
    (string=? (quoted-text back) (quoted-text f))))
(for-each
  (lambda (src) (ok (string-append "source round-trips: " src) (round-trips? src)))
  (list "(fn* [^long n ^String s] (/ (+ n 1/2) 2))"
        "(fn* [] [##Inf ##-Inf ##NaN 1.5 -2 12345678901234567890 1.0E10 -0.0 0])"
        "(fn* [] [\\a \\newline \\space \\tab \\( \\\\ \\u00e9])"
        "(fn* [] [\"a\\\"b\\nc\\\\d\\t\\u00e9\" :k :ns/k nil true false])"
        "(fn* [] [#{3 1 2} {:b 2 :a 1} (quote sym) (quote ns/sym) () (1 2) [1 [2]]])"
        "(fn* [] {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10})"
        "(fn* [] [#\"a\\\\d\\\"\" #inst \"2020-01-02T00:00:00Z\" #uuid \"3b241101-e2bb-4255-8caf-4136c566a962\" 1.5M #foo/bar [1 2]])"
        "(fn* [x] (fn* [y] (fn* [z] (+ x y z))))"
        "(fn* [^{:tag long :foo true} n] (let [x (quote ^:kw q)] n))"
        "(fn* [] (clojure.core// 1 2))"
        "(fn* [] (.foo Foo. a.b/c))"))

;; A form with no source rendering (a macro spliced a live class value into the
;; body) still registers, through the quoted construction it always used -- as
;; a form, never as text.
(jolt-eval "(defmacro cls-fn [] (list 'fn '[x] (list 'instance? String 'x)))" "app")
(let ((e (emit-src "app" "(def clsf {:f (cls-fn)})")))
  (ok "an unrenderable literal falls back to the quoted construction"
      (and (has? e "(let* ((_q$0") (has? e "(jolt-class-for "))))
(jolt-eval "(def clsf {:f (cls-fn)})" "app")
(ok "...and registers a form, not text"
    (and (vector? (image-fn-form-lookup "jfn$app$clsf$0"))
         (not (bytevector? (raw-form "jfn$app$clsf$0")))))

;; The minted seed carries every core literal as text: no quoted construction
;; is left in it.
(define (file-has? path sub)
  (has? (call-with-port (open-input-file path) get-string-all) sub))
(ok "the seed prelude registers every literal as source text"
    (not (file-has? "host/chez/seed/prelude.ss" "(let* ((_q$0")))
(ok "the seed image registers every literal as source text"
    (not (file-has? "host/chez/seed/image.ss" "(let* ((_q$0")))

(printf "\nfnform gate: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
