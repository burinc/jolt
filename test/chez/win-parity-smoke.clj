;; End-to-end checks for the Windows parity reports #1108, #1109, #1117, #1118
;; and #1119: each is the issue's own repro, asserted the way the JVM answers.
;; Runs on any host (the child program and the drive spelling follow os.name),
;; but it exists for the ones a POSIX runner cannot see:
;;
;;   tools/wine/run.sh jolt-nt test/chez/win-parity-smoke.clj  # under Wine
;;   make winparity                                             # this host
;;
;; Exits 1 on any failure.
(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.java.io :as io]
         '[clojure.java.shell :as sh]
         '[clojure.string :as str])

(def windows? (str/starts-with? (System/getProperty "os.name") "Windows"))
(def fails (atom 0))
(def total (atom 0))

(defmacro check [label expr want]
  `(let [got# (try ~expr (catch Throwable e# [:threw (str e#)]))]
     (swap! total inc)
     (if (= got# ~want)
       (println "ok  " ~label)
       (do (swap! fails inc)
           (println "FAIL" ~label "\n     got: " (pr-str got#) "\n     want:" (pr-str ~want))))))

(def root (str (fs/create-temp-dir {:prefix "jolt-parity"})))
(defn under [& parts] (str/join "/" (cons root parts)))
(defn gone? [f] (not (fs/exists? f)))

;; --- #1108: every subprocess spawn --------------------------------------------
(def echo-argv (if windows? ["cmd" "/c" "echo" "hi"] ["sh" "-c" "echo hi"]))

(check "#1108 ProcessBuilder reads the child's stdout"
       (let [pr (.start (ProcessBuilder. echo-argv))
             out (str/trim (slurp (.getInputStream pr)))]
         [out (.waitFor pr)])
       ["hi" 0])
(check "#1108 babashka.process/shell"
       (-> (apply p/shell {:out :string :err :string} echo-argv) :out str/trim)
       "hi")
(check "#1108 clojure.java.shell/sh, nonzero exit"
       (let [r (apply sh/sh (if windows? ["cmd" "/c" "exit 3"] ["sh" "-c" "exit 3"]))] (:exit r))
       3)
(check "#1108 an argument with a space arrives whole"
       (let [r (apply sh/sh (if windows?
                              ["cmd" "/c" "echo" "a b"]
                              ["sh" "-c" "printf '%s' \"$1\"" "sh" "a b"]))]
         (str/trim (:out r)))
       (if windows? "\"a b\"" "a b"))

;; --- #1109: PushbackReader.close closes the wrapped reader ---------------------
(let [f (under "close-only.clj")]
  (spit f "(ns dep)")
  (with-open [r (java.io.PushbackReader. (io/reader f))])
  (fs/delete f)
  (check "#1109 with-open PushbackReader releases the file" (gone? f) true))

;; --- #1117: ...and still after clojure.core/read -------------------------------
(let [f (under "read-then-close.clj")]
  (spit f "(ns dep)")
  (check "#1117 read over a PushbackReader(FileReader)"
         (with-open [r (java.io.PushbackReader. (java.io.FileReader. f))] (read r false nil))
         '(ns dep))
  (fs/delete f)
  (check "#1117 ...and the file is released on close" (gone? f) true))
(let [f (under "read-io-reader.clj")]
  (spit f "(ns dep)")
  (with-open [r (java.io.PushbackReader. (io/reader f))] (read r false nil))
  (fs/delete f)
  (check "#1117 read over a PushbackReader(io/reader) releases the file" (gone? f) true))

;; --- #1118: file: URLs -----------------------------------------------------------
(let [d (under "has space")
      f (str d "/x.txt")
      abs (str (fs/absolutize f))
      slashed (str/replace abs "\\" "/")
      url-path (if windows? (str "/" slashed) slashed)]
  (fs/create-dirs d)
  (spit f "payload")
  (check "#1118 File.toURI is the JDK's spelling"
         (str (.toURI (io/file abs)))
         (str "file:" (str/replace url-path " " "%20")))
  (check "#1118 toURI -> toURL round trip opens"
         (with-open [is (io/input-stream (.toURL (.toURI (io/file abs))))] (slurp is))
         "payload")
  (check "#1118 io/as-url opens" (slurp (io/as-url (io/file abs))) "payload")
  (check "#1118 file:/… opens" (slurp (java.net.URL. (str "file:" url-path))) "payload")
  (check "#1118 file:///… opens" (slurp (java.net.URL. (str "file://" url-path))) "payload")
  (check "#1118 a file: string opens" (slurp (str "file:" url-path)) "payload")
  ;; the same FILE: its spelling may differ from abs's, whose separators are
  ;; whatever TEMP held (the #1110 rendering question), so ask canonically
  (check "#1118 io/as-file of the URL is the file"
         (.getCanonicalPath (io/as-file (.toURL (.toURI (io/file abs)))))
         (.getCanonicalPath (io/file abs))))
(let [jar (under "has space" "r.jar")
      jar-path (str/replace (str (fs/absolutize jar)) "\\" "/")]
  (with-open [zo (java.util.zip.ZipOutputStream. (io/output-stream jar))]
    (.putNextEntry zo (java.util.zip.ZipEntry. "data.txt"))
    (.write zo (.getBytes "in-jar"))
    (.closeEntry zo))
  (check "#1118 jar:file: over toURI opens"
         (slurp (java.net.URL. (str "jar:" (.toURI (io/file jar-path)) "!/data.txt")))
         "in-jar"))

;; --- #1119: last-modified time ---------------------------------------------------
(let [d (under "lock")
      now (System/currentTimeMillis)]
  (fs/create-dirs d)
  (fs/set-last-modified-time d (- now 60000))
  (check "#1119 a directory back-dated with a number"
         (- now (fs/file-time->millis (fs/last-modified-time d)))
         60000)
  (fs/set-last-modified-time d (java.time.Instant/ofEpochMilli (- now 120000)))
  (check "#1119 ...and with an Instant"
         (- now (fs/file-time->millis (fs/last-modified-time d)))
         120000)
  (check "#1119 last-modified-time is a FileTime"
         (instance? java.nio.file.attribute.FileTime (fs/last-modified-time d))
         true))
(let [f (under "file.txt")]
  (spit f "x")
  (fs/set-last-modified-time f 1500000000456)
  (check "#1119 a file, to the millisecond"
         (fs/file-time->millis (fs/last-modified-time f))
         1500000000456))

;; --- POSIX permissions follow the filesystem provider ----------------------------
;; The JDK's Windows provider has no POSIX view: get and set both raise. The shim
;; answered rwxr-xr-x and ignored the set, so a read-only check always passed.
(let [f (under "perms.txt")]
  (spit f "x")
  (check "POSIX permissions: set"
         (try (fs/set-posix-file-permissions f "r--r--r--") :set
              (catch UnsupportedOperationException _ :unsupported))
         (if windows? :unsupported :set))
  (check "POSIX permissions: get"
         (try (fs/posix->str (fs/posix-file-permissions f))
              (catch UnsupportedOperationException _ :unsupported))
         (if windows? :unsupported "r--r--r--"))
  (when-not windows? (fs/set-posix-file-permissions f "rw-r--r--")))

;; --- the tree the loader and the checks above used deletes cleanly -------------
(let [src (under "src")]
  (fs/create-dirs src)
  (spit (str src "/parity_dep.clj") "(ns parity-dep) (def x 1)")
  (require '[jolt.loader :as jl])
  ((resolve 'jl/load) ((resolve 'jl/classpath) [src]) {:kind :ns :name "parity-dep"})
  (check "#1117 a loaded source tree deletes" (do (fs/delete-tree src) (gone? src)) true))
(check "the whole scratch tree deletes" (do (fs/delete-tree root) (gone? root)) true)

(println (format "parity smoke: %d/%d passed" (- @total @fails) @total))
(System/exit (if (pos? @fails) 1 0))
