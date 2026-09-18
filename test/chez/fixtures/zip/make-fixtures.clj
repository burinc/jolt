;; make-fixtures.clj — write the java.util.zip fixture archives with JDK 21. Run
;; once from the repository root, and commit what it writes:
;;   JAVA_CMD=/path/to/jdk-21/bin/java clojure -M test/chez/fixtures/zip/make-fixtures.clj
(require '[clojure.java.io :as io]
         '[clojure.string :as str])

(def dir (io/file (or (first *command-line-args*) "test/chez/fixtures/zip")))

;; Fixed content, so a second run writes the same entries.
(defn utf8 ^bytes [^String s] (.getBytes s "UTF-8"))
(defn random-bytes ^bytes [seed n]
  (let [b (byte-array n)] (.nextBytes (java.util.Random. seed) b) b))
(defn crc32 [^bytes b] (.getValue (doto (java.util.zip.CRC32.) (.update b))))
(def modified (java.time.LocalDateTime/of 2026 9 14 12 0 0))

;; An archive from JDK 21's ZipOutputStream. ENTRIES is [name bytes method].
(defn write-zip [name entries]
  (with-open [out (java.util.zip.ZipOutputStream. (io/output-stream (io/file dir name)))]
    (doseq [[entry-name ^bytes bytes method] entries]
      (let [e (java.util.zip.ZipEntry. ^String entry-name)]
        (.setTimeLocal e modified)
        (when (= method :stored)
          (.setMethod e java.util.zip.ZipEntry/STORED)
          (.setSize e (alength bytes))
          (.setCompressedSize e (alength bytes))
          (.setCrc e (crc32 bytes)))
        (.putNextEntry out e)
        (.write out bytes)
        (.closeEntry out)))))

;; Little-endian integer fields.
(defn le ^bytes [n width]
  (byte-array (map #(unchecked-byte (bit-shift-right n (* 8 %))) (range width))))
(defn raw-deflate ^bytes [^bytes b]
  (let [d (java.util.zip.Deflater. java.util.zip.Deflater/DEFAULT_COMPRESSION true)
        out (java.io.ByteArrayOutputStream.)
        buf (byte-array 4096)]
    (.setInput d b)
    (.finish d)
    (while (not (.finished d))
      (.write out buf 0 (.deflate d buf)))
    (.end d)
    (.toByteArray out)))

;; An archive of deflated entries whose data descriptors have no signature
;; (APPNOTE 6.3.10 section 4.3.9.3). ZipOutputStream always writes the
;; signature, so this one is written field by field.
(defn write-no-signature-descriptors [name entries]
  (let [out (java.io.ByteArrayOutputStream.)
        cen (java.io.ByteArrayOutputStream.)
        put (fn [^java.io.ByteArrayOutputStream o & parts]
              (doseq [^bytes p parts] (.write o p 0 (alength p))))
        dos-time (bit-shift-left 12 11)
        dos-date (bit-or (bit-shift-left (- 2026 1980) 9) (bit-shift-left 9 5) 14)]
    (doseq [[entry-name ^bytes bytes] entries]
      (let [offset (.size out)
            n (utf8 entry-name)
            z (raw-deflate bytes)
            c (crc32 bytes)]
        (put out (le 0x04034b50 4) (le 20 2) (le 8 2) (le 8 2) (le dos-time 2) (le dos-date 2)
             (le 0 4) (le 0 4) (le 0 4) (le (alength n) 2) (le 0 2) n z
             (le c 4) (le (alength z) 4) (le (alength bytes) 4))
        (put cen (le 0x02014b50 4) (le 20 2) (le 20 2) (le 8 2) (le 8 2) (le dos-time 2) (le dos-date 2)
             (le c 4) (le (alength z) 4) (le (alength bytes) 4) (le (alength n) 2) (le 0 2) (le 0 2)
             (le 0 2) (le 0 2) (le 0 4) (le offset 4) n)))
    (let [cen-offset (.size out)
          cen-bytes (.toByteArray cen)]
      (put out cen-bytes
           (le 0x06054b50 4) (le 0 2) (le 0 2) (le (count entries) 2) (le (count entries) 2)
           (le (alength cen-bytes) 4) (le cen-offset 4) (le 0 2)))
    (with-open [f (io/output-stream (io/file dir name))]
      (.writeTo out f))))

(.mkdirs dir)

(write-zip "deflated.zip"
           [["hello.txt" (utf8 "hello, zip\n") :deflated]
            ["docs/" (byte-array 0) :deflated]
            ["docs/notes.txt" (utf8 (str/join (repeat 80 "a line of notes for the deflater\n"))) :deflated]
            ["data/random.bin" (random-bytes 916 6000) :deflated]
            ["empty.txt" (byte-array 0) :deflated]
            ["empty-dir/" (byte-array 0) :deflated]])

;; A UTF-8 name sets general purpose flag bit 11.
(write-zip "utf8-name.zip"
           [["名前/ファイル.txt" (utf8 "unicode name\n") :deflated]
            ["plain.txt" (utf8 "plain name\n") :deflated]])

(write-zip "stored.zip"
           [["a.txt" (utf8 "stored\n") :stored]
            ["b/" (byte-array 0) :stored]
            ["b/random.bin" (random-bytes 988 3000) :stored]
            ["empty.txt" (byte-array 0) :stored]])

(write-zip "mixed.zip"
           [["one.txt" (utf8 "first, stored\n") :stored]
            ["two.txt" (utf8 (str/join (repeat 60 "second, deflated\n"))) :deflated]
            ["three.bin" (random-bytes 2026 700) :stored]
            ["four.txt" (utf8 "fourth, deflated\n") :deflated]])

(write-no-signature-descriptors "no-signature-descriptors.zip"
                                [["first.txt" (utf8 (str/join (repeat 20 "no signature\n")))]
                                 ["second.txt" (utf8 "second entry\n")]])

(println "wrote" (count (filter #(str/ends-with? (.getName ^java.io.File %) ".zip") (.listFiles dir)))
         "archives in" (str dir))
