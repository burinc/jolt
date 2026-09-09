;; pagecache.clj — page-cache control for the cold-start benchmark
;; (bench/startup.sh COLD=1). Two things the shell cannot do on its own:
;;
;;   evict <file>     drop the file's pages from the page cache, so the next run
;;                    of it reads from storage. Linux: posix_fadvise(DONTNEED),
;;                    which drops every clean page. macOS has no posix_fadvise;
;;                    there the file is mapped and msync(MS_INVALIDATE) asks for
;;                    its cached pages back, which the kernel honours only in
;;                    part (measured: 14.3MB of a 23MB binary resident before,
;;                    12.3MB after) — so on macOS read the `resident` number
;;                    startup.sh prints beside each cold rep, not the word
;;                    "cold". No root, no /proc/sys/vm/drop_caches, and only
;;                    this one file rather than the whole machine's cache.
;;   resident <file>  how much of the file is in the page cache right now, via
;;                    mincore(2): "<resident-bytes> <file-bytes>". Run it after a
;;                    cold invocation and the first number is what that
;;                    invocation actually had to read.
;;
;; Both are best effort: a failure prints to stderr and exits non-zero, and the
;; caller decides whether that is fatal. Pages are the machine's own size
;; (getpagesize: 4K on x86_64 Linux, 16K on Apple Silicon), not a constant.
;;
;;   jolt run bench/pagecache.clj evict target/release/jolt
;;   jolt run bench/pagecache.clj resident target/release/jolt
(require '[jolt.ffi :as ffi])

(ffi/defcfn c-open "open" [:string :int] :int)
(ffi/defcfn c-close "close" [:int] :int)
(ffi/defcfn c-getpagesize "getpagesize" [] :int)
(ffi/defcfn c-mmap "mmap" [:pointer :size_t :int :int :int :long] :pointer)
(ffi/defcfn c-munmap "munmap" [:pointer :size_t] :int)
(ffi/defcfn c-mincore "mincore" [:pointer :size_t :pointer] :int)
(ffi/defcfn c-msync "msync" [:pointer :size_t :int] :int)

(def ^:private O_RDONLY 0)
(def ^:private PROT_READ 1)
(def ^:private MAP_SHARED 1)
(def ^:private MS_INVALIDATE 2)              ; the same value on Linux and macOS
(def ^:private POSIX_FADV_DONTNEED 4)        ; Linux

(defn- fail [what]
  (throw (ex-info (str what ": " (ffi/errno-message)) {})))

(defn- linux? [] (= "Linux" (System/getProperty "os.name")))

;; map the whole file read-only and hand the mapping to f
(defn- with-mapping [path f]
  (let [size (.length (java.io.File. path))
        fd (c-open path O_RDONLY)]
    (when (neg? fd) (fail "open"))
    (try
      (let [addr (c-mmap ffi/null size PROT_READ MAP_SHARED fd 0)]
        (when (or (nil? addr) (= -1 (ffi/address addr)) (= (dec (bit-shift-left 1 64)) (ffi/address addr)))
          (fail "mmap"))
        (try (f addr size)
             (finally (c-munmap addr size))))
      (finally (c-close fd)))))

(defn evict [path]
  (if (linux?)
    (let [fadvise (ffi/cfn "posix_fadvise" [:int :long :long :int] :int)
          fd (c-open path O_RDONLY)]
      (when (neg? fd) (fail "open"))
      (try
        ;; length 0 means "to end of file"; fadvise answers the errno itself
        (let [r (fadvise fd 0 0 POSIX_FADV_DONTNEED)]
          (when-not (zero? r) (throw (ex-info (str "posix_fadvise: " (ffi/errno-message r)) {}))))
        (finally (c-close fd))))
    (with-mapping path
      (fn [addr size]
        (when-not (zero? (c-msync addr size MS_INVALIDATE)) (fail "msync"))))))

(defn resident [path]
  (with-mapping path
    (fn [addr size]
      (let [page (c-getpagesize)
            pages (quot (+ size (dec page)) page)]
        (ffi/with-arena [a]
          (let [vec (ffi/alloc a pages)]
            (when-not (zero? (c-mincore addr size vec)) (fail "mincore"))
            ;; bit 0 of each byte is "this page is resident"
            (let [in (reduce (fn [n b] (if (odd? (bit-and b 1)) (inc n) n))
                             0 (ffi/read-array vec pages))]
              [(min size (* in page)) size])))))))

(defn -main [& [cmd path & more]]
  (if (or (nil? cmd) (nil? path) (seq more) (not (#{"evict" "resident"} cmd)))
    (do (binding [*out* *err*] (println "usage: pagecache.clj evict|resident FILE"))
        (System/exit 2))
    (try
      (case cmd
        "evict" (evict path)
        "resident" (let [[got total] (resident path)] (println got total)))
      (System/exit 0)
      (catch Exception e
        (binding [*out* *err*] (println (str "pagecache.clj: " cmd ": " (.getMessage e))))
        (System/exit 1)))))

(apply -main *command-line-args*)
