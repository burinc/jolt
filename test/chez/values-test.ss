;; Tests for the Jolt value model on Chez (nil/truthiness, interned keywords,
;; symbols, exactness-aware =, hashing). Run from repo root:
;;   chez --script test/chez/values-test.ss
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; nil distinct from #f and '()
(ok "nil not #f"        (not (eq? jolt-nil #f)))
(ok "nil not '()"       (not (eq? jolt-nil '())))
(ok "nil? jolt-nil"     (jolt-nil? jolt-nil))
(ok "nil? not on #f"    (not (jolt-nil? #f)))

;; truthiness: only nil and false falsey
(ok "nil falsey"        (not (jolt-truthy? jolt-nil)))
(ok "false falsey"      (not (jolt-truthy? #f)))
(ok "true truthy"       (jolt-truthy? #t))
(ok "0 truthy"          (jolt-truthy? 0))
(ok "empty-str truthy"  (jolt-truthy? ""))
(ok "empty-list truthy" (jolt-truthy? '()))

;; keywords interned -> identity
(ok "kw eq"             (eq? (keyword #f "foo") (keyword #f "foo")))
(ok "kw ns eq"          (eq? (keyword "a" "foo") (keyword "a" "foo")))
(ok "kw diff ns"        (not (eq? (keyword "a" "foo") (keyword #f "foo"))))
(ok "kw?"               (keyword? (keyword #f "x")))
(ok "kw not sym"        (not (jolt-symbol? (keyword #f "x"))))

;; symbols NOT interned but jolt= by ns/name
(ok "sym not eq"        (not (eq? (jolt-symbol #f "x") (jolt-symbol #f "x"))))
(ok "sym jolt="         (jolt= (jolt-symbol #f "x") (jolt-symbol #f "x")))
(ok "sym diff name"     (not (jolt= (jolt-symbol #f "x") (jolt-symbol #f "y"))))
(ok "sym?"              (jolt-symbol? (jolt-symbol "ns" "n")))

;; numbers: exactness-aware = (Clojure semantics)
(ok "1 = 1"             (jolt= 1 1))
(ok "1 not= 1.0"        (not (jolt= 1 1.0)))
(ok "1.0 = 1.0"         (jolt= 1.0 1.0))
(ok "ratio ="           (jolt= 1/2 1/2))
(ok "bigint=int exact"  (jolt= 2 (expt 2 1)))
(ok "= variadic"        (jolt= 3 3 3))
(ok "= variadic false"  (not (jolt= 3 3 4)))

;; strings / chars
(ok "str ="             (jolt= "ab" "ab"))
(ok "str !="            (not (jolt= "ab" "ac")))
(ok "char ="            (jolt= #\a #\a))

;; hashing consistent with =
(ok "hash kw stable"    (= (jolt-hash (keyword #f "k")) (jolt-hash (keyword #f "k"))))
(ok "hash sym stable"   (= (jolt-hash (jolt-symbol #f "k")) (jolt-hash (jolt-symbol #f "k"))))
(ok "hash 1 != 1.0"     (not (= (jolt-hash 1) (jolt-hash 1.0))))
(ok "hash str stable"   (= (jolt-hash "abc") (jolt-hash "abc")))

;; regression: keyword intern key must not collide across ns/name boundary
(ok "kw no boundary collide" (not (eq? (keyword "a" "b/c") (keyword "a/b" "c"))))
;; regression: jolt-hash must not throw on non-finite floats
(ok "hash +inf ok" (number? (jolt-hash +inf.0)))
(ok "hash +nan ok"  (number? (jolt-hash +nan.0)))
(ok "hash inf != exact" (not (= (jolt-hash +inf.0) (jolt-hash 0))))

;; --- arm registries reject arms their fast path would skip ------------------
;; jolt-hash answers nil/keyword/fixnum/string, and jolt=2 answers fixnum and
;; flonum pairs, before consulting the arms. An arm claiming one of those would
;; be silently skipped, so registration rejects it rather than leaving the
;; invariant to a comment. Each registry guards its OWN fast path — the
;; printer's is wider, and reusing it here would reject legitimate arms.
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define-record-type armtest-t (fields v) (nongenerative armtest-v1))

(ok "hash arm rejects fixnum"  (raises? (lambda () (register-hash-arm! fixnum? (lambda (x) 0)))))
(ok "hash arm rejects string"  (raises? (lambda () (register-hash-arm! string? (lambda (x) 0)))))
(ok "hash arm rejects keyword" (raises? (lambda () (register-hash-arm! keyword-t? (lambda (x) 0)))))
(ok "hash arm rejects nil"     (raises? (lambda () (register-hash-arm! jolt-nil? (lambda (x) 0)))))

;; an arm claiming BOTH sides of a fast pair is what jolt=2 would skip
(ok "eq arm rejects fixnum pair"
    (raises? (lambda () (register-eq-arm! (lambda (a b) (and (fixnum? a) (fixnum? b)))
                                          (lambda (a b) #t)))))
(ok "eq arm rejects flonum pair"
    (raises? (lambda () (register-eq-arm! (lambda (a b) (and (flonum? a) (flonum? b)))
                                          (lambda (a b) #t)))))

;; hash's fast path is NARROWER than the printer's: chars, symbols, flonums and
;; bignums all reach the arms, so the hash guard must let them through
(ok "hash guard allows char"   (not (raises? (lambda () (hash-arm-reject-fast-type! 'test char?)))))
(ok "hash guard allows flonum" (not (raises? (lambda () (hash-arm-reject-fast-type! 'test flonum?)))))
(ok "hash guard allows symbol" (not (raises? (lambda () (hash-arm-reject-fast-type! 'test symbol-t?)))))
(ok "pr guard still rejects char" (raises? (lambda () (pr-arm-reject-fast-type! 'test char?))))

;; eq's identity clause legitimately short-circuits every non-number type, so a
;; single-sided claim on one is not subject to the invariant
(ok "eq guard allows either-arg shape"
    (not (raises? (lambda () (eq-arm-reject-fast-type!
                              'test (lambda (a b) (or (string? a) (string? b))))))))

;; and a real arm on a type off the fast path still registers and is consulted
(ok "hash arm on a plain type registers"
    (not (raises? (lambda () (register-hash-arm! armtest-t? (lambda (x) 4242))))))
(ok "registered hash arm is consulted" (= 4242 (jolt-hash (make-armtest-t 1))))
(ok "eq arm on a plain type registers"
    (not (raises? (lambda () (register-eq-arm! (lambda (a b) (or (armtest-t? a) (armtest-t? b)))
                                               (lambda (a b) #t))))))
(ok "registered eq arm is consulted" (jolt=2 (make-armtest-t 1) (make-armtest-t 2)))

(printf "values-test: ~a/~a passed\n" (- total fails) total)
(exit (if (> fails 0) 1 0))
