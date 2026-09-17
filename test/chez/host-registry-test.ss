;; The host method registry's two tag relations (host-static.ss): alias and
;; derive. A tag is a representation — its table's procedures read the state
;; vector its constructor builds — and the class it reports is a separate fact
;; the class graph owns. derive lets a layout that extends another inherit its
;; table, and this gate pins what keeps that sound:
;;
;;   - a derivation is checked against the class graph: the child's class must
;;     be a strict descendant of the parent's, and both tags must name a class,
;;     so a layout claim cannot contradict the class claim and two layouts of one
;;     class cannot reach each other's procedures
;;   - the chain cannot cycle, so host-method-ref terminates
;;   - resolution is own table first, then the parents; an alias of a derived tag
;;     inherits the link; reflection's entries list a shadowed member once
;;   - the runtime's own derivations agree with the graph and with each other
;;
;; Loads the full runtime: the real derivations live in java/concurrency.ss.
;;   chez --script test/chez/host-registry-test.ss
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (raises? thunk)
  (call/cc (lambda (k) (with-exception-handler (lambda (e) (k #t)) (lambda () (thunk) #f)))))

;; A small graph of its own: Sub extends Base, one tag each, plus a second
;; layout of Base and a tag with no class row.
(jch-register-supers! "reg.test.Base" '())
(jch-register-supers! "reg.test.Sub" '("reg.test.Base"))
(hashtable-set! jhost-tag->fqn "reg-base" "reg.test.Base")
(hashtable-set! jhost-tag->fqn "reg-base-2" "reg.test.Base")
(hashtable-set! jhost-tag->fqn "reg-sub" "reg.test.Sub")
(define (base-a self) 'base-a)
(define (base-b self) 'base-b)
(define (sub-b self) 'sub-b)
(define (sub-c self) 'sub-c)
(register-host-methods! "reg-base" (list (cons "a" base-a) (cons "b" base-b)))
(register-host-methods! "reg-base-2" (list (cons "a" base-a)))

;; refusals
(ok "derive: parent tag must have a table"
    (raises? (lambda () (derive-host-methods! "reg-sub" "reg-nothing" '()))))
(ok "derive: child tag must name a class"
    (raises? (lambda () (derive-host-methods! "reg-no-class" "reg-base" '()))))
(ok "derive: a class cannot derive from a class it does not extend"
    (raises? (lambda () (derive-host-methods! "reg-sub" "abq" '()))))
(ok "derive: two layouts of one class cannot reach each other"
    (raises? (lambda () (derive-host-methods! "reg-base-2" "reg-base" '()))))
(ok "derive: refused derivations leave no link behind"
    (and (not (host-tag-parent "reg-sub")) (not (host-tag-parent "reg-base-2"))))

;; the accepted derivation, and what resolves through it
(derive-host-methods! "reg-sub" "reg-base" (list (cons "b" sub-b) (cons "c" sub-c)))
(ok "derive: the child names its parent" (equal? (host-tag-parent "reg-sub") "reg-base"))
(ok "resolve: an inherited member" (eq? (host-method-ref "reg-sub" "a") base-a))
(ok "resolve: the child's own member shadows the parent's" (eq? (host-method-ref "reg-sub" "b") sub-b))
(ok "resolve: the child's new member" (eq? (host-method-ref "reg-sub" "c") sub-c))
(ok "resolve: the parent is untouched" (eq? (host-method-ref "reg-base" "b") base-b))
(ok "resolve: a miss is a miss" (not (host-method-ref "reg-sub" "d")))
;; a member registered on the parent AFTER the derivation reaches the child —
;; the property a copied table would not have
(register-host-methods! "reg-base" (list (cons "late" base-a)))
(ok "resolve: a member registered on the parent later reaches the child"
    (eq? (host-method-ref "reg-sub" "late") base-a))
;; entries: own first, a shadowed parent member once (the child's), every name once
(let ((es (host-method-entries "reg-sub")))
  (ok "entries: every name once"
      (= (length es) (length (list-sort string<? (map car es)))))
  (ok "entries: the shadowed member is the child's"
      (eq? (cdr (assoc "b" es)) sub-b))
  (ok "entries: inherited members are listed"
      (and (assoc "a" es) (assoc "late" es) #t))
  (ok "entries: the child's own come first"
      (equal? (list-sort string<? (map car (list-head es 2))) '("b" "c"))))
;; an alias of the derived tag inherits the link
(hashtable-set! jhost-tag->fqn "reg-sub-alias" "reg.test.Sub")
(alias-host-methods! "reg-sub-alias" "reg-sub")
(ok "alias: of a derived tag resolves the parent's members" (eq? (host-method-ref "reg-sub-alias" "a") base-a))
(ok "alias: shares the derived tag's own table" (eq? (host-method-ref "reg-sub-alias" "c") sub-c))

;; the chain cannot cycle, even over a graph a library grafted a cycle onto
(jch-register-supers! "reg.test.Cyc1" '("reg.test.Cyc2"))
(jch-register-supers! "reg.test.Cyc2" '("reg.test.Cyc1"))
(hashtable-set! jhost-tag->fqn "reg-cyc1" "reg.test.Cyc1")
(hashtable-set! jhost-tag->fqn "reg-cyc2" "reg.test.Cyc2")
(register-host-methods! "reg-cyc1" (list (cons "x" base-a)))
(register-host-methods! "reg-cyc2" (list (cons "y" base-b)))
(derive-host-methods! "reg-cyc1" "reg-cyc2" '())
(ok "derive: a cycle is refused" (raises? (lambda () (derive-host-methods! "reg-cyc2" "reg-cyc1" '()))))
(ok "derive: the refused cycle left the earlier link in place"
    (and (equal? (host-tag-parent "reg-cyc1") "reg-cyc2") (not (host-tag-parent "reg-cyc2"))))
(ok "resolve: terminates on the acyclic chain" (eq? (host-method-ref "reg-cyc1" "y") base-b))

;; the runtime's own derivations
(ok "runtime: scheduled-executor derives from executor-service"
    (equal? (host-tag-parent "scheduled-executor") "executor-service"))
(ok "runtime: scheduled-future derives from j-future"
    (equal? (host-tag-parent "scheduled-future") "j-future"))
(ok "runtime: the scheduled pool answers the executor's submit, the same procedure"
    (eq? (host-method-ref "scheduled-executor" "submit") (host-method-ref "executor-service" "submit")))
(ok "runtime: a plain pool has no schedule" (not (host-method-ref "executor-service" "schedule")))
(ok "runtime: the scheduled future answers j-future's get" 
    (eq? (host-method-ref "scheduled-future" "get") (host-method-ref "j-future" "get")))
;; every derivation in the runtime agrees with the class graph — the check derive
;; makes, re-made over the table so a link written any other way is caught too
(let-values (((tags parents) (hashtable-entries host-methods-parent)))
  (vector-for-each
    (lambda (tag parent)
      (let ((c (jhost-fqn tag)) (p (jhost-fqn parent)))
        (ok (format "runtime: ~a's class extends ~a's" tag parent)
            (and c p (not (string=? c p)) (jch-isa? c p)))))
    tags parents))

(printf "host-registry: ~a checks, ~a failures\n" total fails)
(when (> fails 0) (exit 1))
