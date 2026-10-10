;; footprint-chunks.ss — after a full collection, report the memory chunks Chez
;; holds that are oversize (one allocation's own chunk, over the 129-segment
;; standard) yet under a quarter used. Such a chunk is pinned: Chez frees an
;; oversize chunk the moment it empties (gc.c), so one that stays near-empty is
;; held by a segment that cannot move. Prints one line:
;;   PINNED <chunks> <bytes> HELD <current-memory-bytes> LIVE <bytes-allocated>
;; Loaded into a running jolt with the report path bound as footprint-report,
;; after a System/gc (a bare (collect) here refuses whenever another jolt thread
;; is active, which on Linux it is at startup).
((foreign-procedure "(cs)s_showalloc" (boolean string) void) #f footprint-report)
(let ((p (open-input-file footprint-report)))
  (let loop ((n 0) (bytes 0))
    (let ((l (get-line p)))
      (if (eof-object? l)
          (begin
            (close-port p)
            (printf "PINNED ~a ~a HELD ~a LIVE ~a\n" n bytes
                    (current-memory-bytes) (bytes-allocated)))
          ;; a chunk row: 0xADDR 0xBYTES (+ 0xHDR bytes @ 0xADDR) USED of SEGS
          (let* ((ip (open-input-string l)) (addr (read ip)))
            (if (and (symbol? addr)
                     (let ((s (symbol->string addr)))
                       (and (> (string-length s) 2) (string=? (substring s 0 2) "0x"))))
                (let* ((sz (let ((s (symbol->string (read ip))))
                             (string->number (substring s 2 (string-length s)) 16)))
                       (hdr (read ip)) (used (read ip)) (of (read ip)) (segs (read ip)))
                  (if (and (> segs 129) (< (* used 4) segs))
                      (loop (+ n 1) (+ bytes sz))
                      (loop n bytes)))
                (loop n bytes)))))))
