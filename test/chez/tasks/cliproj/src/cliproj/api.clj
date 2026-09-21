(ns cliproj.api
  "Handlers for the CLI-task fixture. Every one prints what it was called with,
  so the smoke test asserts on the map the runner built rather than on a side
  effect further down.")

(defn greet
  "Greet someone."
  [m]
  (println "greet" (pr-str (into (sorted-map) m))))

(defn migrate [m]
  (println "migrate" (pr-str (into (sorted-map) m))))

(defn seed [m]
  (println "seed" (pr-str (into (sorted-map) m))))

;; The spec on the handler itself, which is what `bb -x` reads and what a task
;; naming this fn inherits without repeating it in bb.edn.
(defn ^{:org.babashka/cli {:spec {:port {:coerce :long :desc "port to listen on"
                                         :default 8080}}}}
  serve
  "Serve the app."
  [m]
  (println "serve" (pr-str (into (sorted-map) m))))

(defn setup
  "Prepare the app."
  [m]
  (println "setup" (pr-str (into (sorted-map) m))))

;; Options that cannot be written in edn, held in code and named by :cli.
(def greet-opts
  {:spec {:name {:desc "who to greet" :default "world"}
          :loud {:coerce :boolean :desc "shout it"}}})

(defn body-and-tree [m]
  (println "sub" (pr-str (into (sorted-map) m))))

(defn body-and-tree2 [m]
  (println "tree-by-sym" (pr-str (into (sorted-map) m))))

;; A command tree held in code, named by a task's :cmd — how a large tree stays
;; out of bb.edn.
(def tree
  {"up" {:doc "bring it up" :exec-fn body-and-tree2}})

(defn boom
  "Fail on purpose."
  [_]
  (throw (ex-info "handler said no" {})))
