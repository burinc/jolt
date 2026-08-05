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

;; --- system gate: a clojure.core-produced closure has no jfn$ name ---
(define pn (closure-name (var-deref "app" "p")))
(ok "partial closure not jfn$-named" (or (not pn) (not (string-prefix? pn "jfn$"))))

(printf "\nfnform gate: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
