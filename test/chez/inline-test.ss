;; IR inlining (jolt.passes.inline), enabled under optimization. A small
;; single-arity defn is stashed and spliced at its call sites, removing the call.
;; A ^double/^long fn's param-entry and return coercions travel with the splice
;; (via :coerce nodes) so an inlined call matches the called one — incl. coercing a
;; non-double arg — and the body's fl*/fx* fast path still fires. Run:
;;   chez --script test/chez/inline-test.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (has? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))
(define (emitf ns str)            ; analyze + run-passes (optimize on) + emit
  (let-values (((f j) (rdr-read-form str 0 (string-length str))))
    (let ((ctx (make-analyze-ctx ns)))
      (jolt-ce-emit (jolt-ce-run-passes (jolt-ce-analyze ctx f) ctx)))))
;; The CODE portion of an emission. An anon literal's registration replays its
;; original SOURCE form, so a callee name that inlining removed from the code is
;; still there verbatim — drop the registrations before asserting.
;;
;; They are a PREAMBLE, not a tail: emit-top-form puts them first, as
;; (begin <registrations> <code>). Cutting at the first (image-register-fn-form!
;; and keeping the prefix therefore kept "(begin " and threw the code away, so
;; every assertion below that used this passed no matter what the code said. It
;; only surfaced when the registrations grew a (let* …) header binding the shared
;; constructions, which put the callee's name into the part being kept.
;;
;; So match parens instead of scanning for a marker: skip the one balanced form
;; that follows "(begin " and keep the rest. String literals are opaque to the
;; scan — the registrations are full of them, and a symbol named ")" would
;; otherwise unbalance it.
(define (skip-form s i)
  (let ((n (string-length s)))
    (let loop ((i i) (depth 0) (in-str #f))
      (if (>= i n)
          i
          (let ((c (string-ref s i)))
            (cond
              (in-str (cond ((char=? c #\\) (loop (+ i 2) depth #t))
                            ((char=? c #\") (loop (+ i 1) depth #f))
                            (else (loop (+ i 1) depth #t))))
              ((char=? c #\") (loop (+ i 1) depth #t))
              ((char=? c #\() (loop (+ i 1) (+ depth 1) #f))
              ((char=? c #\)) (if (= depth 1) (+ i 1) (loop (+ i 1) (- depth 1) #f)))
              (else (loop (+ i 1) depth #f))))))))
;; Matched against the two shapes the preamble can take and nothing else: a
;; top-level `do` also emits (begin …, and dropping its first statement would be a
;; silent hole in whatever asserted on it.
(define (starts-with? s pre)
  (and (>= (string-length s) (string-length pre))
       (string=? (substring s 0 (string-length pre)) pre)))
(define (code-part s)
  (if (or (starts-with? s "(begin (let* (")
          (starts-with? s "(begin (image-register-fn-form!"))
      (substring s (skip-form s 7) (string-length s))   ; 7 = past "(begin "
      s))
(define (ev s) (jolt-compile-eval s "u"))

;; inlining is a closed-world optimization — requires optimize + direct-link.
(set-optimize! #t)
(set-direct-link-flag! #t)

;; a small plain fn is spliced; the call to it disappears.
(ev "(def add1 (fn* ([x] (+ x 1))))")
(let ((e (emitf "u" "(fn* ([y] (add1 y)))")))
  (ok "plain fn is inlined (call to add1 gone)" (not (has? (code-part e) "add1")))
  (ok "inlined body present (jolt-n+ ... 1)" (has? e "(jolt-n+")))
(ok "inlined plain fn runtime: (add1 41) = 42" (= 42 (jnum->exact (ev "((fn* ([y] (add1 y))) 41)"))))

;; a ^double fn: body fl-ops fire after inlining, and the call is gone.
(ev "(def ^double dwork (fn* ([^double a ^double b] (+ (* a a) (* b b)))))")
(let ((e (emitf "u" "(fn* ([] (dwork 3.0 4.0)))")))
  (ok "inlined ^double fn body uses fl*" (has? e "(#3%fl*"))
  (ok "inlined ^double fn call to dwork is gone" (not (has? (code-part e) "dwork"))))
(ok "inlined ^double call: 3^2+4^2 = 25" (= 25 (jnum->exact (ev "((fn* ([] (dwork 3.0 4.0))))"))))
;; coercion travels with the splice: int args become doubles, so the result is a
;; flonum 25.0 — matching the called fn, not an exact 25.
(ok "inlined ^double with int args still returns a flonum" (flonum? (ev "((fn* ([] (dwork 3 4))))")))

;; a ^long fn inlines with long coercion + the checked long ops.
(ev "(def ^long lsum (fn* ([^long a ^long b] (+ a b))))")
(let ((e (emitf "u" "(fn* ([] (lsum 3 4)))")))
  (ok "inlined ^long fn body uses jolt-l+" (has? e "(jolt-l+")))
(ok "inlined ^long call: 3+4 = 7 (fixnum)" (let ((r (ev "((fn* ([] (lsum 3 4))))"))) (and (fixnum? r) (= r 7))))

;; an accumulator over an inlined ^double call: the whole loop body fuses to fl-ops.
(ev "(def ^double sq (fn* ([^double x] (* x x))))")
(let ((e (emitf "u" "(fn* ([] (loop [acc 0.0 i 0] (if (< i 3) (recur (+ acc (sq 2.0)) (inc i)) acc))))")))
  (ok "accumulator over inlined ^double call lowers to fl+" (has? e "(#3%fl+"))
  (ok "the sq call is inlined away" (not (has? (code-part e) "sq"))))
(ok "accumulator over inlined ^double call: 3*4.0 = 12" (= 12 (jnum->exact (ev "((fn* ([] (loop [acc 0.0 i 0] (if (< i 3) (recur (+ acc (sq 2.0)) (inc i)) acc)))))"))))

(set-optimize! #f)
(set-direct-link-flag! #f)
(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
