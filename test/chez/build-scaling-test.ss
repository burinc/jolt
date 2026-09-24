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
;;   e. the app half is one compile unit per namespace, cached on its text; a
;;      miss compiles in a worker (in parallel, in a real build)
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

(define (substring? needle hay)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

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

;; --- e: one compile unit per namespace, cached on its text -------------------------
(define grouped (bld-group-app-strs '("a1" "a2" "b1" "c1" "c2" "c3") '(("a" . 2) ("b" . 1) ("c" . 3)) "entry"))
(ok "app strings regroup by namespace, in order"
    (equal? grouped '(("a" "a1" "a2") ("b" "b1") ("c" "c1" "c2" "c3"))))
(ok "a namespace that emitted nothing makes no unit"
    (equal? (bld-group-app-strs '("a1" "c1") '(("a" . 1) ("b" . 0) ("c" . 1)) "entry")
            '(("a" "a1") ("c" "c1"))))
(ok "strings the sizes do not account for (a shaken app) stay one unit"
    (equal? (bld-group-app-strs '("x" "y") '(("a" . 3)) "entry") '(("entry" "x" "y"))))
(ok "chunk procedures are named for their namespace, not their position"
    (let ((s (with-output-to-string
               (lambda () (bld-emit-app-chunks (current-output-port) (bld-unit-tag "my.ns-x/y?") '("(f)"))))))
      (and (substring? "jolt-app-init$my.ns-x_y_$0!" s))))
(ok "the unit key moves with the text"
    (not (string=? (bld-unit-key "release" "(define x 1)") (bld-unit-key "release" "(define x 2)"))))
(ok "…and with the compile parameters"
    (not (string=? (bld-unit-key "release" "(define x 1)") (bld-unit-key "optimized" "(define x 1)"))))
(ok "…and is stable for the same inputs"
    (string=? (bld-unit-key "release" "(define x 1)") (bld-unit-key "release" "(define x 1)")))

;; the cache: a miss compiles and stores, a hit copies without compiling
(define ucache (at "unit-cache"))
(when (file-exists? ucache)
  (for-each (lambda (f) (delete-file (string-append ucache "/" f))) (directory-list ucache)))
(putenv "JOLT_BUILD_CACHE_DIR" ucache)
(putenv "JOLT_BUILD_JOBS" "1")
(define u1-ss (at "u1.ss")) (define u2-ss (at "u2.ss"))
(write-text! u1-ss "(define gate-u1 1)\n")
(write-text! u2-ss "(define gate-u2 2)\n")
(define uunits (list (list u1-ss (at "u1.so") 'app) (list u2-ss (at "u2.so") 'app)))
(bld-compile-app-units! tmp "release" uunits #f)
(ok "a cold build compiles every unit and caches it"
    (and (file-exists? (at "u1.so")) (file-exists? (at "u2.so"))
         (= 2 (length (filter (lambda (f) (bld-suffix? f ".so")) (directory-list ucache))))))
(delete-file (at "u1.so")) (delete-file (at "u2.so"))
(define real-compile bld-chez-compile-file)
(define compiled-again 0)
(set! bld-chez-compile-file (lambda args (set! compiled-again (+ compiled-again 1)) (apply real-compile args)))
(bld-compile-app-units! tmp "release" uunits #f)
(ok "a warm build compiles nothing and still produces every unit"
    (and (= compiled-again 0) (file-exists? (at "u1.so")) (file-exists? (at "u2.so"))))
(write-text! u2-ss "(define gate-u2 3)\n")
(bld-compile-app-units! tmp "release" uunits #f)
(ok "changing one unit recompiles that unit only" (= compiled-again 1))
(set! bld-chez-compile-file real-compile)

;; an image an earlier build left in the build dir is never taken as this build's
(write-text! (at "u1.so.vfasl") "stale bytes from an earlier build")
(bld-compile-app-units! tmp "release" uunits #t)
(ok "a unit image left over from an earlier build is not reused"
    (and (bld-vfasl-unit! (at "u1.so") (at "u1.so.vfasl"))
         (not (string=? (read-file-string (at "u1.so.vfasl")) "stale bytes from an earlier build"))))

;; a worker manifest compiles its jobs
(define wm (at "jobs.edn"))
(let ((op (open-output-file wm 'replace)))
  (write (vector u1-ss (at "w1.so") (at "w1.so.vfasl") "release" 'default) op)
  (close-port op))
(bld-compile-worker wm)
(ok "a worker compiles and converts each job in its manifest"
    (and (file-exists? (at "w1.so")) (file-exists? (at "w1.so.vfasl"))))

(printf "\nbuild scaling gate: ~a/~a passed~a\n"
        (- total fails) total (if (= fails 0) "" (format " (~a failed)" fails)))
(exit (if (= fails 0) 0 1))
