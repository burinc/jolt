;; gen-boot.ss — write host/gambit/boot-<profile>.ss for a build profile.
;;
;; Run on CHEZ from the repo root (make gambitweb PROFILE=... does this):
;;   chez --script host/gambit/gen-boot.ss repl
;;
;; Gambit resolves ##include at expansion time, so which files a build carries
;; cannot be a runtime choice — the boot has to be generated. Same reasoning as
;; the seed and records-gambit.ss: derive it on Chez, check nothing by hand.
;;
;; boot.ss owns the load order; profiles.ss says which of its files are optional
;; and which profile keeps which groups. Excluded files are dropped from the
;; include list, and every clojure.core name they define is bound to a raise
;; naming the group — read out of the files themselves, so the error surface
;; cannot drift from the code.

(import (chezscheme))
(print-brackets #f)

(define args (command-line-arguments))
(define profile-name
  (if (null? args)
      (begin (display "usage: gen-boot.ss <profile>\n") (exit 1))
      (string->symbol (car args))))

(define (read-all f)
  (with-input-from-file f
    (lambda ()
      (let loop ((acc '()))
        (let ((x (read)))
          (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))

;; ---- profiles.ss -----------------------------------------------------------

(define spec (read-all "host/gambit/profiles.ss"))

(define (section name)
  (let loop ((fs spec))
    (cond ((null? fs) (error 'gen-boot "section missing from profiles.ss" name))
          ((and (pair? (car fs)) (eq? (caar fs) name)) (cdar fs))
          (else (loop (cdr fs))))))

(define group-specs (section 'groups))     ; (name label (file ...))
(define profile-specs (section 'profiles)) ; (name (group ...))

(define (profile-names) (map car profile-specs))

(define kept-groups
  (let loop ((ps profile-specs))
    (cond ((null? ps)
           (display "gen-boot: unknown profile ")
           (display profile-name)
           (display "; profiles.ss lists ")
           (write (profile-names))
           (newline)
           (exit 1))
          ((eq? (caar ps) profile-name) (cadar ps))
          (else (loop (cdr ps))))))

(define excluded-groups
  (let loop ((gs group-specs) (acc '()))
    (cond ((null? gs) (reverse acc))
          ((memq (caar gs) kept-groups) (loop (cdr gs) acc))
          (else (loop (cdr gs) (cons (car gs) acc))))))

(define excluded-files
  (apply append (map caddr excluded-groups)))

;; ---- the names an excluded group takes with it ------------------------------
;; Scan for (def-var! "clojure.core" "name" — the one way a host file publishes
;; a core name, and how the emitted prelude publishes every one of them.

(define core-def-prefix
  (string-append "(def-var! " (string #\") "clojure.core" (string #\")
                 " " (string #\")))

(define (name-end text start)
  (let scan ((j start))
    (cond ((>= j (string-length text)) j)
          ((char=? (string-ref text j) (string-ref (string #\") 0)) j)
          (else (scan (+ j 1))))))

(define (file-core-names path)
  (let ((full (string-append "host/gambit/" path)))
    (if (not (file-exists? full))
        (list)
        (let ((text (call-with-input-file full (lambda (p) (get-string-all p)))))
          (let loop ((i 0) (acc (list)))
            (let ((hit (find-substring core-def-prefix text i)))
              (if (not hit)
                  (reverse acc)
                  (let* ((start (+ hit (string-length core-def-prefix)))
                         (end (name-end text start)))
                    (loop end (cons (substring text start end) acc))))))))))

(define (find-substring needle hay from)
  (let ((nl (string-length needle)) (hl (string-length hay)))
    (let loop ((i from))
      (cond ((> (+ i nl) hl) #f)
            ((string=? (substring hay i (+ i nl)) needle) i)
            (else (loop (+ i 1)))))))

;; A name the KEPT files also define is not missing — the kernel or another
;; group still provides it.
(define kept-names
  (let loop ((gs group-specs) (acc '()))
    (cond ((null? gs) acc)
          ((memq (caar gs) kept-groups)
           (loop (cdr gs) (append (apply append (map file-core-names (caddar gs))) acc)))
          (else (loop (cdr gs) acc)))))

(define (missing-names-of group)
  (let ((names (apply append (map file-core-names (caddr group)))))
    ;; dedupe, and drop anything still provided elsewhere
    (let loop ((ns names) (seen '()) (acc '()))
      (cond ((null? ns) (reverse acc))
            ((member (car ns) seen) (loop (cdr ns) seen acc))
            ((member (car ns) kept-names) (loop (cdr ns) (cons (car ns) seen) acc))
            (else (loop (cdr ns) (cons (car ns) seen) (cons (car ns) acc)))))))

;; ---- write the boot --------------------------------------------------------

(define boot-lines
  (let ((p (open-input-file "host/gambit/boot.ss")))
    (let loop ((acc '()))
      (let ((l (get-line p)))
        (if (eof-object? l)
            (begin (close-port p) (reverse acc))
            (loop (cons l acc)))))))

(define (include-line? l)
  (find-substring "(##include \"" l 0))

(define (included-path l)
  (let* ((s (find-substring "\"" l 0))
         (start (+ s 1))
         (end (let scan ((j start))
                (if (char=? (string-ref l j) #\") j (scan (+ j 1))))))
    (substring l start end)))

(define boot-include-paths
  (let loop ((ls boot-lines) (acc (list)))
    (cond ((null? ls) (reverse acc))
          ((find-substring "(##include \"" (car ls) 0)
           (loop (cdr ls) (cons (included-path (car ls)) acc)))
          (else (loop (cdr ls) acc)))))

;; ---- the SCHEME-level names an excluded file takes with it -------------------
;; A booted file may call an excluded file's procedure directly, which no core
;; var covers: the reader builds a #"..." literal through jolt-re-pattern, and
;; the class model probes jolt-regex?. Same rule as the hand-written degradations
;; in host-vars.ss — a PREDICATE answers #f, because a value cannot be of a type
;; this build does not carry, and anything else raises.
;;
;; seed/ files are skipped: their defines are per-var mangled names reached only
;; through var cells, never called by name from a booted file.

(define (seed-file? path) (find-substring "seed/" path 0))

;; Only names WE define may be degraded. A vendored file defines standard-looking
;; helpers (irregex has its own vector-copy) that the host itself provides, and
;; shadowing one of those with a raise would break a build rather than describe
;; it. Vendored code is reached through our wrappers, which are ours to degrade.
(define (vendored-file? path) (find-substring "vendor/" path 0))
(define (degradable-file? path)
  (and (not (seed-file? path)) (not (vendored-file? path))))

(define (file-text path)
  (let ((full (string-append "host/gambit/" path)))
    (if (file-exists? full)
        (call-with-input-file full (lambda (p) (get-string-all p)))
        "")))

(define (token-end text start)
  (let scan ((j start))
    (cond ((>= j (string-length text)) j)
          ((memv (string-ref text j) (list #\space #\newline #\tab #\) #\()) j)
          (else (scan (+ j 1))))))

;; every name a file defines, either shape of define
;; define-record-type generates NAME?, which a define scan cannot see — the blind
;; spot that left jhost? unbound when the class model probed it. A record type
;; from an excluded file has no instances here, so its predicate is #f.
(define (file-record-predicates path)
  (let ((text (file-text path)))
    (let loop ((i 0) (acc (list)))
      (let ((hit (find-substring "(define-record-type " text i)))
        (if (not hit)
            (reverse acc)
            (let* ((after (+ hit (string-length "(define-record-type ")))
                   (start (if (and (< after (string-length text))
                                   (char=? (string-ref text after) #\())
                              (+ after 1)
                              after))
                   (end (token-end text start)))
              (loop end
                    (if (> end start)
                        (cons (string-append (substring text start end) "?") acc)
                        acc))))))))

(define (file-defines path)
  (let ((text (file-text path)))
    (let loop ((i 0) (acc (list)))
      (let ((hit (find-substring "(define " text i)))
        (if (not hit)
            (reverse acc)
            (let* ((after (+ hit (string-length "(define ")))
                   (start (if (and (< after (string-length text))
                                   (char=? (string-ref text after) #\())
                              (+ after 1)
                              after))
                   (end (token-end text start)))
              (loop end
                    (if (> end start) (cons (substring text start end) acc) acc))))))))

(define kept-text
  (let loop ((ls boot-include-paths) (acc (list)))
    (cond ((null? ls) (apply string-append (reverse acc)))
          ((or (member (car ls) excluded-files) (seed-file? (car ls))) (loop (cdr ls) acc))
          (else (loop (cdr ls) (cons (file-text (car ls)) acc))))))

(define kept-defines
  (let loop ((ls boot-include-paths) (acc (list)))
    (cond ((null? ls) acc)
          ((member (car ls) excluded-files) (loop (cdr ls) acc))
          (else (loop (cdr ls) (append (file-defines (car ls)) acc))))))

(define (predicate-name? n)
  (let ((len (string-length n)))
    (and (> len 0) (char=? (string-ref n (- len 1)) #\?))))

(define (scheme-degradations-of group)
  (let loop ((fs (caddr group)) (acc (list)))
    (if (null? fs)
        (reverse acc)
        (loop (cdr fs)
              (let inner ((ns (if (degradable-file? (car fs))
                                  (append (file-defines (car fs))
                                          (file-record-predicates (car fs)))
                                  (list)))
                          (acc acc))
                (cond ((null? ns) acc)
                      ((member (car ns) kept-defines) (inner (cdr ns) acc))
                      ((member (car ns) acc) (inner (cdr ns) acc))
                      ((find-substring (car ns) kept-text 0)
                       (inner (cdr ns) (cons (car ns) acc)))
                      (else (inner (cdr ns) acc))))))))

(define out-path (string-append "host/gambit/boot-" (symbol->string profile-name) ".ss"))
(define out (open-output-file out-path 'replace))

(put-string out (string-append
  ";; boot-" (symbol->string profile-name) ".ss — GENERATED by host/gambit/gen-boot.ss\n"
  ";; from boot.ss + profiles.ss. Do not edit; regenerate.\n;;\n"
  ";; profile: " (symbol->string profile-name) "\n"))
(put-string out ";; groups kept:")
(for-each (lambda (g) (put-string out (string-append " " (symbol->string g)))) kept-groups)
(put-string out (if (null? kept-groups) " (kernel only)\n" "\n"))
(put-string out ";; groups excluded:")
(for-each (lambda (g) (put-string out (string-append " " (symbol->string (car g)))))
          excluded-groups)
(put-string out (if (null? excluded-groups) " none\n\n" "\n\n"))

(define dropped 0)
(for-each
  (lambda (l)
    (if (and (include-line? l) (member (included-path l) excluded-files))
        (begin (set! dropped (+ dropped 1))
               (put-string out (string-append ";; excluded by profile: " l "\n")))
        (begin (put-string out l) (put-string out "\n"))))
  boot-lines)

;; Degradation goes last so it wins over anything an earlier file bound.
(unless (null? excluded-groups)
  (put-string out "\n;; ---- excluded features report themselves --------------------------------\n")
  (put-string out ";; Derived from the def-var! forms in the excluded files, so this list cannot\n")
  (put-string out ";; drift from the code. A dropped feature raises with its group named rather\n")
  (put-string out ";; than failing as an unbound global.\n")
  (put-string out ";; A predicate over a type the build cannot hold answers #f — a value simply\n")
  (put-string out ";; is not one — while an operation that would have to produce or consume that\n")
  (put-string out ";; type raises. Same split as the hand-written degradations in host-vars.ss.\n")
  (put-string out "(define (profile-excluded-pred! nm)\n")
  (put-string out "  (def-var! \"clojure.core\" nm (lambda args #f)))\n")
  (put-string out "(define (profile-excluded! nm group)\n")
  (put-string out "  (def-var! \"clojure.core\" nm\n")
  (put-string out "    (lambda args\n")
  (put-string out "      (jolt-throw\n")
  (put-string out "        (jolt-host-throwable \"java.lang.UnsupportedOperationException\"\n")
  (put-string out "          (string-append \"clojure.core/\" nm \" is not in this build: the \"\n")
  (put-string out "                         group \" feature group was excluded\"))))))\n")
  (for-each
    (lambda (g)
      (let ((snames (scheme-degradations-of g)))
        (unless (null? snames)
          (put-string out (string-append "\n;; " (symbol->string (car g))
                                         " — direct callers in booted files\n"))
          (for-each
            (lambda (n)
              (if (predicate-name? n)
                  (put-string out (string-append "(define (" n " . args) #f)\n"))
                  (put-string out
                    (string-append "(define (" n " . args)\n"
                                   "  (jolt-throw (jolt-host-throwable\n"
                                   "    \"java.lang.UnsupportedOperationException\"\n"
                                   "    \"" n " is not in this build: the " (cadr g)
                                   " feature group was excluded\")))\n"))))
            snames))))
    excluded-groups)
  (for-each
    (lambda (g)
      (let ((names (missing-names-of g)))
        (put-string out (string-append "\n;; " (symbol->string (car g)) " ("
                                       (number->string (length names)) " names)\n"))
        (for-each
          (lambda (n)
            (if (predicate-name? n)
                (put-string out (string-append "(profile-excluded-pred! \"" n "\")\n"))
                (put-string out (string-append "(profile-excluded! \"" n "\" \"" (cadr g) "\")\n"))))
          names)))
    excluded-groups))

(close-port out)

;; An entry file (repl-main.ss) includes the ACTIVE profile by a fixed name, so
;; switching profiles is a regeneration rather than an edit.
(let ((active (open-output-file "host/gambit/boot-active.ss" 'replace)))
  (put-string active ";; boot-active.ss — GENERATED. The profile the next bundle build carries.\n")
  (put-string active (string-append "(##include \"boot-" (symbol->string profile-name) ".ss\")\n"))
  (close-port active))

(display (string-append "gen-boot: wrote " out-path
                        " (profile " (symbol->string profile-name)
                        ", " (number->string dropped) " file(s) excluded, "
                        (number->string
                          (apply + (map (lambda (g) (length (missing-names-of g))) excluded-groups)))
                        " name(s) degraded)\n"))
