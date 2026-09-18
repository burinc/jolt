;; mkjar.clj — write a jar (a zip with STORED entries) from files on disk, with
;; nothing but jolt: no `zip`, no `jar`, no java.util.zip. A test fixture
;; writer — host/chez/deps-cpcache-smoke.sh builds the jar whose corruption
;; and repair it checks with it — so it does the one thing a fixture needs and
;; does it exactly: local headers, a central directory, an end record, and a
;; CRC-32 per entry. Entries are stored, never deflated; every reader of jars
;; accepts a stored entry.
;;
;;   jolt run tools/mkjar.clj OUT.jar ENTRY=FILE [ENTRY=FILE ...]
;;   jolt run tools/mkjar.clj libj.jar libj/core.clj=/tmp/core.clj
(require '[clojure.string :as str])

;; CRC-32 (IEEE 802.3, the zip flavour): table-driven, over a byte array
(def ^:private crc-table
  (long-array (map (fn [n]
                     (loop [c (long n) k 0]
                       (if (= k 8) c
                           (recur (if (odd? c) (bit-xor 0xEDB88320 (unsigned-bit-shift-right c 1))
                                      (unsigned-bit-shift-right c 1))
                                  (inc k)))))
                   (range 256))))

(defn- crc32 [^bytes bs]
  (let [n (alength bs)]
    (loop [i 0 c 0xFFFFFFFF]
      (if (= i n)
        (bit-and (bit-xor c 0xFFFFFFFF) 0xFFFFFFFF)
        (let [b (bit-and (aget bs i) 0xFF)]
          (recur (inc i)
                 (bit-xor (aget crc-table (bit-and (bit-xor c b) 0xFF))
                          (unsigned-bit-shift-right c 8))))))))

;; little-endian fields
(defn- le16 [n] (byte-array [(bit-and n 0xFF) (bit-and (bit-shift-right n 8) 0xFF)]))
(defn- le32 [n] (byte-array [(bit-and n 0xFF) (bit-and (bit-shift-right n 8) 0xFF)
                             (bit-and (bit-shift-right n 16) 0xFF) (bit-and (bit-shift-right n 24) 0xFF)]))

(defn- read-bytes [^String path]
  (let [f (java.io.File. path)
        n (.length f)
        buf (byte-array n)]
    (with-open [in (java.io.FileInputStream. f)]
      (loop [off 0]
        (when (< off n)
          (let [k (.read in buf off (- n off))]
            (when (pos? k) (recur (+ off k)))))))
    buf))

(defn- write-all [^java.io.OutputStream out parts]
  (doseq [^bytes p parts] (.write out p 0 (alength p))))

;; DOS date/time for the headers: a fixed 1980-01-01 00:00, so the jar is the
;; same bytes for the same inputs (a fixture wants that)
(def ^:private dos-time (le16 0))
(def ^:private dos-date (le16 0x21))

(defn write-jar [out entries]                ; entries: [[name bytes] ...]
  (with-open [o (java.io.FileOutputStream. ^String out)]
    (let [central (atom [])
          offset (atom 0)]
      (doseq [[^String name ^bytes data] entries]
        (let [nb (.getBytes name "UTF-8")
              crc (crc32 data)
              n (alength data)
              local (concat [(le32 0x04034b50) (le16 20) (le16 0x0800) (le16 0) dos-time dos-date
                             (le32 crc) (le32 n) (le32 n) (le16 (alength nb)) (le16 0) nb data])]
          (swap! central conj
                 [(le32 0x02014b50) (le16 20) (le16 20) (le16 0x0800) (le16 0) dos-time dos-date
                  (le32 crc) (le32 n) (le32 n) (le16 (alength nb)) (le16 0) (le16 0) (le16 0) (le16 0)
                  (le32 0) (le32 @offset) nb])
          (write-all o local)
          (swap! offset + (reduce + (map alength local)))))
      (let [cd-start @offset
            cd (apply concat @central)
            cd-size (reduce + (map alength cd))]
        (write-all o cd)
        (write-all o [(le32 0x06054b50) (le16 0) (le16 0) (le16 (count entries)) (le16 (count entries))
                      (le32 cd-size) (le32 cd-start) (le16 0)])))))

(defn -main [& [out & specs]]
  (if (or (nil? out) (empty? specs) (not (every? #(str/includes? % "=") specs)))
    (do (binding [*out* *err*] (println "usage: mkjar.clj OUT.jar ENTRY=FILE [ENTRY=FILE ...]"))
        (System/exit 2))
    (let [entries (mapv (fn [spec]
                          (let [i (str/index-of spec "=")]
                            [(subs spec 0 i) (read-bytes (subs spec (inc i)))]))
                        specs)]
      (write-jar out entries)
      (println (str out ": " (count entries) " stored entr" (if (= 1 (count entries)) "y" "ies"))))))

(apply -main *command-line-args*)
