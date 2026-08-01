;; cheshire.core over clojure.data.json, for conformance runs only.
;;
;; Selmer's own source already resolves a JSON library at load time in the order
;; cheshire -> clojure.data.json -> jsonista, so the library itself is happy with
;; data.json. Its TEST namespace, though, does (:require [cheshire.core :refer :all])
;; outright, and real cheshire is a wrapper over Jackson — Java, so not something
;; jolt can run. This shim gives the test the cheshire names over data.json.
;;
;; It is deliberately NOT a full cheshire: only what a suite under test actually
;; calls, so an unimplemented corner surfaces as an unbound var rather than as a
;; quietly wrong answer. Grow it when a suite needs more.
(ns cheshire.core
  (:require [clojure.data.json :as json]))

(defn parse-string
  "cheshire's parse-string. The second argument is cheshire's key-fn: true means
  keywordize, a fn is applied to each key string."
  ([s] (parse-string s nil))
  ([s key-fn]
   (when s
     (cond
       (true? key-fn) (json/read-str s :key-fn keyword)
       (fn? key-fn)   (json/read-str s :key-fn key-fn)
       :else          (json/read-str s)))))

(defn parse-string-strict
  ([s] (parse-string s nil))
  ([s key-fn] (parse-string s key-fn)))

(defn generate-string
  "cheshire's generate-string. data.json writes the same JSON text for the shapes
  a template renderer produces."
  ([v] (json/write-str v))
  ([v _opts] (json/write-str v)))

(def decode parse-string)
(def encode generate-string)
