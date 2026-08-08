;; The cheap park: a source-to-source CPS pass over a go body.
;;
;; A go body runs as a fiber, and a fiber parks by capturing a continuation —
;; which retains a whole Chez stack segment for as long as the process is parked.
;; A park this pass can SEE does not need that: the pass rewrites the rest of the
;; body after the park into a closure, and the channel op stores that closure and
;; switches to the scheduler without capturing anything.
;;
;; The choice is per PARK SITE, not per body. A park the pass cannot rewrite —
;; inside a called function, inside a try, inside a nested fn, reached through
;; eval — is left exactly as it is and parks by capturing a continuation, which is
;; what every park does today. So the pass is opportunistic: it can cost a park
;; its cheap representation, never its correctness.
;;
;; Both halves are the same channel protocol; only the wake differs. See
;; clojure.core.async/__sm-take and __sm-put.
;;
;; Not covered: alts! / alt! (threading a continuation through the waiter
;; registration is its own round), and any park inside a try (a state machine
;; would have to carry the exception frame explicitly).

(ns clojure.core.async.sm)

;; The park ops, by identity. Resolving the caller's symbol and comparing the VAR
;; is the only sound test: a user function named <! must be left alone. A macro
;; that expands to a park is invisible to the pre-scan below, which costs it the
;; cheap park and nothing else.
;;
;; <!! and >!! are the same ops as <! and >!: identical on a fiber (parking a
;; blocking take preserves what it means without holding the carrier) and already
;; identical on a thread.
(def ^:private take-var-1 #'clojure.core.async/<!)
(def ^:private take-var-2 #'clojure.core.async/<!!)
(def ^:private put-var-1 #'clojure.core.async/>!)
(def ^:private put-var-2 #'clojure.core.async/>!!)

;; Forms this pass does not look inside. A park in one of them stays where it is;
;; a park-free one is emitted whole.
(def ^:private opaque
  '#{quote try fn* letfn* set! def defmacro throw var syntax-quote
     monitor-enter monitor-exit new .})

;; recur inside one of these targets it, not an enclosing loop.
(def ^:private recur-barrier '#{fn* loop* letfn*})

(defn- bail []
  (throw (ex-info "sm/bail" {:clojure.core.async.sm/bail true})))

(defn- bail? [e]
  (boolean (:clojure.core.async.sm/bail (ex-data e))))

(defn- head [form] (when (seq? form) (first form)))

(defn- children
  "Subforms to walk for a tree predicate. A quoted form has none."
  [form]
  (cond
    (= (head form) 'quote) nil
    (seq? form) (seq form)
    (vector? form) (seq form)
    (set? form) (seq form)
    (map? form) (concat (keys form) (vals form))
    :else nil))

(defn- tree-any? [pred form]
  (or (pred form)
      (boolean (some (fn [c] (tree-any? pred c)) (children form)))))

(defn- park-kind
  "nil, :take or :put — and only when sym resolves to the exact var. A local of
   the same name shadows it."
  [ctx sym]
  (when (and (symbol? sym) (not (contains? (:locals ctx) sym)))
    (let [v (resolve (:env ctx) sym)]
      (cond
        (nil? v) nil
        (or (identical? v take-var-1) (identical? v take-var-2)) :take
        (or (identical? v put-var-1) (identical? v put-var-2)) :put
        :else nil))))

(defn- parks? [ctx form]
  (tree-any? (fn [f] (some? (park-kind ctx (head f)))) form))

(defn- targets-recur?
  "A recur that would rebind the loop this pass is rewriting."
  [form]
  (cond
    (= (head form) 'recur) true
    (contains? recur-barrier (head form)) false
    :else (boolean (some targets-recur? (children form)))))

;; A form may be emitted whole only if it neither parks NOR carries a recur this
;; pass owns. The recur half is the trap: in
;;
;;   (loop [] (do (<! ch) (if p (recur) :done)))
;;
;; the tail is park-free, so emitting it whole looks right — but it would land
;; inside a continuation closure, where recur targets THAT fn instead of the loop.
;; Keeping such a form on the spine costs a couple of closures and reaches the
;; recur.
(defn- inline-ok? [ctx form]
  (and (not (parks? ctx form))
       (or (nil? (:rec ctx)) (not (targets-recur? form)))))

(defn- bind-local [ctx sym] (update ctx :locals conj sym))

(defn- bind-locals [ctx syms] (reduce bind-local ctx syms))

(declare cps)

(defn- kont
  "Bind (fn* [p] <bodyf>) to a fresh name and hand that name to f. A continuation
   is always a symbol, so it can be mentioned by both arms of an if without
   duplicating its body."
  [ctx p bodyf f]
  (let [ks (gensym "k__")
        ctx' (bind-local (bind-local ctx ks) p)]
    (list 'let* [ks (list 'fn* [p] (bodyf ctx'))]
          (f (bind-local ctx ks) ks))))

(defn- cps-body
  "CPS a form sequence as an implicit do."
  [ctx forms k]
  (cond
    (empty? forms) (list k nil)
    (empty? (rest forms)) (cps ctx (first forms) k)
    (inline-ok? ctx (first forms))
    (list 'do (first forms) (cps-body ctx (rest forms) k))
    :else
    (kont ctx (gensym "_v__")
          (fn [c] (cps-body c (rest forms) k))
          (fn [c ks] (cps c (first forms) ks)))))

(defn- cps-seq
  "Evaluate forms left to right, binding each result to a symbol, then hand the
   symbols to f. Source order is preserved: a park-free form to the left of a
   parking one is let* bound before the park, not after it."
  [ctx forms f]
  (letfn [(step [c done todo]
            (if (empty? todo)
              (f c done)
              (let [a (first todo)
                    s (gensym "a__")]
                (if (inline-ok? c a)
                  (let [c2 (bind-local c s)]
                    (list 'let* [s a] (step c2 (conj done s) (rest todo))))
                  (kont c s
                        (fn [c2] (step c2 (conj done s) (rest todo)))
                        (fn [c2 ks] (cps c2 a ks)))))))]
    (if (every? (fn [a] (inline-ok? ctx a)) forms)
      (f ctx (vec forms))
      (step ctx [] forms))))

(defn- cps-let
  "let* — a park-free init stays a binding; a parking one becomes a continuation
   parameter, which keeps the shadowing the source had."
  [ctx pairs body k]
  (if (empty? pairs)
    (cps-body ctx body k)
    (let [b (first pairs)
          init (second pairs)
          more (drop 2 pairs)]
      (if (inline-ok? ctx init)
        (let [ctx' (bind-local ctx b)]
          (list 'let* [b init] (cps-let ctx' more body k)))
        (kont ctx b
              (fn [c] (cps-let c more body k))
              (fn [c ks] (cps c init ks)))))))

(defn- cps-loop
  "loop* becomes a letfn* function called in tail position, so a recur chain is a
   tail call and does not grow the stack across parks."
  [ctx bindings body k]
  (let [names (vec (take-nth 2 bindings))
        inits (vec (take-nth 2 (rest bindings)))
        lp (gensym "lp__")]
    (cps-seq ctx inits
             (fn [c args]
               (let [c' (-> (bind-local c lp)
                            (bind-locals names)
                            (assoc :rec {:name lp :n (count names)}))]
                 (list 'letfn* [lp (list 'fn* names (cps-body c' body k))]
                       (apply list lp args)))))))

(defn- cps-if
  [ctx form k]
  (let [t (second form)
        arms (drop 2 form)
        ts (gensym "t__")]
    (kont ctx ts
          (fn [c]
            (list 'if ts
                  (cps c (first arms) k)
                  (if (> (count arms) 1)
                    (cps c (second arms) k)
                    (list k nil))))
          (fn [c ks] (cps c t ks)))))

(defn- cps
  "Rewrite form so that its value is passed to the continuation named by k."
  [ctx form k]
  (if (inline-ok? ctx form)
    (list k form)
    (if-not (seq? form)
      ;; a collection literal holding a park: left whole, parks the old way
      (list k form)
      (let [h0 (head form)
            ex (if (and (symbol? h0)
                        (not (contains? (:locals ctx) h0))
                        (not (contains? opaque h0)))
                 (macroexpand form)
                 form)
            h (head ex)
            pk (park-kind ctx h)]
        (cond
          pk
          (cps-seq ctx (vec (rest ex))
                   (fn [_ args]
                     (apply list
                            (if (= pk :take)
                              'clojure.core.async/__sm-take
                              'clojure.core.async/__sm-put)
                            (concat args [k]))))

          (= h 'do) (cps-body ctx (rest ex) k)
          (= h 'let*) (cps-let ctx (vec (second ex)) (drop 2 ex) k)
          (= h 'if) (cps-if ctx ex k)
          (= h 'loop*) (cps-loop ctx (vec (second ex)) (drop 2 ex) k)

          (= h 'recur)
          (let [rec (:rec ctx)]
            (when (or (nil? rec) (not= (count (rest ex)) (:n rec))) (bail))
            (cps-seq ctx (vec (rest ex))
                     (fn [_ args] (apply list (:name rec) args))))

          ;; A form this pass does not rewrite. Emitting it whole is correct: a
          ;; park inside it captures a continuation, and that capture includes the
          ;; pending (k _) frame, so the resume carries on properly.
          (or (contains? opaque h) (not (symbol? h)))
          (if (and (:rec ctx) (targets-recur? ex)) (bail) (list k form))

          :else
          (cps-seq ctx (vec (rest ex))
                   (fn [_ args] (list k (apply list h args)))))))))

;; --- the entry point ---------------------------------------------------------

(defn cps-go-body
  "The go body rewritten as (fn* [k] ...), or nil to compile the body the way it
   always was. nil means: nothing here parks where the pass can see it, or the
   body did something the pass will not guess at."
  [env body]
  (let [ctx {:env env :locals #{} :rec nil}
        form (if (= 1 (count body)) (first body) (cons 'do body))]
    (when (and (parks? ctx form)
               ;; a recur in the body targets the body fn itself, whose arity this
               ;; pass changes
               (not (targets-recur? form)))
      (try
        (let [k (gensym "k__")]
          (list 'fn* [k] (cps (bind-local ctx k) form k)))
        (catch Throwable e
          (when-not (bail? e) (throw e))
          nil)))))
