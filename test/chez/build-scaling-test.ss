;; build-scaling-test.ss — what keeps `jolt build` from scaling badly with the
;; size of the app (jolt-lang/jolt#1059).
;;
;; Profiling a test-heavy app of 233 namespaces put 70% of a 120s build in Chez's
;; back end: compile-file over the app half (44s, 62% of it collecting) and the
;; vfasl conversion (40s, superlinear in the image). This gate pins the build-side
;; shapes those costs depend on:
;;
;;   a. the app's init bodies are split into SMALL procedures. Chez's passes over
;;      one lambda body grow faster than the body; 100 forms per procedure
;;      compiled the 28MB app half in 49.6s, 10 per procedure in 31.2s
;;   b. the back-end steps run under a larger collect trip, and restore it after
;;   c. a vfasl conversion that fails outright says so — the in-process path used
;;      to keep the plain boot silently, after spending the time
;;   d. the vfasl image is converted in pieces: the runtime prefix once (cached),
;;      the app per unit. The whole-boot conversion re-imaged ~40MB that never
;;      changes, and is superlinear in the image (40s for a 28MB app half)
;;
;;   chez --script test/chez/build-scaling-test.ss
(import (chezscheme))
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

(define tmp "target/build-scaling-gate")
(bld-mkdir-p tmp)
(define (at name) (string-append tmp "/" name))

(define (read-all-string s)
  (let ((ip (open-input-string s)))
    (let loop ((acc '()))
      (let ((f (read ip)))
        (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))

;; --- a: init procedures stay small -------------------------------------------
(define init-forms
  (read-all-string
    (with-output-to-string
      (lambda ()
        (bld-emit-app-init (current-output-port)
                           (let loop ((i 0) (acc '()))
                             (if (= i 95) acc
                                 (loop (+ i 1) (cons (format "(display ~a)" i) acc)))))))))
(define chunk-procs
  (filter (lambda (f) (and (pair? f) (eq? (car f) 'define) (pair? (cadr f))
                           (not (eq? (car (cadr f)) 'jolt-app-init!))))
          init-forms))
(ok "every app body lands in exactly one init procedure"
    (= 95 (apply + (map (lambda (f) (length (cddr f))) chunk-procs))))
(ok "no init procedure holds more than 10 app forms"
    (for-all (lambda (f) (<= (length (cddr f)) 10)) chunk-procs))
(ok "jolt-app-init! calls every chunk, in order"
    (let ((main (find (lambda (f) (and (pair? f) (eq? (car f) 'define) (pair? (cadr f))
                                       (eq? (car (cadr f)) 'jolt-app-init!)))
                      init-forms)))
      (equal? (map car (cddr main)) (map (lambda (f) (car (cadr f))) chunk-procs))))

;; --- b: the back end's collect trip -------------------------------------------
(define before (collect-trip-bytes))
(define inside (bld-with-backend-gc (lambda () (collect-trip-bytes))))
(ok "back-end steps run under a collect trip of at least 64MB"
    (>= inside (* 64 1024 1024)))
(ok "the collect trip is restored afterwards" (= before (collect-trip-bytes)))

;; --- c: a failed in-process conversion reports itself --------------------------
(define junk (at "junk.boot"))
(let ((p (open-file-output-port junk (file-options no-fail))))
  (put-bytevector p (u8-list->bytevector '(200 201 202 203)))
  (close-port p))
(define junk-out (at "junk.vfasl"))
(define junk-result 'unset)
(define note-text
  (with-output-to-string (lambda () (set! junk-result (bld-vfasl-convert! junk junk-out)))))
(ok "an unconvertible boot answers #f" (eq? junk-result #f))
(ok "…and prints the no-vfasl note"
    (let ((needle "could not be converted to a vfasl"))
      (let loop ((i 0))
        (cond ((> (+ i (string-length needle)) (string-length note-text)) #f)
              ((string=? needle (substring note-text i (+ i (string-length needle)))) #t)
              (else (loop (+ i 1)))))))

;; --- d: split vfasl conversion ------------------------------------------------
;; The prefix (Chez's boots + the runtime unit) converts once and is cached; each
;; app unit converts on its own; the image is their concatenation. What has to
;; hold is that the result BOOTS, and that the app unit's code shares the
;; runtime unit's objects — a record made by the runtime is an instance of the
;; type the app unit's code names, across two separately converted entries.
(define csv bld-host-csv-dir)
(define (write-text! path s)
  (let ((p (open-output-file path 'replace))) (put-string p s) (close-port p)))
(define rt-ss (at "rt-unit.ss")) (define rt-so (at "rt-unit.so"))
(define app-ss (at "app-unit.ss")) (define app-so (at "app-unit.so"))
(write-text! rt-ss
  (string-append
    "(define-record-type gate-point (nongenerative gate-point-v1) (fields x))\n"
    "(define rt-made (make-gate-point 41))\n"))
(write-text! app-ss
  "(define app-says (if (gate-point? rt-made) (+ 1 (gate-point-x rt-made)) 'not-a-point))\n")
(parameterize ((optimize-level 2)) (compile-file rt-ss rt-so) (compile-file app-ss app-so))
(define units (list (list rt-ss rt-so 'runtime) (list app-ss app-so 'app)))
(define base-boots (list (string-append csv "/petite.boot") (string-append csv "/scheme.boot")))
(define rt-key (at "rt-key.so"))
(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
          (list rt-key (string-append rt-key ".default.vfasl")))
(define vboot (at "split.boot"))
(ok "a split conversion produces an image"
    (and (bld-vfasl-split! tmp base-boots units rt-key #f vboot) (file-exists? vboot)))
(ok "the runtime prefix image is cached under the runtime's key"
    (file-exists? (string-append rt-key ".default.vfasl")))
(define probe (at "probe.ss"))
(write-text! probe "(display app-says)\n")
(define (boot-output boot)
  (let* ((p (process (string-append "'" bld-chez "' -b '" (current-directory) "/" boot "' --script '" probe "' 2>&1")))
         (in (car p)))
    (let loop ((acc '()))
      (let ((c (read-char in)))
        (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc)))))))
(ok "the split image boots, and app code sees the runtime's record as its own type"
    (string=? (boot-output vboot) "42"))
;; second build: the prefix comes from the cache (make its source unreadable to
;; prove nothing re-converts it)
(define vboot2 (at "split2.boot"))
(ok "a second build reuses the cached prefix"
    (and (bld-vfasl-split! tmp (list (at "no-such-petite.boot")) units rt-key #f vboot2)
         (string=? (boot-output vboot2) "42")))

(printf "\nbuild scaling gate: ~a/~a passed~a\n"
        (- total fails) total (if (= fails 0) "" (format " (~a failed)" fails)))
(exit (if (= fails 0) 0 1))
