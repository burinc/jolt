;; zip-file.ss — java.util.zip.ZipFile (JDK 21 ZipFile.java), and the central
;; directory index it and the loader's jar roots share.
;;
;; A zipdir is one archive's central directory, read once: every entry's name,
;; method, sizes, CRC, times, extra field, comment and local-header offset,
;; keyed by name. An entry's bytes are read on demand from a fresh port on the
;; file, positioned at the local header, so two readers of one archive share
;; nothing but the index; the index itself is immutable once built. The loader
;; keeps one zipdir per jar on its roots (zipdir-for), re-read when the file's
;; modification time changes, and answers a require or an io/resource out of it
;; without extracting the jar (jolt issue #1005). ZipFile is the class over the
;; same index.
;;
;; Reading follows JDK 21 Source.initCEN and checkAndAddEntry: the END record is
;; found by scanning the last 64 KiB + 22 bytes, its Zip64 locator is honoured,
;; every CEN header is checked, and each refusal is the JDK's ZipException
;; message. The local header is read when an entry is opened, as the JDK reads
;; it then, because its name and extra lengths — not the central directory's —
;; say where the data starts.

;; --- constants (JDK 21 ZipConstants.java, ZipConstants64.java) ----------------
(define zip-censig #x02014b50)
(define zip-endsig #x06054b50)
(define zip64-endsig #x06064b50)
(define zip64-locsig #x07064b50)
(define zip-cenhdr 46)
(define zip-endhdr 22)
(define zip64-endhdr 56)
(define zip64-lochdr 20)
(define zip-end-maxlen (+ #xFFFF zip-endhdr))
(define zip64-magiccount #xFFFF)
(define zip-open-read 1)
(define zip-open-delete 4)

;; --- the central directory --------------------------------------------------
(define-record-type zipdir
  (fields path      ; the archive's path, as opened
          comment   ; the archive comment (string), or #f
          table     ; name -> zdirent
          order)    ; vector of zdirent, in central-directory order
  (nongenerative jolt-zipdir-v1))

(define-record-type zdirent
  (fields name method flag crc csize size xdostime extra comment loc-offset)
  (nongenerative jolt-zdirent-v1))

(define (zipdir-size d) (vector-length (zipdir-order d)))

;; The entry named NAME, or, when NAME does not end in "/", the directory entry
;; NAME + "/" — ZipFile.getEntry's lookup (ZipFile.java getEntryPos). #f when
;; neither is there.
(define (zipdir-lookup d name)
  (or (hashtable-ref (zipdir-table d) name #f)
      (let ((n (string-length name)))
        (and (or (fx= n 0) (not (char=? (string-ref name (fx- n 1)) #\/)))
             (hashtable-ref (zipdir-table d) (string-append name "/") #f)))))

(define (zipdir-has? d name) (and (hashtable-ref (zipdir-table d) name #f) #t))

;; Every entry name, in central-directory order.
(define (zipdir-names d)
  (map zdirent-name (vector->list (zipdir-order d))))

(define (zip-zerror msg) (zip-throw "java.util.zip.ZipException" msg))

;; The bytes of the file at PATH from POS, N of them, or #f when the file is
;; shorter than that.
(define (zip-file-bytes in size pos n)
  (and (>= pos 0) (>= n 0) (<= (+ pos n) size)
       (begin
         (set-port-position! in pos)
         (let ((bv (get-bytevector-n in n)))
           (and (bytevector? bv) (= (bytevector-length bv) n) bv)))))

(define (zip-u16 bv i) (bytevector-u16-ref bv i (endianness little)))
(define (zip-u32 bv i) (bytevector-u32-ref bv i (endianness little)))
(define (zip-u64 bv i) (bytevector-u64-ref bv i (endianness little)))

;; The Zip64 extended information (tag 0x0001) of a CEN extra field, as
;; (values size csize loc-offset) with a #f for each field the block does not
;; carry; only the fields whose CEN value is 0xFFFFFFFF are in the block, in
;; that order (APPNOTE 4.5.3; ZipFile.java checkExtraFields).
(define (zip64-extra-fields extra size csize off)
  (let ((len (bytevector-length extra)))
    (let loop ((i 0))
      (if (> (+ i 4) len)
          (values #f #f #f)
          (let ((tag (zip-u16 extra i))
                (sz (zip-u16 extra (+ i 2))))
            (cond
              ((> (+ i 4 sz) len) (values #f #f #f))
              ((= tag #x0001)
               (let* ((at (+ i 4))
                      (end (+ at sz))
                      (take (lambda (need pos)
                              (if (and need (<= (+ pos 8) end))
                                  (values (zip-u64 extra pos) (+ pos 8))
                                  (values #f pos)))))
                 (let*-values (((s pos) (take (= size #xFFFFFFFF) at))
                               ((c pos) (take (= csize #xFFFFFFFF) pos))
                               ((o pos) (take (= off #xFFFFFFFF) pos)))
                   (values s c o))))
              (else (loop (+ i 4 sz)))))))))

;; The END record as (endpos cenlen cenoff total comment-bytes), with the Zip64
;; END record's values when the locator points at one. #f when the file holds
;; no END record (ZipFile.java findEND, initCEN lines 1483-1527).
(define (zipdir-find-end in size)
  (let* ((n (min size zip-end-maxlen))
         (tail (zip-file-bytes in size (- size n) n)))
    (and tail
         (let loop ((i (- n zip-endhdr)))
           (and (>= i 0)
                (if (and (= (zip-u32 tail i) zip-endsig)
                         (= (+ i zip-endhdr (zip-u16 tail (+ i 20))) n))
                    (let* ((endpos (+ (- size n) i))
                           (comlen (zip-u16 tail (+ i 20)))
                           (comment (let ((c (make-bytevector comlen)))
                                      (bytevector-copy! tail (+ i zip-endhdr) c 0 comlen)
                                      c))
                           (total (zip-u16 tail (+ i 10)))
                           (cenlen (zip-u32 tail (+ i 12)))
                           (cenoff (zip-u32 tail (+ i 16))))
                      ;; a Zip64 END record is consulted when the locator is
                      ;; there and its record answers (ZipFile.java lines
                      ;; 1443-1477): a sentinel field, or any field, comes
                      ;; from it then
                      (let ((loc (and (>= endpos zip64-lochdr)
                                      (zip-file-bytes in size (- endpos zip64-lochdr) zip64-lochdr))))
                        (if (and loc (= (zip-u32 loc 0) zip64-locsig))
                            (let* ((end64pos (zip-u64 loc 8))
                                   (end64 (zip-file-bytes in size end64pos zip64-endhdr)))
                              (if (and end64 (= (zip-u32 end64 0) zip64-endsig))
                                  (list endpos (zip-u64 end64 40) (zip-u64 end64 48)
                                        (zip-u64 end64 32) comment)
                                  (list endpos cenlen cenoff total comment)))
                            (list endpos cenlen cenoff total comment))))
                    (loop (- i 1))))))))

;; Read the central directory of the archive at PATH. CODER is the charset's
;; canonical name in lower case for names and comments, or #f for UTF-8; an
;; entry flagged UTF-8 (bit 11) decodes as UTF-8 whatever the coder, as JDK 21's
;; ZipCoder does. Every refusal is the JDK's: a directory or missing file the
;; open reports, an empty file, a file with no END record, and each CEN
;; inconsistency initCEN and checkAndAddEntry check.
(define (zipdir-read path coder . rest)
  (define name (and (pair? rest) (car rest)))
  (let ((in (guard (e (#t (zip-throw "java.nio.file.NoSuchFileException" (or name path))))
              (open-file-input-port path))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ((size (port-length in)))
          (when (= size 0) (zip-zerror "zip file is empty"))
          (let-values (((endpos cenlen cenoff total comment)
                        (apply values (or (zipdir-find-end in size)
                                          (zip-zerror "zip END header not found")))))
            (when (> (+ cenoff cenlen) endpos)
              (zip-zerror "invalid END header (bad central directory size)"))
            (when (> cenlen (- endpos cenoff))
              (zip-zerror "invalid END header (bad central directory offset)"))
            (let ((cen (zip-file-bytes in size cenoff cenlen)))
              (unless cen (zip-zerror "invalid END header (bad central directory offset)"))
              (let ((table (make-hashtable string-hash string=?))
                    (decode (lambda (bv flag)
                              (if (or (not coder) (not (zero? (bitwise-and flag zip-use-utf8))))
                                  (zip-decode-utf8 bv)
                                  (zip-decode-charset bv coder)))))
                (let loop ((pos 0) (acc '()) (count 0))
                  (cond
                    ((>= pos cenlen)
                     (unless (= pos cenlen) (zip-zerror "invalid CEN header (bad header size)"))
                     (unless (= count total) (zip-zerror "invalid END header (bad central directory size)"))
                     (make-zipdir path
                                  (and (> (bytevector-length comment) 0)
                                       (decode comment 0))
                                  table
                                  (list->vector (reverse acc))))
                    (else
                     (when (> (+ pos zip-cenhdr) cenlen)
                       (zip-zerror "invalid CEN header (bad header size)"))
                     (unless (= (zip-u32 cen pos) zip-censig)
                       (zip-zerror "invalid CEN header (bad signature)"))
                     (let* ((flag (zip-u16 cen (+ pos 8)))
                            (method (zip-u16 cen (+ pos 10)))
                            (xdostime (zip-u32 cen (+ pos 12)))
                            (crc (zip-u32 cen (+ pos 16)))
                            (csize (zip-u32 cen (+ pos 20)))
                            (size (zip-u32 cen (+ pos 24)))
                            (nlen (zip-u16 cen (+ pos 28)))
                            (elen (zip-u16 cen (+ pos 30)))
                            (clen (zip-u16 cen (+ pos 32)))
                            (off (zip-u32 cen (+ pos 42)))
                            (hlen (+ zip-cenhdr nlen elen clen)))
                       (when (not (zero? (bitwise-and flag 1)))
                         (zip-zerror "invalid CEN header (encrypted entry)"))
                       (unless (or (= method zip-stored) (= method zip-deflated))
                         (zip-zerror (string-append "invalid CEN header (bad compression method: "
                                                    (number->string method) ")")))
                       (when (> (+ pos hlen) cenlen)
                         (zip-zerror "invalid CEN header (bad header size)"))
                       (let* ((name-bv (let ((b (make-bytevector nlen)))
                                         (bytevector-copy! cen (+ pos zip-cenhdr) b 0 nlen) b))
                              (extra (and (> elen 0)
                                          (let ((b (make-bytevector elen)))
                                            (bytevector-copy! cen (+ pos zip-cenhdr nlen) b 0 elen) b)))
                              (comment-bv (and (> clen 0)
                                               (let ((b (make-bytevector clen)))
                                                 (bytevector-copy! cen (+ pos zip-cenhdr nlen elen) b 0 clen) b)))
                              (name (decode name-bv flag)))
                         (let-values (((size64 csize64 off64)
                                       (if extra (zip64-extra-fields extra size csize off) (values #f #f #f))))
                           (let ((ent (make-zdirent name method flag crc
                                                    (or csize64 csize) (or size64 size)
                                                    xdostime extra
                                                    (and comment-bv (decode comment-bv flag))
                                                    (or off64 off))))
                             (when (> (+ (zdirent-loc-offset ent) zip-lochdr) cenoff)
                               (zip-zerror "invalid CEN header (bad header size)"))
                             ;; a name that appears twice keeps the first (a
                             ;; hashtable-ref finds it); every one is enumerated
                             (unless (hashtable-ref table name #f)
                               (hashtable-set! table name ent))
                             (loop (+ pos hlen) (cons ent acc) (+ count 1))))))))))))))
      (lambda () (close-port in)))))

;; Where ENT's data starts in the file, from its local header (ZipFile.java
;; initDataOffset): the header's own name and extra lengths, which may differ
;; from the central directory's.
(define (zipdir-data-offset in size ent)
  (let ((loc (zip-file-bytes in size (zdirent-loc-offset ent) zip-lochdr)))
    (unless (and loc (= (zip-u32 loc 0) zip-locsig))
      (zip-zerror "ZipFile invalid LOC header (bad signature)"))
    (+ (zdirent-loc-offset ent) zip-lochdr (zip-u16 loc 26) (zip-u16 loc 28))))

;; A binary input port over the N bytes of PATH from OFFSET, on its own file
;; port; closing it closes the file. A file that ends early ends the port.
(define (zip-slice-port path offset n)
  (let ((in (open-file-input-port path))
        (remaining n))
    (set-port-position! in offset)
    (make-custom-binary-input-port
     "zip-entry"
     (lambda (bv start count)
       (if (<= remaining 0)
           0
           (let ((got (get-bytevector-some! in bv start (min count remaining))))
             (if (eof-object? got)
                 0
                 (begin (set! remaining (- remaining got)) got)))))
     #f #f
     (lambda () (close-port in)))))

;; The compressed bytes of ENT, from a file port opened for the call.
(define (zipdir-raw-bytes d ent)
  (let ((in (open-file-input-port (zipdir-path d))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let* ((size (port-length in))
               (off (zipdir-data-offset in size ent))
               (bv (zip-file-bytes in size off (zdirent-csize ent))))
          (or bv (zip-zerror "ZipFile invalid LOC header (bad signature)"))))
      (lambda () (close-port in)))))

;; Raw-deflate BV inflated, expecting SIZE bytes: one zlib stream, fed a window
;; at a time. A stream that ends early or late is the JDK's ZipException.
(define (zip-inflate-raw bv size)
  (let-values (((zs code msg) (zstream-open 'inflate -15 0 0)))
    (unless zs (zip-throw "java.lang.InternalError" (or msg "inflateInit2 failed")))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ((out (make-bytevector size))
              (len (bytevector-length bv)))
          (let loop ((pos 0) (written 0))
            (let* ((n (min zip-input-window (- len pos)))
                   (in (let ((w (make-bytevector n))) (bytevector-copy! bv pos w 0 n) w)))
              (let-values (((code consumed produced bytes)
                            (zstream-step! zs z-no-flush in (- size written))))
                (cond
                  ((or (= code z-ok) (= code z-stream-end) (= code z-buf-error))
                   (bytevector-copy! bytes 0 out written produced)
                   (let ((written (+ written produced))
                         (pos (+ pos consumed)))
                     (cond
                       ((= code z-stream-end)
                        (unless (= written size)
                          (zip-zerror (string-append "invalid entry size (expected "
                                                     (number->string size) " but got "
                                                     (number->string written) " bytes)")))
                        out)
                       ((and (= pos len) (= produced 0))
                        (zip-throw "java.io.EOFException" "Unexpected end of ZLIB input stream"))
                       ((and (= written size) (< pos len))
                        ;; the JDK's inflater stream stops reading at size;
                        ;; the rest of the compressed bytes are not looked at
                        out)
                       (else (loop pos written)))))
                  ((= code z-data-error)
                   (zip-zerror (or (zstream-message zs) "invalid stored block lengths")))
                  (else (zip-throw "java.lang.InternalError" (zstream-message zs)))))))))
      (lambda () (zstream-close! zs)))))

;; The uncompressed bytes of the entry ENT of D, whole.
(define (zipdir-entry-bytes d ent)
  (let ((raw (zipdir-raw-bytes d ent)))
    (cond
      ((= (zdirent-method ent) zip-stored) raw)
      ((= (zdirent-method ent) zip-deflated) (zip-inflate-raw raw (zdirent-size ent)))
      (else (zip-zerror "invalid compression method")))))

;; The entry's bytes as a UTF-8 string.
(define (zipdir-entry-string d ent)
  (utf8->string (zipdir-entry-bytes d ent)))

;; An InputStream over ENT's uncompressed bytes, as ZipFile.getInputStream
;; answers: a stored entry's reads its slice of the file (ZipFile.java
;; ZipFileInputStream), a deflated entry's is an InflaterInputStream over that
;; slice with a raw Inflater (ZipFileInflaterInputStream). Both are jolt's
;; in-stream on the zip-in-streams.ss frame, and available() answers the
;; uncompressed bytes not yet read, as both of the JDK's do.
(define zip-int-max 2147483647)
(define (zipdir-entry-stream d ent)
  (let ((in (open-file-input-port (zipdir-path d))))
    (let ((off (dynamic-wind
                 (lambda () #f)
                 (lambda () (zipdir-data-offset in (port-length in) ent))
                 (lambda () (close-port in)))))
      (let ((slice (zip-slice-port (zipdir-path d) off (zdirent-csize ent)))
            (size (zdirent-size ent)))
        (cond
          ((= (zdirent-method ent) zip-stored)
           (let ((remaining size))
             (make-zin-stream
              (make-zin "java.util.zip.ZipFile$ZipFileInputStream" (make-in-stream slice) #f #f
                        (na-byte-array 0) 0 #f
                        (lambda (z bv start count)
                          (let ((n (get-bytevector-some! slice bv start count)))
                            (if (eof-object? n)
                                (begin (zin-reach-eof-set! z #t) 0)
                                (begin (set! remaining (- remaining n)) n))))
                        (lambda (z) (min remaining zip-int-max))
                        (lambda (z) (close-port slice))
                        #f))))
          ((= (zdirent-method ent) zip-deflated)
           (let ((inf (make-inflater #t)))
             (make-zin-stream
              (make-zin "java.util.zip.ZipFile$ZipFileInflaterInputStream" (make-in-stream slice) inf #t
                        (na-byte-array 8192) 0 #f
                        zin-inflate-read
                        (lambda (z) (min (max 0 (- size (inflater-bytes-written inf))) zip-int-max))
                        zin-inflate-close #f))))
          (else (close-port slice) (zip-zerror "invalid compression method")))))))

;; --- the index the loader shares ---------------------------------------------
;; One zipdir per archive path, keyed by the file's modification time: a jar
;; re-fetched at the same path is read again. A path that is not a readable
;; archive answers #f, and is not remembered, so it is asked again — the
;; archive may be finished by then. The table is read under its lock; a build
;; runs outside it, so two threads may read one archive at once and the second
;; store wins, which is harmless: the two are equal.
(define zipdir-cache (make-hashtable string-hash string=?))
(define zipdir-cache-mu (make-mutex))
(define (zipdir-for path)
  (let ((stamp (guard (e (#t #f)) (sa-file-mtime-ms path))))
    (and stamp
         (let ((hit (jolt-with-mutex zipdir-cache-mu (hashtable-ref zipdir-cache path #f))))
           (if (and hit (eqv? (car hit) stamp))
               (cdr hit)
               (let ((d (guard (e (#t #f)) (zipdir-read path #f))))
                 (when d
                   (jolt-with-mutex zipdir-cache-mu
                     (hashtable-set! zipdir-cache path (cons stamp d))))
                 d))))))

;; --- java.util.zip.ZipFile --------------------------------------------------
;; state #(zipdir name closed? streams): STREAMS holds the in-streams opened
;; through getInputStream, which close() closes, as the JDK closes them.
(define (zip-file? x) (and (jhost? x) (string=? (jhost-tag x) "zip-file")))
(define (zfile-dir self) (vector-ref (jhost-state self) 0))
(define (zfile-name self) (vector-ref (jhost-state self) 1))
(define (zfile-closed? self) (vector-ref (jhost-state self) 2))

(define (zfile-ensure-open self)
  (when (zfile-closed? self)
    (zip-throw "java.lang.IllegalStateException" "zip file closed")))

;; The ZipEntry for a directory record: every field the JDK's getZipEntry sets.
(define (zdirent->entry ent)
  (let ((e (make-zip-entry-named (zdirent-name ent))))
    (let ((z (zentry-of e)))
      (zentry-method-set! z (zdirent-method ent))
      (zentry-xdostime-set! z (zdirent-xdostime ent))
      (zentry-crc-set! z (zdirent-crc ent))
      (zentry-csize-set! z (zdirent-csize ent))
      (zentry-size-set! z (zdirent-size ent))
      (when (zdirent-extra ent) (zentry-extra-set! z (na-byte-array (bytevector-copy (zdirent-extra ent)))))
      (when (zdirent-comment ent) (zentry-comment-set! z (zdirent-comment ent))))
    e))

;; ZipFile(String) | ZipFile(File) | ZipFile(File, int) | ZipFile(String, Charset)
;; | ZipFile(File, Charset) | ZipFile(File, int, Charset), resolved as the
;; compiled call resolves them (ZipFile.java lines 165-268). The mode must be
;; OPEN_READ, with or without OPEN_DELETE; the charset null check has the JDK's
;; message. A File or a String names the archive; the name kept is the path as
;; given, which getName answers.
(define (make-zip-file . args)
  (define (no-ctor)
    (throw-jvm 'IllegalArgumentException "No matching ctor found for class java.util.zip.ZipFile"))
  (define (file-arg x)
    (cond ((jolt-nil? x) (zip-throw "java.lang.NullPointerException" #f))
          ((string? x) x)
          ((jfile? x) (jfile-path x))
          (else (no-ctor))))
  (define (mode-arg x)
    (let ((m (zip-int-arg x)))
      (unless (or (= m zip-open-read) (= m (bitwise-ior zip-open-read zip-open-delete)))
        (zip-throw "java.lang.IllegalArgumentException"
                   (string-append "Illegal mode: 0x" (number->string m 16))))
      m))
  (define (charset-arg x)
    (cond ((jolt-nil? x) (zip-throw "java.lang.NullPointerException" "charset"))
          ((zip-charset? x)
           (let ((name (charset-canonical-down (charset-arg-name x))))
             (and (not (string=? name "utf-8")) name)))
          (else (zip-class-cast x "java.nio.charset.Charset"))))
  (let-values (((name coder)
                (case (length args)
                  ((1) (values (file-arg (car args)) #f))
                  ((2) (let ((a (car args)) (b (cadr args)))
                         (cond ((zip-long? b) (mode-arg b) (values (file-arg a) #f))
                               (else (values (file-arg a) (charset-arg b))))))
                  ((3) (mode-arg (cadr args))
                       (values (file-arg (car args)) (charset-arg (caddr args))))
                  (else (no-ctor)))))
    (let* ((path (jfile-fs name))
           (dir (if (and (file-exists? path) (file-directory? path))
                    (zip-throw "java.io.FileNotFoundException"
                               (string-append name " (Is a directory)"))
                    (zipdir-read path coder name))))
      (make-jhost "zip-file" (vector dir name #f '())))))

(define (zfile-entry-arg self who x)
  (cond ((jolt-nil? x) (zip-throw "java.lang.NullPointerException" who))
        ((string? x) x)
        (else (zip-class-cast x "java.lang.String"))))

(define (zfile-get-entry self name)
  (let ((name (zfile-entry-arg self "name" name)))
    (zfile-ensure-open self)
    (let ((ent (zipdir-lookup (zfile-dir self) name)))
      (if ent (zdirent->entry ent) jolt-nil))))

;; getInputStream(ZipEntry): null for a name the archive does not hold; the
;; stream is remembered so close() closes it.
(define (zfile-get-input-stream self entry)
  (when (jolt-nil? entry) (zip-throw "java.lang.NullPointerException" "entry"))
  (unless (zip-entry? entry) (zip-class-cast entry "java.util.zip.ZipEntry"))
  (zfile-ensure-open self)
  (let ((ent (zipdir-lookup (zfile-dir self) (zentry-name (zentry-of entry)))))
    (if (not ent)
        jolt-nil
        (let ((s (zipdir-entry-stream (zfile-dir self) ent)))
          (vector-set! (jhost-state self) 3 (cons s (vector-ref (jhost-state self) 3)))
          s))))

(define (zfile-entries self)
  (zfile-ensure-open self)
  (list->cseq (map zdirent->entry (vector->list (zipdir-order (zfile-dir self))))))

(define (zfile-close self)
  (unless (zfile-closed? self)
    (vector-set! (jhost-state self) 2 #t)
    (for-each (lambda (s) (guard (e (#t #f)) (record-method-dispatch s "close" jolt-nil)))
              (vector-ref (jhost-state self) 3))
    (vector-set! (jhost-state self) 3 '()))
  jolt-nil)

(hashtable-set! jhost-tag->fqn "zip-file" "java.util.zip.ZipFile")
(register-host-methods! "zip-file"
  (list
   (cons "getEntry" (zip-method "getEntry" '(1) zfile-get-entry))
   (cons "getInputStream" (zip-method "getInputStream" '(1) zfile-get-input-stream))
   (cons "entries" (zip-method "entries" '(0) zfile-entries))
   (cons "stream" (zip-method "stream" '(0) zfile-entries))
   (cons "size" (zip-method "size" '(0)
                  (lambda (self) (zfile-ensure-open self) (->num (zipdir-size (zfile-dir self))))))
   (cons "getName" (zip-method "getName" '(0) zfile-name))
   (cons "getComment" (zip-method "getComment" '(0)
                        (lambda (self)
                          (zfile-ensure-open self)
                          (or (zipdir-comment (zfile-dir self)) jolt-nil))))
   (cons "close" (zip-method "close" '(0) zfile-close))))
(register-class-statics! "java.util.zip.ZipFile"
  (list (cons "OPEN_READ" (->num zip-open-read))
        (cons "OPEN_DELETE" (->num zip-open-delete))))
(reg-ctor! '("ZipFile" "java.util.zip.ZipFile") make-zip-file)
