;; hello — the startup row: nothing but a main that prints. bench/run.sh and
;; ci/bench-gate.sh build it and time the WHOLE process, exec to exit, which is
;; the boot image's decode plus the runtime's init and is what every other row
;; excludes by timing inside an already-running binary.
;;
;; Portable Clojure (jolt + JVM Clojure).
(ns hello)

(defn -main [& _] (println "hello"))
