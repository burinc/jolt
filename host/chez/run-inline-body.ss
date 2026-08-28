;; run-inline-body.ss — inline method body field-read gate.
;;
;; When `run-passes` re-infers inline method bodies with the receiver typed as the
;; record, (get _p :field) must emit jrec-field-at (bare index) instead of jolt-get.
;;
;;   chez --script host/chez/run-inline-body.ss
(import (chezscheme))
(load "host/chez/run-gate-harness.ss")

(define set-record-shapes! (var-deref "jolt.passes.types" "set-record-shapes!"))
(define set-protocol-methods! (var-deref "jolt.passes.types" "set-protocol-methods!"))
(define run-passes (var-deref "jolt.passes" "run-passes"))
(define emit    (var-deref "jolt.backend-scheme" "emit"))
(define analyze (var-deref "jolt.analyzer" "analyze"))
(define U ((var-deref "jolt.passes.types" "new-unit")))
((var-deref "jolt.backend-scheme" "set-emit-unit!") U)
((var-deref "jolt.backend-scheme" "set-prelude-mode!") #t)
(define (evals src) (jolt-compile-eval (string-append "(do " src ")") "user"))

;; Populate runtime tables with a protocol and a defrecord with inline method impl.
(evals "(defprotocol Shape (area [s]))")
(evals "(defrecord Circle [^double r] Shape (area [_] (* r r 3.14159)))")

;; Get shapes from the populated runtime tables.
(define shapes (chez-record-shapes-map))
(define pmethods (chez-protocol-methods-map))

;; Analyze the defrecord form.  The macro expansion populates the runtime tables
;; (register-record-type!, register-inline-method!), so shapes are available.
(let* ((ir (analyze (make-analyze-ctx "user")
                    (jolt-ce-read "(defrecord Circle [^double r] Shape (area [_] (* r r 3.14159)))")))
       (_ (set-optimize! #t))
       (_ (set-record-shapes! U shapes))
       (_ (set-protocol-methods! U pmethods))
       (passed (run-passes ir (make-analyze-ctx "user") U))
       (emitted (emit passed)))
  ;; The register-inline-method's fn body is inside the :do statements; the
  ;; reinfer pass should have seeded the receiver param so field reads emit
  ;; jrec-field-at.  Not checking jolt-get absence — the :do also contains
  ;; defs that use jolt-get for other purposes.
  (gate-check "inline method body field read uses direct accessor"
         (gate-sub? emitted "jrec1-f0") #t))

;; Also check that a deftype (non-record protocol impl) does NOT break anything.
;; deftype bodies use register-method, not register-inline-method.
(evals "(defrecord Square [s] Shape (area [_] (* s s)))")
(define shapes2 (chez-record-shapes-map))
(let* ((ir2 (analyze (make-analyze-ctx "user")
                     (jolt-ce-read "(defrecord Square [s] Shape (area [_] (* s s)))")))
       (_ (set-record-shapes! U shapes2))
       (passed2 (run-passes ir2 (make-analyze-ctx "user") U))
       (emitted2 (emit passed2)))
  (gate-check "deftype field read uses direct accessor"
         (gate-sub? emitted2 "jrec1-f0") #t))

;; jolt-ox7c.46: scalar-replace must not DISCARD a throwing sibling. A numeric op
;; throws on a non-numeric arg, so a map value like (+ x "throwme") whose key is
;; never read must NOT be dropped when the map binding is eliminated (that would
;; swallow the exception under --opt). The emitted body still contains the op.
(set-direct-link-flag! #t)
(let* ((ir (analyze (make-analyze-ctx "user")
                    (jolt-ce-read "(fn [x] (let [m {:a (+ x \"throwme\")}] (:b m)))")))
       (_ (set-optimize! #t))
       (passed (run-passes ir (make-analyze-ctx "user") U))
       (emitted (emit passed)))
  (gate-check "throwing discarded map value survives scalar-replace"
              (gate-sub? emitted "throwme") #t))
(set-direct-link-flag! #f)

;; --- splicing follows LINKAGE, not a build mode (jolt-mbcm.6) ---------------
;; hc-inline-enabled? used to be (and hc-optimize? hc-direct-link?), so the
;; DEFAULT release build emitted a real call everywhere --opt emitted a spliced
;; body -- a policy dial on a pass whose precondition is a correctness property.
;; It is hc-direct-link? alone now, and there is no second path to fall back to,
;; so this 2x2 is what stands in for the flag.
;;
;; Both axes are varied INDEPENDENTLY on purpose. Pinning only the shipped
;; configurations would leave the linkage-on/passes-off cell untested, and that
;; is the one cell that tells (and hc-optimize? hc-direct-link?) apart from
;; hc-direct-link? -- checked by mutation: restoring the old conjunction fails
;; row 1 and nothing else, and widening the gate to #t fails rows 3 and 4.
;;
;; Asserted on the callee's NAME: a spliced body has no reference left to it, an
;; un-spliced call reads its var by name whichever way the back end spells that.
(define (ilg-emit src)
  (emit (run-passes (analyze (make-analyze-ctx "user") (jolt-ce-read src))
                    (make-analyze-ctx "user") U)))
(define ilg-callee "(defn ilg-callee [a b] (+ a b 1))")
(define ilg-caller "(defn ilg-caller [x] (ilg-callee x 2))")
(define (ilg-spliced?) (not (gate-sub? (ilg-emit ilg-caller) "ilg-callee")))
(evals ilg-callee)                      ; intern the var so the ref resolves to :var

;; 1. linkage alone decides. Passes OFF, direct-linked: still spliced, because
;;    the closed world is the whole precondition. This also stashes the callee,
;;    so rows 3 and 4 below refuse a splice that is otherwise available.
(set-optimize! #f)
(set-direct-link-flag! #t)
(ilg-emit ilg-callee)
(gate-check "direct-linked, passes off: eligible callee is spliced" (ilg-spliced?) #t)

;; 2. the shipped build configuration.
(set-optimize! #t)
(gate-check "direct-linked, passes on: eligible callee is spliced" (ilg-spliced?) #t)

;; 3. --no-direct-link: the var stays redefinable, so the same stashed callee
;;    must NOT travel. This is the row that catches an inline gate widened past
;;    what linkage guarantees.
(set-direct-link-flag! #f)
(gate-check "dynamically linked, passes on: the same callee stays a call"
            (ilg-spliced?) #f)

;; 4. --dev, and the runtime compile spine.
(set-optimize! #f)
(gate-check "dynamically linked, passes off: the same callee stays a call"
            (ilg-spliced?) #f)

;; --- ^:redef / ^:dynamic are never spliced ----------------------------------
;; Direct-linking is decided PER DEF, not just by the global flag: dl-opt-out?
;; leaves a ^:dynamic or ^:redef def var-routed so `binding` and a later
;; redefinition still reach code already compiled. The stash gate has to make the
;; same per-def decision, and until jolt-mbcm.6 it did not -- with splicing gated
;; on --opt the gap was unreachable in a default build, and the moment splicing
;; followed linkage a ^:redef callee got its body copied into its caller and the
;; redefinition landed on a var nothing read any more. Verified end to end at the
;; time: a built binary printed "original" after interning a new greeting.
;;
;; Both rows assert on the callee's NAME, like the 2x2 above -- and the callers
;; are named so that neither name CONTAINS the callee's. gate-sub? is a substring
;; test, so an ilg-redef-caller would match "ilg-redef" whether or not the body
;; was spliced, and the row would pass under any mutation. It did.
(set-optimize! #t)
(set-direct-link-flag! #t)

(evals "(defn ^:redef ilg-redef [a] (+ a 1))")
(ilg-emit "(defn ^:redef ilg-redef [a] (+ a 1))")
(gate-check "^:redef callee is not spliced, even direct-linked"
            (gate-sub? (ilg-emit "(defn ilg-uses-redef [x] (ilg-redef x))") "ilg-redef") #t)

(evals "(defn ^:dynamic ilg-dyn [a] (+ a 1))")
(ilg-emit "(defn ^:dynamic ilg-dyn [a] (+ a 1))")
(gate-check "^:dynamic callee is not spliced, even direct-linked"
            (gate-sub? (ilg-emit "(defn ilg-uses-dyn [x] (ilg-dyn x))") "ilg-dyn") #t)

(set-direct-link-flag! #f)
(set-optimize! #f)

(gate-summary "inline-body")
