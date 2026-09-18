;; The boundary of analyze/unknown-namespace, the side that stays late-bound: a
;; bare Capitalized name is how an :import-ed class short name is spelled, and a
;; provider's class may not be registered until it autoloads on first use — after
;; the fn referencing it compiled. So `Nope/foo` with no such class stays a host
;; static and reports as a class miss at the call, not at compile time (a
;; documented divergence in known-divergences.edn). Pinned here so widening the
;; analyzer check has to move this on purpose.
(ns input)

(defn f [] (Nope/foo 1))

(f)
