;; The struct-stat layout resolution (jolt-lang/jolt#798). Run:
;;   chez --script test/chez/stat-layout-test.ss
;;
;; nio-file reads st_mode and st_uid at offsets that are a per-platform ABI, and
;; it used to pick them from the host's IDENTITY alone. A portable-bytecode
;; build has no identity to read — its machine tag names neither OS nor arch —
;; so every pb build fell through to "unverified struct stat layout" and refused
;; getPosixFilePermissions and getOwner, on hosts whose layout is one this file
;; has always known. Native aarch64 Linux refused for the same reason.
;;
;; The layout is measured now, so the interesting case is the one this host
;; cannot be: resolution with NO identity to go on. That is what the middle
;; block does — it runs the measurement alone and requires it to land on the row
;; identity would have proposed, which is exactly what a pb build depends on.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; ---- the host resolves a layout at all -------------------------------------
(define resolved (nio-stat-layout))
(ok "this host resolves a struct stat layout" (and resolved #t))
(ok (format "resolved layout is ~a" (and resolved (nio-layout-name resolved)))
    (memq (and resolved (nio-layout-name resolved)) '(darwin linux-x86-64 linux-arm64)))

;; ---- measurement alone, which is the pb case -------------------------------
;; No identity input: just a real stat and the candidate table.
(define probe-buf (nio-probe-root-stat))
(ok "a root stat is available to measure with" (and probe-buf #t))
(when probe-buf
  (let ((measured (nio-sole-verifying-layout probe-buf)))
    (ok "measurement alone identifies exactly one layout" (and measured #t))
    (ok "measurement alone agrees with what identity proposes here"
        (eq? measured (nio-proposed-stat-layout)))
    (ok "measurement alone agrees with what the host actually resolved"
        (eq? measured resolved))
    ;; The discrimination has to be sharp, not lucky: every OTHER row must fail.
    (for-each
      (lambda (l)
        (unless (eq? l measured)
          (ok (format "~a does not also verify here" (nio-layout-name l))
              (not (nio-layout-verifies? l probe-buf)))))
      nio-stat-layouts)))

;; ---- and the offsets it lands on actually read the file --------------------
;; A file whose mode we just set: the layout is right only if st_mode reads back
;; the mode we chose, which no offset that merely happens to carry S_IFDIR would.
(define tmp (string-append "/tmp/jolt-stat-layout-" (number->string (sa-real-time-ms))))
(when probe-buf
  (close-port (open-file-output-port tmp (file-options no-fail)))
  (guard (e (#t #f))
    (let ((chmod (jolt-foreign-proc-safe "chmod" '(string int) 'int)))
      (when chmod
        (chmod tmp #o640)
        (let ((mode (nio-stat-mode tmp)))
          (ok (format "st_mode of a 0640 file reads back 0640 (got ~a)"
                      (and mode (number->string (bitwise-and mode #o777) 8)))
              (and mode (= #o640 (bitwise-and mode #o777))))
          (ok "and its format bits say regular file, not directory"
              (and mode (= #x8000 (bitwise-and mode #xF000))))))))
  ;; st_uid of a file this process just created is this process's own uid.
  (let ((uid (nio-stat-uid tmp))
        (c-getuid (jolt-foreign-proc-safe "getuid" '() 'int)))
    (when c-getuid
      (ok (format "st_uid of a file we created is our own uid (~a)" uid)
          (and uid (= uid (c-getuid))))))
  (delete-file tmp))

(printf "stat-layout: ~a checks, ~a failures\n" total fails)
(when (> fails 0) (exit 1))
