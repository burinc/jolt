;; byte-arrays — RAW BYTES crossing the host boundary in bulk: block copies
;; between byte arrays, draining a stream into a reusable buffer, and the
;; String<->byte[] round trip. Per-pass work is dominated by moves of whole
;; regions, not by per-element arithmetic, which is what separates this from
;; `arrays` (indexed reads/writes on a ^doubles array).
;;
;; The axis is the BACKING a byte array holds. A jolt array is a Chez vector plus
;; an element-kind tag, and a ^bytes array's backing is a bytevector — the same
;; shape of thing the host's own I/O, string and ffi primitives take — so every
;; crossing here is a block move (bytevector-copy!, get-bytevector-n!,
;; utf8->string) instead of an element loop with a sign fold per byte. Nothing
;; else in the suite touches a byte array at all, and the paths below are exactly
;; where that shows: against v0.8.2, the last release in which a byte array was a
;; boxed vector of small integers, this whole bench runs 49x faster (13150.9ms ->
;; 270.6ms through ci/bench-gate.sh; the per-phase split is in README.md).
;;
;; The element-access phase is here for the two halves of a hinted ^bytes access,
;; which pull in opposite directions: (aget ^bytes a i) lowers to the direct
;; backing read (jolt-vaget, skipping the generic nth dispatch walk), while
;; (aset ^bytes a i v) deliberately stays on the generic path, because the store
;; has to narrow its value to signed 8 bits. A codegen round that moves either one
;; lands here.
;;
;; No unhinted twin: the generic (aget a i) / (aset a i v) dispatch walk is already
;; covered by `arrays-unhinted`, and it is the same walk for every element kind.
;; What this bench adds over that pair is the BULK path, which no hint reaches.
;;
;; Portable Clojure (jolt + JVM Clojure) — System/arraycopy, ByteArrayInputStream
;; and String/getBytes are the same operations on both, and the JVM's arraycopy is
;; an intrinsic, so that column is close to the machine's memcpy.
;;   bench/run.sh byte-arrays 400
(ns byte-arrays)

(def block (* 1024 1024))   ; the copied/drained region
(def chunk-size 8192)       ; the stream read buffer, as an I/O loop sizes it
(def cells 8192)            ; the element-access loop, sized to weigh about
                            ; the same as the three bulk phases together

;; --- block copies -------------------------------------------------------------
;; Two shapes: the whole array, and a middle-to-middle region at unequal offsets
;; (which cannot be answered by handing the destination the source's backing).
(defn copy-full! [^bytes src ^bytes dst ^long n]
  (System/arraycopy src 0 dst 0 n)
  dst)

(defn copy-region! [^bytes src ^bytes dst ^long n]
  (System/arraycopy src 8 dst 24 (- n 32))
  dst)

;; --- stream -> reusable buffer ------------------------------------------------
;; The read-into-a-buffer loop every stream consumer is written as; `buf` is
;; reused across reads, so the only per-read cost is the transfer itself.
(defn drain ^long [^bytes src ^bytes buf]
  (let [in (java.io.ByteArrayInputStream. src)
        cap (alength buf)]
    (loop [total 0]
      (let [k (.read in buf 0 cap)]
        (if (neg? k)
          total
          (recur (unchecked-add total k)))))))

;; --- String <-> byte[] round trip ---------------------------------------------
;; Encode and decode, the shape anything speaking a byte protocol does per message.
(defn round-trip ^long [^String s ^long reps]
  (loop [i 0 acc 0]
    (if (< i reps)
      (recur (inc i) (unchecked-add acc (.length (String. (.getBytes s)))))
      acc)))

;; --- element access -----------------------------------------------------------
(defn bfill! [^bytes a ^long n]
  (loop [i 0]
    (when (< i n)
      (aset a i (byte (bit-and i 127)))
      (recur (inc i))))
  a)

(defn bsum ^long [^bytes a ^long n]
  (loop [i 0 acc 0]
    (if (< i n)
      (recur (inc i) (unchecked-add acc (aget a i)))
      acc)))

;; One pass: two block copies of `block` bytes, one full drain of `block` bytes
;; through a `chunk-size` buffer, four String<->byte[] round trips over a 5KB
;; string, and a fill+sum over `cells` elements. The arrays are allocated once and
;; reused, so allocation is not part of the measurement. At the default size the
;; three bulk phases and the element loop each take about half the time.
(defn run ^long [^long passes]
  (let [src (bfill! (byte-array block) block)
        dst (byte-array block)
        buf (byte-array chunk-size)
        cel (byte-array cells)
        s   (apply str (repeat 1000 "abcde"))]
    (loop [p 0 acc 0]
      (if (< p passes)
        (recur (inc p)
               (unchecked-add
                acc
                (unchecked-add
                 (unchecked-add (aget ^bytes (copy-full! src dst block) 1023)
                                (aget ^bytes (copy-region! src dst block) 1023))
                 (unchecked-add (unchecked-add (drain src buf) (round-trip s 4))
                                (bsum (bfill! cel cells) cells)))))
        acc))))

(defn -main [& args]
  (let [passes (if (seq args) (Integer/parseInt (first args)) 400)]
    (dotimes [_ 2] (run (quot passes 4)))                ; warmup
    (let [runs 3
          ts (mapv (fn [_]
                     (let [t0 (System/nanoTime)
                           r (run passes)
                           ms (/ (- (System/nanoTime) t0) 1000000.0)]
                       (when (zero? r) (println "unexpected zero"))
                       ms))
                   (range runs))
          mean (/ (reduce + ts) runs)]
      (println "byte-arrays passes" passes)
      (println "runs:" (mapv (fn [t] (/ (Math/round (* t 10.0)) 10.0)) ts))
      (println "mean:" (/ (Math/round (* mean 10.0)) 10.0) "ms"))))
