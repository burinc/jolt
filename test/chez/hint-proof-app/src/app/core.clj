(ns app.core)

;; A ^String or ^Keyword hint is a contract for interop, not a proof of the
;; value: string?, nil?, count and str still look at what was passed. Every value
;; goes through an atom, so inference can't prove its type and only the hint is
;; left to go on, as with ring-codec's form-encode*, whose ^String encoding is a
;; Charset.

(defn- opaque [x] @(atom x))

(defn- to-charset [s] (if (string? s) [:named s] s))
(defn encode [^String _ ^String enc] (to-charset enc))

(defprotocol Enc (enc* [x enc]))
(extend-protocol Enc
  String (enc* [^String _ ^String enc] (to-charset enc)))

(defn str? [^String x] (string? x))
(defn absent? [^String x] (nil? x))
(defn kw? [^clojure.lang.Keyword x] (keyword? x))
(defn len [^String x] (count x))
(defn cat2 [^String a ^String b] (str a b))
(defn shout [^String s] (.toUpperCase s))
(defn size [^String s] (let [t s] (.length t)))

(defrecord Named [^String nm])

(defn -main [& _]
  (println (encode "a" (opaque :utf-8)))
  (println (enc* "a" (opaque :utf-8)))
  (println (str? (opaque 42)))
  (println (absent? (opaque nil)))
  (println (kw? (opaque "k")))
  (println (len (opaque [1 2 3])))
  (println (cat2 (opaque 1) (opaque 2)))
  (println (nil? (:nm (->Named (opaque nil)))))
  ;; and the hint still drives interop, directly and through a let
  (println (shout (opaque "ab")))
  (println (size (opaque "abc"))))
