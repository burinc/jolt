;; Confined-arena bookkeeping benchmark. Jolt-only: there is no JVM FFI
;; reference for this API. Retain every sample and alternate scenario order so
;; drift is visible; compare exact base/candidate runs on the same host.
(ns ffi-arenas
  (:require [jolt.ffi :as ffi]))

(defn- touch [p]
  (ffi/write p :int64 42 0)
  (when-not (= 42 (ffi/read p :int64))
    (throw (ex-info "FFI round-trip failed" {}))))

(defn- raw [n]
  (dotimes [_ n]
    (let [p (ffi/alloc 8)]
      (try (touch p) (finally (ffi/free p))))))

(defn- empty-arenas [n]
  (dotimes [_ n]
    (let [a (ffi/confined-arena)]
      (ffi/close-arena a))))

(defn- grouped [n batch]
  (dotimes [_ (quot n batch)]
    (let [a (ffi/confined-arena)]
      (try
        (dotimes [_ batch] (touch (ffi/alloc a 8)))
        (finally (ffi/close-arena a))))))

(defn- time-call [f]
  (let [start (System/nanoTime)]
    (f)
    (- (System/nanoTime) start)))

(defn -main [& args]
  (let [n (if (seq args) (Integer/parseInt (first args)) 30000)
        cases [[:raw #(raw n)]
               [:empty-arena #(empty-arenas n)]
               [:arena-per-allocation #(grouped n 1)]
               [:arena-per-10 #(grouped n 10)]
               [:arena-per-100 #(grouped n 100)]
               [:arena-per-1000 #(grouped n 1000)]]]
    (raw 1000)
    (empty-arenas 1000)
    (grouped 1000 1)
    (grouped 1000 10)
    (let [results
          (reduce (fn [out round]
                    (reduce (fn [acc [label call]]
                              (update acc label (fnil conj []) (time-call call)))
                            out (if (even? round) cases (reverse cases))))
                  {} (range 5))]
      (prn {:iterations n
            :allocation-bytes 8
            :clock :monotonic-nanoseconds
            :samples-ns results
            :median-ns
            (into {} (map (fn [[k v]] [k (nth (sort v) 2)]) results))}))))
