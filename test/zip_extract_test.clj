;; jolt.host/extract-zip! over the zip fixtures (test/chez/fixtures/zip, written
;; by make-fixtures.clj there): the trees unzip -o -q made, UTF-8 names, an
;; archive with a comment, an entry larger than the copy buffer, files that are
;; already there, refused names, a symbolic link on the way, and archives that
;; are not whole.
;; Run from the repository root: bin/jolt run test/zip_extract_test.clj
(ns zip-extract-test
  (:require [clojure.edn :as edn]
            [clojure.string :as str]))

(def fixtures "test/chez/fixtures/zip")

(def ^:private created (atom []))

(defn- fail! [what data]
  (throw (ex-info (str "zip extract: " what) data)))

(defn- fresh-dir
  "A new empty directory under the temporary directory."
  [label]
  (let [d (str (System/getProperty "java.io.tmpdir") "/jolt-zip-extract-" label "-"
               (System/currentTimeMillis) "-" (rand-int 1000000))]
    (when-not (jolt.host/mkdirs! d)
      (fail! "could not make a directory" {:dir d}))
    (swap! created conj d)
    d))

(defn- tree
  "Every path under DIR, sorted, with a slash after a directory."
  [dir]
  (letfn [(walk [rel]
            (mapcat (fn [n]
                      (let [r (if (= rel "") n (str rel "/" n))]
                        (if (jolt.host/directory? (str dir "/" r))
                          (cons (str r "/") (walk r))
                          [r])))
                    (jolt.host/list-dir (if (= rel "") dir (str dir "/" rel)))))]
    (vec (sort (walk "")))))

(defn- file-bytes [path]
  (with-open [in (java.io.FileInputStream. path)]
    (vec (.readAllBytes in))))

(defn- le
  "N as WIDTH little-endian bytes."
  [n width]
  (mapv (fn [i] (unchecked-byte (bit-and (bit-shift-right n (* 8 i)) 255))) (range width)))

(defn- write-bytes! [path bytes]
  (with-open [out (java.io.FileOutputStream. path)]
    (.write out (byte-array bytes))))

(defn- extract [zip dir]
  (let [r (jolt.host/extract-zip! zip dir)]
    (when-not (boolean? r)
      (fail! "the answer is not a boolean" {:zip zip :result r}))
    r))

(defn- same-as-unzip!
  "DIR holds the paths and bytes unzip -o -q made of ARCHIVE."
  [archive dir]
  (let [base (str/replace archive #"\.zip$" "")
        expected (edn/read-string (slurp (str fixtures "/" base ".tree.edn")))]
    (when-not (= expected (tree dir))
      (fail! "the tree differs from unzip's" {:archive archive :expected expected :actual (tree dir)}))
    (doseq [p expected :when (not (str/ends-with? p "/"))]
      (when-not (= (file-bytes (str fixtures "/" base ".tree/" p)) (file-bytes (str dir "/" p)))
        (fail! "the bytes differ from unzip's" {:archive archive :path p})))))

(defn- run-cases []
  ;; Each safe archive extracts to the tree unzip -o -q made.
  (doseq [archive ["deflated.zip" "stored.zip" "mixed.zip" "no-signature-descriptors.zip"]]
    (let [d (fresh-dir "tree")]
      (when-not (extract (str fixtures "/" archive) d)
        (fail! "an extraction failed" {:archive archive}))
      (same-as-unzip! archive d)))

  ;; UTF-8 names. The unzip that made the trees cannot write these names, so
  ;; the paths and bytes are the ones JDK 21's ZipInputStream reads from
  ;; utf8-name.zip.
  (let [d (fresh-dir "utf8")]
    (when-not (extract (str fixtures "/utf8-name.zip") d)
      (fail! "an extraction failed" {:archive "utf8-name.zip"}))
    (when-not (= ["plain.txt" "名前/" "名前/ファイル.txt"] (tree d))
      (fail! "the UTF-8 tree differs" {:actual (tree d)}))
    (when-not (and (= "plain name\n" (slurp (str d "/plain.txt")))
                   (= "unicode name\n" (slurp (str d "/名前/ファイル.txt"))))
      (fail! "the UTF-8 entries' bytes differ" {})))

  ;; Files already at the entries' paths are replaced, and a second extraction
  ;; over the tree gives the same tree.
  (let [d (fresh-dir "replace")]
    (spit (str d "/hello.txt") "a longer file that was here before the archive")
    (jolt.host/mkdirs! (str d "/docs"))
    (spit (str d "/docs/notes.txt") "old")
    (when-not (and (extract (str fixtures "/deflated.zip") d)
                   (extract (str fixtures "/deflated.zip") d))
      (fail! "an extraction over existing files failed" {}))
    (same-as-unzip! "deflated.zip" d))

  ;; A refused name refuses the archive: the entry before it stays, nothing is
  ;; written outside the target, and no temporary file is left.
  (doseq [archive ["unsafe-absolute.zip" "unsafe-drive.zip" "unsafe-backslash.zip" "unsafe-dotdot.zip"]]
    (let [outer (fresh-dir "unsafe")
          d (str outer "/one/two/target")]
      (when (extract (str fixtures "/" archive) d)
        (fail! "a refused name extracted" {:archive archive}))
      (when-not (= ["one/" "one/two/" "one/two/target/" "one/two/target/safe.txt"] (tree outer))
        (fail! "a refused archive wrote more than its safe entry" {:archive archive :tree (tree outer)}))))

  ;; An entry larger than the copy buffer (65536 bytes) runs the copy loop more
  ;; than once. Every fixture entry is smaller, and their bytes are pinned by
  ;; the corpus rows, so this archive is built here: one stored entry, its
  ;; central directory record, and the end record.
  (let [d (fresh-dir "large")
        name (vec (.getBytes "big.bin" "UTF-8"))
        data (mapv (fn [i] (unchecked-byte (mod (* i 7) 256))) (range 200000))
        crc (let [c (java.util.zip.CRC32.)] (.update c (byte-array data)) (.getValue c))
        header (concat [80 75 3 4 20 0 0 0 0 0 0 0 0 0] (le crc 4) (le (count data) 4)
                       (le (count data) 4) (le (count name) 2) [0 0] name)
        central (concat [80 75 1 2 20 0 20 0 0 0 0 0 0 0 0 0] (le crc 4) (le (count data) 4)
                        (le (count data) 4) (le (count name) 2) [0 0 0 0 0 0 0 0 0 0 0 0]
                        (le 0 4) name)
        archive (str d "/large.zip")
        target (fresh-dir "large-out")]
    (write-bytes! archive
                  (concat header data central
                          [80 75 5 6 0 0 0 0 1 0 1 0] (le (count central) 4)
                          (le (+ (count header) (count data)) 4) [0 0]))
    (when-not (extract archive target)
      (fail! "an archive with a large entry failed" {}))
    (when-not (= ["big.bin"] (tree target))
      (fail! "the large entry's tree differs" {:tree (tree target)}))
    (when-not (= data (file-bytes (str target "/big.bin")))
      (fail! "the large entry's bytes differ" {:size (count (file-bytes (str target "/big.bin")))})))

  ;; A symbolic link on the way refuses the archive, and nothing is written
  ;; through it: a link in place of a directory, and a link at a file's own
  ;; path. POSIX only: ln -s makes the link.
  (when-not (str/starts-with? (str/lower-case (System/getProperty "os.name")) "windows")
    ;; sh takes these paths, and pr-str is not shell quoting: refuse a
    ;; temporary directory whose name would need it.
    (let [d (fresh-dir "meta")]
      (when (re-find #"[^A-Za-z0-9/._-]" d)
        (fail! "the temporary directory needs shell quoting" {:dir d})))
    (let [d (fresh-dir "link")
          outside (fresh-dir "outside")]
      (when-not (zero? (jolt.host/sh (str "ln -s " (pr-str outside) " " (pr-str (str d "/docs")))))
        (fail! "ln -s failed" {}))
      (when (extract (str fixtures "/deflated.zip") d)
        (fail! "an archive extracted through a symbolic link" {}))
      (when-not (= [] (tree outside))
        (fail! "an extraction wrote through a symbolic link" {:tree (tree outside)})))
    (let [d (fresh-dir "file-link")
          outside (fresh-dir "file-outside")
          kept (str outside "/kept.txt")]
      (spit kept "kept\n")
      (when-not (zero? (jolt.host/sh (str "ln -s " (pr-str kept) " " (pr-str (str d "/hello.txt")))))
        (fail! "ln -s failed" {}))
      (when (extract (str fixtures "/deflated.zip") d)
        (fail! "an archive extracted over a symbolic link" {}))
      (when-not (and (= "kept\n" (slurp kept)) (= ["kept.txt"] (tree outside)))
        (fail! "an extraction wrote through a symbolic link" {:tree (tree outside)}))))

  ;; What is not a whole archive answers false without throwing: a missing file,
  ;; a directory, a file that is not a zip, a file that holds an end record's
  ;; signature but no record, an archive cut before its central directory, an
  ;; archive whose second local header is broken, and an entry whose bytes do
  ;; not match its CRC-32.
  (let [stored (file-bytes (str fixtures "/stored.zip"))
        index-of (fn [pattern from]
                   (first (for [i (range from (- (count stored) (count pattern)))
                                :when (= pattern (subvec stored i (+ i (count pattern))))]
                            i)))
        scratch (fresh-dir "bad")
        not-zip (str scratch "/not-a-zip.zip")
        fake-record (str scratch "/fake-record.zip")
        cut (str scratch "/cut.zip")
        broken-header (str scratch "/broken-header.zip")
        corrupt (str scratch "/corrupt.zip")
        ;; the last byte of the second local header's signature
        second-header (+ (index-of [80 75 3 4] 1) 3)
        ;; ten bytes into the data of b/random.bin, which follows its name
        data (+ (index-of (vec (.getBytes "b/random.bin" "UTF-8")) 0) 12 10)]
    (spit not-zip "this is not a zip file\n")
    ;; a signature and a zero entry count, but text after the 22 bytes where the
    ;; comment would have to end the file
    (write-bytes! fake-record (concat (.getBytes "hello " "UTF-8") [80 75 5 6] (repeat 18 0)
                                      (.getBytes " and more text, not an archive\n" "UTF-8")))
    (write-bytes! cut (subvec stored 0 (index-of [80 75 1 2] 0)))
    (write-bytes! broken-header (assoc stored second-header 5))
    (write-bytes! corrupt (assoc stored data (bit-xor (stored data) 1)))
    ;; A comment ends the file: the end record's comment length, at offset 20
    ;; of the record, counts the bytes after it. This comment has the largest
    ;; length, 65535 bytes (-1 -1), so the record is at the start of the tail
    ;; that extract-zip! reads.
    (let [with-comment (str scratch "/with-comment.zip")
          text (vec (take 65535 (cycle (.getBytes "an archive comment " "UTF-8"))))
          eocd (last (for [i (range (- (count stored) 21))
                           :when (= [80 75 5 6] (subvec stored i (+ i 4)))]
                       i))
          d (fresh-dir "comment")]
      (write-bytes! with-comment (concat (assoc stored (+ eocd 20) -1 (+ eocd 21) -1) text))
      (when-not (extract with-comment d)
        (fail! "an archive with a comment failed" {}))
      (same-as-unzip! "stored.zip" d))
    ;; An archive whose central directory was cut away keeps its local entries
    ;; and its end record. The entry count alone cannot tell: the directory the
    ;; end record points at has to be there and hold what it says.
    (let [no-cd (str scratch "/no-central-directory.zip")
          cd (index-of [80 75 1 2] 0)
          eocd (last (for [i (range (- (count stored) 21))
                           :when (= [80 75 5 6] (subvec stored i (+ i 4)))]
                       i))]
      (write-bytes! no-cd (concat (subvec stored 0 cd) (subvec stored eocd)))
      ;; An end record counting 0xFFFF is a Zip64 archive's, and its real count
      ;; is in the Zip64 end record. Without one, the count proves nothing: this
      ;; archive's first local header is broken too, so nothing extracts.
      (let [ffff (str scratch "/count-ffff.zip")]
        (write-bytes! ffff (-> stored (assoc 0 88) (assoc (+ eocd 8) -1) (assoc (+ eocd 9) -1)
                               (assoc (+ eocd 10) -1) (assoc (+ eocd 11) -1)))
        (doseq [[label zip] [["an archive with no central directory" no-cd]
                             ["an end record counting 0xFFFF with no Zip64 end record" ffff]]]
          (let [d (fresh-dir "cd")]
            (when (extract zip d)
              (fail! (str label " extracted") {:zip zip}))
            (when-not (= [] (tree d))
              (fail! (str label " wrote files") {:tree (tree d)}))))))
    (doseq [[label zip] [["a missing file" (str scratch "/absent.zip")]
                         ["a directory" scratch]
                         ["a file that is not a zip" not-zip]
                         ["a file with an end record's signature and no record" fake-record]
                         ["an archive with no central directory" cut]]]
      (let [d (fresh-dir "bad-target")]
        (when (extract zip d)
          (fail! (str label " extracted") {}))
        (when-not (= [] (tree d))
          (fail! (str label " wrote files") {:tree (tree d)}))))
    (let [d (fresh-dir "broken-header")]
      (when (extract broken-header d)
        (fail! "an archive with a broken local header extracted" {}))
      (when-not (= ["a.txt"] (tree d))
        (fail! "a broken header left more than the entries before it" {:tree (tree d)})))
    (let [d (fresh-dir "corrupt")]
      (when (extract corrupt d)
        (fail! "an entry with a bad CRC-32 extracted" {}))
      (when-not (= ["a.txt" "b/"] (tree d))
        (fail! "a bad entry left more than the entries before it" {:tree (tree d)}))))

  ;; An archive that is only an end record extracts nothing and answers true.
  (let [scratch (fresh-dir "empty")
        zip (str scratch "/empty.zip")
        d (str scratch "/target")]
    (write-bytes! zip (concat [80 75 5 6] (repeat 18 0)))
    (when-not (extract zip d)
      (fail! "an archive with no entries failed" {}))
    (when-not (= [] (tree d))
      (fail! "an archive with no entries wrote files" {:tree (tree d)}))))

(try
  (run-cases)
  (finally
    (doseq [d @created] (jolt.host/delete-tree! d))))

(println "zip extract gate: passed")
