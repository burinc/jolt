;; What a body spliced into its callers (jolt build's inline pass) must keep of
;; the fn it came from. Each answer is the JVM's, with direct linking on or off.
(ns app.core)

;; One literal site is one object however many callers it is spliced into.
(defn q-list [] '(a b))
(defn q-sym [] 'a)
(defn q-map [] {:k 'a})
(defn q-vec [] [:k 'a])
(defn q-set [] #{:k 'a})
(defn rx [] #"a+")

;; A ^long return truncates to the low 64 bits and saturates a flonum, whether
;; the call runs the fn or a copy of its body.
(defn ^long rt1 [x] x)
(defn ^long rt2 [x] x)
(defn arl1 ^long [x] x)
(def arl3 (fn ^long [x] x))

(defn f2 [x y] x)

(defn -main [& _]
  (println (identical? (q-list) (q-list)) (identical? (q-sym) (q-sym))
           (identical? (q-map) (q-map)) (identical? (q-vec) (q-vec))
           (identical? (q-set) (q-set)) (identical? (rx) (rx)))
  (println [(rt1 18446744073709551616N) (rt1 18446744073709551621N)
            (rt1 9223372036854775808N) (rt1 -18446744073709551616N)])
  (println [(rt2 ##Inf) (rt2 ##-Inf) (rt2 ##NaN) (rt2 1e300) (rt2 7/2)])
  (println [(arl1 18446744073709551616N) (arl3 18446744073709551616N) (arl3 7/2)])
  ;; the JVM clears a lazy seq's captured locals once its body has run, so a
  ;; body that threw sees them nil on the next realization
  (println (let [s (let [v [1 2 3]]
                     (lazy-seq (if (nil? v) (list :locals-cleared) (throw (ex-info "boom2" {})))))]
             [(try (seq s) (catch Exception e (ex-message e)))
              (try (seq s) (catch Exception e (ex-message e)))
              (realized? s)]))
  (println (try (f2 1) (catch clojure.lang.ArityException e (ex-message e)))))
