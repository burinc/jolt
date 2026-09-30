;; build-natives-test.ss — the build driver's handling of :static natives and of
;; the directories it creates for them, below `jolt build`.
;;
;;   a. a bare JOLT_CHEZ (a name PATH finds, like "scheme") lives where PATH
;;      says. build.ss reads that directory while it loads, through path-parent,
;;      which answers #f for a bare name — and bld-exe-dir handed the #f to
;;      string=?, so loading build.ss at all raised.
;;   b. bld-mkdir-p creates a missing chain and treats #f (no parent: a root or a
;;      bare name) as the end of the walk rather than an argument
;;      (jolt-lang/jolt#1207; the Windows spellings are win-path-test.ss's rows).
;;
;;   chez --script test/chez/build-natives-test.ss
(import (chezscheme))
;; (a): set before build.ss loads, since that is when it reads the directory. "sh"
;; rather than "chez" because every runner has one on PATH.
(putenv "JOLT_CHEZ" "sh")
(putenv "JOLT_CHEZ_CSV" "")
(load "host/chez/gate-boot.ss")
(load "host/chez/cli-core.ss")
(load "host/chez/png.ss")
(load "host/chez/loader.ss")
(load "host/chez/java/ffi.ss")
(load "host/chez/build.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (if pred (printf "PASS: ~a\n" name)
      (begin (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name))))

(define work (string-append (host-temp-dir) "/jolt-natives-test-" (number->string (get-process-id))))
(define (sh cmd) (zero? (system cmd)))
(define (spit path s)
  (let ((p (open-output-file path 'replace))) (put-string p s) (close-port p)))

;; --- (a) ----------------------------------------------------------------------
(ok "(a) build.ss loads with a bare JOLT_CHEZ" (string? bld-host-csv-dir))
(ok "(a) a bare name's directory is where PATH finds it"
    (equal? (bld-exe-dir "sh") (bld-sh-capture "dirname \"$(command -v sh)\"")))
(ok "(a) a name with a directory keeps it" (equal? (bld-exe-dir "/usr/bin/sh") "/usr/bin"))

;; --- (b) ----------------------------------------------------------------------
(bld-mkdir-p (string-append work "/x/y/z.build"))
(ok "(b) bld-mkdir-p creates the whole chain" (file-directory? (string-append work "/x/y/z.build")))
(ok "(b) bld-mkdir-p ends at #f" (begin (bld-mkdir-p #f) #t))
(ok "(b) bld-mkdir-p leaves a bare existing name alone" (begin (bld-mkdir-p ".") #t))

(sh (string-append "rm -rf '" work "'"))
(printf "\nbuild natives: ~a passed, ~a failed\n" (- total fails) fails)
(when (> fails 0) (exit 1))
