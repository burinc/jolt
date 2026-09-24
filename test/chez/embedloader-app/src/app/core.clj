(ns app.core
  (:require [clojure.java.io :as io]
            [jolt.loader :as loader]))

(defn -main [& args]
  ;; --embedloader: a loader root over the binary's EMBEDDED resources. A build
  ;; bakes deps.edn :jolt/build {:embed [dirs]} into its heap, so a root spelled
  ;; "embed:<prefix>" serves namespaces and resources with nothing on disk — the
  ;; shape a shipped app uses to run a plugin or extension bundle it carries.
  ;; The fixture namespaces under assets/ are in no app closure (nothing
  ;; requires them), so a loader context is the only way they exist in this
  ;; binary. Only a built binary has an embedded store to resolve against, which
  ;; is why build-smoke runs this from /.
  (if (= (first args) "--embedloader")
    (let [ctx (loader/classpath ["embed:bundled"] {:id "embedloader" :parent (loader/isolated)})
          bad (loader/classpath ["embed:not/there"] {:parent (loader/isolated)})]
      (loader/load ctx {:kind :ns :name "fixture.entry"})
      (let [answer (loader/resolve ctx {:kind :var :name "fixture.entry/answer"})
            src (loader/resolve ctx {:kind :var :name "fixture.entry/source-file"})
            ns-hit (first (loader/find ctx {:kind :ns :name "fixture.lib"}))
            data-hit (first (loader/find ctx {:kind :resource :name "fixture/data.txt"}))
            cl (loader/as-classloader ctx)]
        (println "embedloader:"
                 ;; loaded through the root, with its own (:require …) served by
                 ;; the same root
                 (= 42 (answer))
                 ;; *file* during the load is the embedded key, not a path
                 (= "bundled/fixture/entry.clj" @src)
                 ;; hits name embedded keys, and a resource hit says so
                 (= "bundled/fixture/lib.clj" (:file ns-hit))
                 (and (= "bundled/fixture/data.txt" (:url data-hit))
                      (true? (:embedded? data-hit)))
                 ;; io/resource inside the context, the ClassLoader surface and
                 ;; the hit's own open all read the embedded copy
                 (= (slurp (loader/with-loader* ctx #(io/resource "fixture/data.txt")))
                    (slurp (.getResourceAsStream cl "fixture/data.txt"))
                    (slurp (loader/open-hit ctx data-hit)))
                 ;; the host root serves the same baked resource by its full key,
                 ;; and opening that hit takes the unmarked path (the resolved
                 ;; resource straight into io/input-stream)
                 (= "bundled fixture data\n"
                    (slurp (loader/open-hit (loader/root)
                                            (first (loader/find (loader/root)
                                                                {:kind :resource
                                                                 :name "bundled/fixture/data.txt"})))))
                 ;; the facade's stream is an InputStream, not a Reader: a
                 ;; URL's openStream is byte-level, and the reader it used to
                 ;; hand back mangled binary payloads and broke
                 ;; (InputStreamReader. …)-style composition
                 (and (instance? java.io.InputStream (.getResourceAsStream cl "fixture/data.txt"))
                      (not (instance? java.io.Reader (.getResourceAsStream cl "fixture/data.txt"))))
                 ;; the context's namespace is private to it, not the host's
                 (nil? (first (loader/find (loader/root) {:kind :ns :name "fixture.entry"})))
                 ;; a prefix holding nothing misses, and the loader names its own
                 ;; miss rather than a file that could exist
                 (and (empty? (loader/find bad {:kind :ns :name "fixture.entry"}))
                      (= :loader/miss
                         (:type (ex-data (try (loader/load bad {:kind :ns :name "fixture.entry"})
                                              nil
                                              (catch :default e e))))))))
      (loader/unload! ctx))
    (println "embedloader-app ran")))
