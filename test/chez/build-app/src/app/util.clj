(ns app.util
  (:require [clojure.string :as str]))

(defn shout [s]
  (str/upper-case (str s "!")))

;; A hintless double fn: with wp-infer now the release default, its r param is
;; seeded :double from the (area 2.0) call site in app.core, so the built binary
;; lowers * to fl*. build-smoke greps flat.ss for the fl-op (proves wp-infer ran).
(defn area [r] (* r r))

;; Unhinted string interop: the target (str x) types :str per-form (the str-ret
;; table), so the built binary lowers .startsWith/.indexOf to the string natives
;; inline — build-smoke greps flat.ss for str-starts-with? and the ABSENCE of a
;; record-method-dispatch "startsWith" (proves the :str stamp emitted directly).
(defn strd-prefix [x] (.startsWith (str x) "s"))
(defn strd-find [x] (.indexOf (str x) (int 45)))

;; The per-ns ret table: clojure.string/replace ALWAYS returns a string (so the
;; target types :str and lowers directly), while clojure.core/replace is
;; polymorphic and must NOT stamp. This call site is the replace row — if the
;; table lookup regressed to generic dispatch, build-smoke's negative grep for
;; record-method-dispatch "startsWith" fails on this fn.
(defn strd-rep [x] (.startsWith (clojure.string/replace x "a" "b") "b"))

;; Never called: only its PRESENCE matters. Referencing a jolt-lang/time class
;; must make the build scan pull the provider's install ns (src-provider/jolt/
;; time.clj, a stand-in on the roots) into flat.ss — a built binary has no
;; source roots, so the runtime class-miss autoload can't fire there.
(defn zdt-class [] java.time.ZonedDateTime)

;; ^:redef / ^:dynamic opt out of direct-linking even with it on by default (the
;; release default now), so the built binary can still redef/bind them at runtime.
(def ^:redef redef-fn (fn [] :original))
(def ^:dynamic *config* :default)

;; A two-deep non-tail call chain that throws — exercises native stack traces in a
;; direct-link build (build-smoke runs -main with a --boom sentinel arg). deep-boom
;; is defined through a USER macro: its source registration only gets a real line
;; if the reader position survives macroexpansion (so the trace frame maps).
(defmacro defguarded [name args & body]
  `(defn ~name ~args (assert (number? ~(first args)) "needs a number") ~@body))

(defguarded deep-boom [x]
  (* x 2))

(defn mid-boom [x]
  (inc (deep-boom x)))

(defmacro twice [x]
  `(do ~x ~x))

;; A multimethod with a :default method. The AOT build must set the per-ns
;; current ns before these forms run, or the defmethod registers app.util/greet
;; under the wrong ns and a dispatch to :default crashes (not a fn nil). app.core
;; adds an aliased method (util/greet :loud) — see there.
(defmulti greet (fn [kind] kind))
(defmethod greet :default [_] "greet:default")
