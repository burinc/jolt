(ns jolt.loader
  "Per-context loading: a loader owns source roots, a delegate, and the
  namespaces, vars, classes and resources linked through it. Two contexts can
  hold different versions of one library, a context can be hermetic, and
  unloading one stops new loads through it without pulling definitions out from
  under code that already resolved them.

  Shaped like java.lang.ClassLoader, not compatible with it. `find` is
  findClass/getResource — it locates and reads nothing. `resolve` is
  findLoadedClass — the link table, no I/O. `load` is loadClass, and is the only
  method that reads. `as-classloader` is the host view, and the only place the
  word ClassLoader appears.

  Resolution is generic and the same for every loader: already linked, then the
  delegate, then this loader's own roots, then a miss. The delegate is a slot
  rather than a fixed parent, so the policy combinators (`allow`, `deny`,
  `self-first`, `pool`, `isolated`) compose, and `->loader` lifts a plain
  function into one.

  Requests are typed because real loaders order and gate the kinds differently:

      {:kind :ns|:var|:class|:resource   ; required
       :name \"clojure.string\"            ; required, a string
       :load? false}                     ; :ns only — load like `require`,
                                         ; or load the one namespace alone

  `find` answers an ordered vector of hits, first-wins for the singular forms,
  `[]` on a miss, and throws on a denial. Hits are data — no open streams, no
  closures, no compiled artifacts — so they print, compare and travel:

      {:kind :ns       :file \"/roots/a/b.clj\"    :loader l}
      {:kind :var      :cell <var cell>}
      {:kind :class    :registration {...}       :loader l}
      {:kind :resource :url \"file:/roots/a/x.edn\" :loader l}

  A `:var` hit carries the cell, so sharing across contexts is by reference and
  `identical?` holds. A resource hit names a location; `open-hit` turns it into
  an open handle on demand, so nothing holds a file handle between calls.

  Two tiers decide which loader answers. Linkage follows the DEFINING loader:
  code compiled for a context resolves through that context for its whole life,
  whoever calls it and on whatever thread. Dynamic loading — `require` reached
  through a value, `eval`, REPL forms, framework resource probes — follows the
  AMBIENT loader, the thread parameter `with-loader` binds, which is inherited
  by threads and fibers.

  NOT IMPLEMENTED. Every entry point below throws. The namespace exists so that
  the surface and its conformance suite (test/chez/loaderconf-test.clj, run by
  `make loaderconf`) are settled before the runtime work, the way the corpus
  settles clojure.core. Do not build on it until the suite is green."
  (:refer-clojure :exclude [find resolve load]))

(defn- todo [what]
  (throw (UnsupportedOperationException.
           (str "jolt.loader/" what " is declared, not implemented"))))

;; --- the protocol -----------------------------------------------------------
;; The arity split is the semantics: probe, look up, read.
(defprotocol Loader
  (find [l req]
    "Ordered hits for `req`, [] on a miss. Locates only — reads nothing,
    compiles nothing, opens nothing, installs nothing. Throws ex-info carrying
    :loader/denied when a policy denies the request; a denial is not a miss and
    does not fall through to this loader's own roots.")
  (resolve [l req]
    "The definition already linked in this loader, or nil. Reads the link table
    and nothing else — no I/O, no delegation to roots.")
  (load [l req]
    "Resolve (or accept a hit from `find`), read, initialize, link, and return
    the handle. The only method that reads. Passing a hit skips re-resolution
    and closes the window between locating and reading.")
  (parent [l]
    "This loader's delegate, or nil at the root.")
  (unload! [l]
    "Stop new loads through this loader and release the host resources it
    acquired. Idempotent, never blocks, and never throws for a teardown
    failure — it reports one. Definitions already resolved stay live; a
    subsequent find/resolve/load throws IllegalStateException. Returns

        {:unloaded true :already false :in-flight 0 :raced false
         :released {:namespaces 0 :resources 0 :registrations 0}
         :errors []}"))

;; --- constructors -----------------------------------------------------------
(defn root
  "The host itself as a loader: today's global namespaces, vars, classes and
  install roots. Its `parent` is nil."
  []
  (todo "root"))

(defn classpath
  "A loader over `roots`, searched in order. `opts` may carry :parent (the
  delegate, nil for none) and :id (a name for `status` and diagnostics). A
  loader IS roots plus a delegate; every combinator below builds a delegate to
  hand to :parent, except `self-first`, which reorders the two.

  Validation is eager: an unreadable root or jar fails here, not at the first
  load."
  ([roots] (classpath roots nil))
  ([roots opts] (todo "classpath")))

(defn url-search
  "The URLClassLoader analogue — `classpath` under the name the delegate table
  uses."
  ([roots] (classpath roots))
  ([roots opts] (classpath roots opts)))

(defn isolated
  "A delegate that answers nothing, so a context composed over it sees only its
  own roots. The root loader is not visible through it."
  []
  (todo "isolated"))

(defn ->loader
  "Lift a plain resolve-fn — (fn [req] hits-or-nil) — into a delegate loader."
  [f]
  (todo "->loader"))

;; --- policies ---------------------------------------------------------------
(defn delegating
  "Try `a`, then `b`."
  [a b]
  (todo "delegating"))

(defn pool
  "Sibling sharing: ask each of `loaders` in order."
  [loaders]
  (todo "pool"))

(defn allow
  "`l`, restricted to `names` — a request outside the whitelist is denied."
  [l names]
  (todo "allow"))

(defn deny
  "`l`, minus `names` — a request inside the blacklist is denied. A denial
  raises; it never falls through."
  [l names]
  (todo "deny"))

(defn self-first
  "`l` with its own roots consulted BEFORE its delegate, for `prefixes` only —
  the parent-first default inverted for the names a context means to shadow.
  The delegate is still consulted for everything else, and for these names when
  the roots miss."
  [l prefixes]
  (todo "self-first"))

;; --- ambient loader ---------------------------------------------------------
(defn current-loader
  "The ambient loader — the one dynamic loading follows on this thread or
  fiber. The root loader unless `with-loader` bound another."
  []
  (todo "current-loader"))

(defn with-loader*
  "`with-loader`'s function form: call `f` with `l` ambient."
  [l f]
  (todo "with-loader*"))

(defmacro with-loader
  "Evaluate `body` with `l` as the ambient loader. The binding is inherited by
  threads and fibers started inside it, and survives a fiber parking and
  resuming on another carrier."
  [l & body]
  `(with-loader* ~l (fn [] ~@body)))

;; --- handles and diagnostics ------------------------------------------------
(defn context
  "The host object underneath `l` — the jolt tables it owns. An escape hatch;
  nothing portable should need it."
  [l]
  (todo "context"))

(defn open-hit
  "A resource hit -> an open handle, or nil. The loader owns opening, so a hit
  stays comparable data and no handle is held between calls."
  [l hit]
  (todo "open-hit"))

(defn unloaded?
  "Has `l` been unloaded? The one behavioral predicate about a loader's state."
  [l]
  (todo "unloaded?"))

(defn status
  "A diagnostics map: loader id, roots, loaded-namespace count, in-flight
  loads, unloaded?, and one level of delegate. Implementation-visible — keys
  are added freely and no behavior may depend on one. Use `unloaded?` for
  anything that decides."
  [l]
  (todo "status"))

(defn as-classloader
  "`l` as a host java.lang.ClassLoader: loadClass is find + load,
  getResource/getResources/getResourceAsStream are find + open-hit, getParent
  is the delegate's facade, close is `unload!`. Accepted by the 2-arity of
  clojure.java.io/resource."
  [l]
  (todo "as-classloader"))
