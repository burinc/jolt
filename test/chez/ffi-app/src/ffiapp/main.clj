;; Smoke fixture: a built binary must carry the CLOJURE half of jolt.ffi
;; (stdlib/jolt/ffi.clj), not just the host primitives from java/ffi.ss.
;; jolt.ffi is in the CLI's own AOT closure and in neither the runtime image
;; nor the stdlib-fasl manifest, so an app build that treats the CLI's closure
;; as preloaded interns these vars UNBOUND and fails at the call, not the build.
;; `jolt run` masks it by compiling the source at require time, so only a built
;; binary can catch it.
(ns ffiapp.main (:require [jolt.ffi :as ffi]))

(def pt (ffi/layout [:struct [[:x :float] [:y :float]]]))

(defn -main [& _]
  (ffi/with-layout [p pt]
    (ffi/write-field p pt [:y] 2.5)
    (println "FFI-APP"
             (ffi/layout-size pt)
             (ffi/layout-alignment pt)
             (ffi/field-offset pt [:y])
             (ffi/read-field p pt [:y])
             (string? (ffi/errno-message 2)))))
