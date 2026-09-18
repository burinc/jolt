(ns app.core)

;; Tree-shake fixture for the spliced-callee bail (jolt-lang/jolt#882).
;;
;; The shape is core.async's go-macro walkers: a small private helper that
;; `resolve`s a symbol, spliced by the inline pass into its only caller, which is
;; itself spliced into a def nothing reachable references. After splicing there
;; is no reference left to either helper, so the shake keeps them for frame
;; identity (jolt-o13s) but must NOT treat them as reachable code — a `resolve`
;; in code whose every call site is a copy never runs, and rooting it bailed the
;; whole shake of any app that merely loaded core.async without writing a go
;; form.
;;
;; So: this app must SHAKE. It bails against the pre-#882 dce.ss.
(defn- park-kind [sym]
  (if (resolve sym) :var :local))

(defn- parks? [form]
  (= :var (park-kind form)))

;; The stand-in for the go macro of an app that never expands one: nothing
;; -main reaches references it, so it is pruned and its (spliced) `resolve` is
;; not reachable code.
(defn walk-body [form]
  (parks? form))

(defn -main [& _]
  (println "spliced-resolve-app ok"))
