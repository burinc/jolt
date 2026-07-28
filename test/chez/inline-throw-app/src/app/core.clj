(ns app.core)

(defn -main [& _]
  ;; scalar-replace folds (:a {:a 1 :b (/ 1 0)}) -> 1 under --opt --direct-link,
  ;; discarding the throwing sibling. The divisor must still evaluate: / is not a
  ;; pure fn, so the map is kept, the ArithmeticException fires, and the catch
  ;; prints THROW OK instead of the folded 1.
  (println
    (try
      (:a {:a 1 :b (/ 1 0)})
      (catch ArithmeticException _ "THROW OK")))
  ;; Same for a literal :throw IR node as an unread map value: safe-op? admitted
  ;; :throw, so pure?/total? treated it as discardable and elim-let-structs
  ;; dropped the binding — the release binary printed 1 instead of throwing.
  ;; A throw is relocatable (safe-op?) but never pure/total.
  (println
    (try
      (let [m {:a 1 :b (throw "boom")}] (:a m))
      (catch :default _ "THROW2 OK"))))
