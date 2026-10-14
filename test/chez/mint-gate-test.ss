;; The seed mint's in-order visibility gate (host-contract.ss hc-mint-unwalked).
;;
;; bootstrap.ss compiles every source form in a process that already holds the
;; previous seed, so a var the seed defines is live before the walk reaches its
;; def. Ungated, a (binding [*x* …]) above (def ^:dynamic *x* …) failed only on
;; the first remint pass and compiled from the second on: the fixpoint converged
;; on code no in-order load accepts, and when the skipped form was part of the
;; compiler, the next pass ran a compiler missing it and broke somewhere else
;; entirely. Here a namespace's vars are pre-defined the way the old seed would
;; have them, the gate is armed with them as bootstrap.ss arms it, and the
;; namespace is walked through the mint's own emitter. Run:
;;   chez --script test/chez/mint-gate-test.ss

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/emit-image.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define (contains? s sub)
  (let ((ns (string-length s)) (nsub (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i nsub) ns) #f)
            ((string=? (substring s i (+ i nsub)) sub) #t)
            (else (loop (+ i 1)))))))

(define src "
(ns mintgate.t)
(defn uses-binding [] (binding [*later* 2] *later*))
(defn uses-var [] #'*later*)
(defn uses-call [] (later-fn))
(defn uses-qualified [] (mintgate.t/later-fn))
(declare declared)
(defn uses-declared [] (binding [declared 1] declared))
(defmacro expands-later [] `(later-fn))
(def ^:dynamic *later* 1)
(defn later-fn [] 1)
(def ^:dynamic declared 0)
(defn after [] (binding [*later* 2] (later-fn)))
")

;; What the previous seed would hold: every var the namespace defines, already
;; defined, *later* and declared already dynamic.
(define seed-vars '("*later*" "later-fn" "declared" "uses-binding" "uses-var" "uses-call"
                    "uses-qualified" "uses-declared" "expands-later" "after"))
(define (seed-the-namespace!)
  (for-each (lambda (n) (def-var! "mintgate.t" n 1)) seed-vars)
  (for-each (lambda (n)
              (set-var-meta! "mintgate.t" n (jolt-hash-map (keyword #f "dynamic") #t)))
            '("*later*" "declared")))
(define (gate-table)
  (let ((t (make-hashtable string-hash string=?)))
    (for-each (lambda (n) (hashtable-set! t (string-append "mintgate.t/" n) #t)) seed-vars)
    t))

;; Walk the source as the mint does; returns (skipped-count . stderr).
(define (mint-walk gate)
  (seed-the-namespace!)
  (ei-reset-skipped!)
  (hc-mint-gate! gate)
  (let* ((err (open-output-string))
         (out (parameterize ((current-error-port err))
                (ei-emit-ns "mintgate.t" src))))
    (hc-mint-gate! #f)
    (set-chez-ns! "user")
    (cons ei-skipped-count (get-output-string err))))

(putenv "JOLT_MINT_DEBUG" "1")

;; Ungated (the old mint): every forward reference resolves against the
;; pre-defined vars, so nothing is reported.
(let ((r (mint-walk #f)))
  (ok "ungated: forward references compile against the old seed's vars" (= 0 (car r))))

(let* ((r (mint-walk (gate-table))) (log (cdr r)))
  (ok "gated: exactly the four forward references are refused" (= 4 (car r)))
  (ok "binding a var defined below: the JVM's message, naming the var"
      (contains? log "mint: mintgate.t/uses-binding raised: Unable to resolve var: *later* in this context"))
  (ok "#' of a var defined below is refused the same way"
      (contains? log "mint: mintgate.t/uses-var raised: Unable to resolve var: *later* in this context"))
  (ok "a call to a fn defined below is unresolved"
      (contains? log "mint: mintgate.t/uses-call raised: Unable to resolve symbol: later-fn in this context"))
  (ok "a qualified reference is refused, not compiled as a host static"
      (contains? log "mint: mintgate.t/uses-qualified raised: No such var: mintgate.t/later-fn"))
  (ok "a declared var binds above its def" (not (contains? log "uses-declared")))
  (ok "a macro's expander may name what is defined below" (not (contains? log "expands-later")))
  (ok "references below the def compile" (not (contains? log "mintgate.t/after"))))

(printf "mint-gate: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
