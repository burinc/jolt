(ns jolt.passes
  "IR optimization passes (nanopass-lite) + the inference/checking
  driver. Façade over three weakly-coupled namespaces, loaded with the compiler:

    jolt.passes.fold    — const-fold (always-on) + the shared const-shape predicate.
    jolt.passes.inline  — inline + flatten-lets + scalar-replace (direct-link only).
    jolt.passes.types   — collection-type inference + success-type checking
                          (RFC 0006) + the inter-procedural driver API.

  run-passes (below) is the single entry the back end applies to every analyzed
  form. The driver/checker fns the back end looks up by name (check-form,
  infer-body, reinfer-def, set-rtenv!, take-diags!, …) are re-exported here via
  :refer, so jolt.passes stays the only namespace the back end imports.

  Portable Clojure: kernel-tier fns + seed primitives only."
  (:require [jolt.host :refer [inline-enabled? inference-enabled? record-shapes protocol-methods stash-inline!]]
            [jolt.passes.fold :refer [const-fold]]
            [jolt.passes.numeric :as numeric]
            [jolt.passes.inline :refer [inline-node flatten-lets scalar-replace direct-call-edges]]
             [jolt.passes.types :refer [run-inference
                                         check-form infer-body reinfer-def
                                         set-rtenv! set-vtypes!
                                        set-record-shapes! set-protocol-methods!
                                        reset-escapes! collected-escapes
                                        wp-infer! param-seeds-for param-num-seeds-for
                                        set-check-mode! take-diags!
                                        reinfer-inline-method-bodies]]))

;; Cap on inline -> flatten -> scalar-replace -> const-fold iterations. Each pass
;; sets `dirty` when it rewrote something; the loop stops at a clean pass or here.
(def ^:private inline-fixpoint-cap 8)

;; A top-level defn the inline pass may splice: a single fixed arity (no rest),
;; and NOT opted out of the closed world. The pass itself checks body size +
;; closedness, so any such fn is stashable.
;;
;; The opt-out check is the same one the back end applies to direct-linking, and
;; it has to be, because splicing is the stronger commitment: a ^:redef def is
;; left var-routed so a later redefinition reaches its callers, and copying its
;; body into one of them defeats exactly that. Refused at the STASH rather than
;; at the splice site, so an opted-out fn never enters the graph the cycle walk
;; and the fixpoint traverse.
(defn- inline-eligible? [node]
  (and (jolt.ir/single-fixed-arity-fn-def? node)
       (not (jolt.ir/closed-world-opt-out? (:meta node)))))

(defn- stash-of [node]
  (let [a (first (:arities (:init node)))]
    {:params (:params a) :body (:body a) :nhints (:nhints a) :ret (:ret-nhint a)
     ;; the stash-graph edges splice-cycle-member? (inline.clj) walks to refuse
     ;; inlining a recursive cluster; computed once here, on the analyzed body.
     :calls (direct-call-edges (:body a))}))

(defn inject-wp-nhints
  "Merge the whole-program :double param seeds into a def's arity :nhints as
  synthetic ^double hints, so the numeric pass unboxes a hintless fn whose callers
  all pass flonums (the entry coercion jolt->fl is a no-op on a proven
  flonum). Only un-hinted params are added — an explicit hint wins. A no-op unless
  the closed-world fixpoint typed a param :double (param-num-seeds-for)."
  [unit node]
  (let [seeds (when (= :def (:op node)) (param-num-seeds-for unit (str (:ns node) "/" (:name node))))
        f (:init node)]
    (if (and seeds (jolt.ir/single-fixed-arity-fn? f))
      (let [a (first (:arities f))
            have (into #{} (map first (:nhints a)))
            add (for [[p k] seeds :when (not (have p))] [p k])]
        (assoc node :init (assoc f :arities [(assoc a :nhints (vec (concat (:nhints a) add)))])))
      node)))

;; Dev IR validation. When JOLT_IR_VALIDATE is set, run-passes checks the node
;; entering and the node leaving the pass pipeline against the jolt.ir schema and
;; prints any problem (unknown :op, missing required key) — a fast way to catch a
;; pass or analyzer producing malformed IR, which the TOTAL child-walk would
;; otherwise turn into a silent no-op. Off, and free, otherwise (read once at load).
;; jolt.host/getenv (defined in the runtime loader, absent during the seed mint)
;; and jolt.ir/tree-problems (new on jolt.ir) are referenced fully-qualified, not
;; :refer'd — a qualified ref to a loaded ns is late-bound, so the mint compiles
;; this before those vars resolve.
(def ^:private ir-validate? (jolt.host/getenv "JOLT_IR_VALIDATE"))
(defn- report-ir! [phase node]
  (run! (fn [p] (println (str "IR-VALIDATE [" phase "] " p)))
        (jolt.ir/tree-problems node)))

(defn run-passes
  "All passes, in order. The back end applies this to every analyzed form.

  Three modes, determined by host-contract flags:

  **Full optimization** (passes on + direct-link):
    run inline + flatten + scalar-replace + const-fold to a capped fixpoint —
    inlining exposes map literals to lookups, scalar-replace collapses them,
    which may expose more — then a collection-type inference pass (optionally
    also emitting success diagnostics) that auto-drops the lookup guard where
    the type is proven. This is what every `jolt build` gets, release and --opt
    alike: inlining follows LINKAGE, because a spliced body is sound exactly
    when the callee's var cannot be redefined under it.

  **Inference mode** (passes on, dynamically linked):
    setup record/protocol shapes (redefinition-safe caches), then run const-fold,
    collection-type inference (with seeds if available), and numeric annotate —
    without inline/scalar. Reached by --no-direct-link (or :jolt/build
    {:direct-link false}), where every def stays redefinable and so cannot be
    spliced, but the type inference still holds.

  **Dev/normal** (passes off):
    just const-fold + numeric annotate. --dev, and the runtime compile spine.

  numeric/annotate runs last in all branches (hint-directed fl*/fx* arithmetic);
  it benefits open builds too, so it is not gated on inlining.

  `unit` is the compilation-unit context (jolt.passes.types/new-unit): all inference/
  checking state is per-unit, not module-global. The 2-arg arity makes a fresh unit
  per call (the runtime compile spine, which never optimizes, so it's unused there);
  build/emit-image call the 3-arg arity with the whole-program-seeded unit they share
  across forms, so param-seeds-for reaches the seeds wp-infer! stashed."
  ;; the 2-arg arity (the runtime compile spine) makes a fresh unit: it never
  ;; optimizes (the const-fold :else branch), so it never installs record-shapes and
  ;; the emit reads an empty registry either way. build/emit-image pass their published
  ;; unit as the 3-arg arity, so the inference branches and the emit share ONE unit.
  ([node ctx] (run-passes node ctx (jolt.passes.types/new-unit)))
  ([node ctx unit]
  ;; INVARIANT (optimize/inference branches): the caller must have published `unit`
  ;; to the back end (set-emit-unit!) so it is @jolt.op-registry/current-unit-box.
  ;; set-record-shapes!/set-protocol-methods! and (:dirty unit) write THIS unit, but
  ;; the back end's direct-ctor emit and the inline pass read the current-unit-box —
  ;; they must be the same object, or the record fold + inline fixpoint silently
  ;; degrade. build/emit-image and the gates all publish then pass the same unit.
  (when ir-validate? (report-ir! "analyze" node))
  ;; stash an inline-eligible defn so later call sites can splice it (closed-world
  ;; optimization only). Done before optimizing, from the analyzed node.
  (when (and (inline-enabled? ctx) (inline-eligible? node))
    (stash-inline! ctx (:ns node) (:name node) (stash-of node)))
  (let [result
        (numeric/annotate
          (cond
      ;; Full inline + inference (optimize + direct-link)
      (inline-enabled? ctx)
      ;; install the record-ctor shapes ONCE on the unit — the inline record fold and
      ;; the back end's direct-ctor emit read it from there (jolt.op-registry holds the
      ;; unit pointer), no separate registries. Protocol methods for devirtualization.
      (let [_ (set-record-shapes! unit (record-shapes ctx))
            _ (set-protocol-methods! unit (protocol-methods ctx))
            opt (loop [i 0 n (const-fold node)]
                  (reset! (:dirty unit) false)
                  (let [n2 (const-fold (scalar-replace (flatten-lets (inline-node n ctx))))]
                    (if (and @(:dirty unit) (< i inline-fixpoint-cap))
                      (recur (inc i) n2)
                      n2)))
            ;; a top-level def whose params the whole-program fixpoint typed gets
            ;; reinferred with those seeds (record types flow in from its callers);
            ;; everything else takes the ordinary per-form inference.
            seeds (when (= :def (:op opt)) (param-seeds-for unit (str (:ns opt) "/" (:name opt))))]
        ;; a final const-fold after inference propagates any predicate folded to a
        ;; constant, collapsing the `if` it gates to the taken branch; re-infer
        ;; inline method bodies with the receiver seeded (field reads → jrec-field-at);
        ;; then inject any whole-program :double param hints for the numeric pass.
        (inject-wp-nhints unit (const-fold (reinfer-inline-method-bodies unit
                                        (if seeds (reinfer-def unit opt seeds) (run-inference unit opt))))))

      ;; Inference mode (release/optimize without direct-link): inference without
      ;; the inline fixpoint. Record shape + protocol caches are redefinition-safe.
      (inference-enabled? ctx)
      (let [_ (set-record-shapes! unit (record-shapes ctx))
            _ (set-protocol-methods! unit (protocol-methods ctx))
            opt (const-fold node)
            seeds (when (= :def (:op opt)) (param-seeds-for unit (str (:ns opt) "/" (:name opt))))]
        (inject-wp-nhints unit (const-fold (reinfer-inline-method-bodies unit
                                        (if seeds (reinfer-def unit opt seeds) (run-inference unit opt))))))

      ;; Dev/normal: const-fold + numeric only
      :else
      (const-fold node)))]
    (when ir-validate? (report-ir! "passes" result))
    result)))
