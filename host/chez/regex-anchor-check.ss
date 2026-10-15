;; regex-anchor-check.ss — the staleness gate for host/chez/java/regex-anchor-sre.scm.
;;
;; regex-anchor-sre.scm redefines vendored irregex procedures with copies carrying
;; marked jolt changes: sre->procedure (the look-behind fast path, the
;; java.util.regex anchors, empty iterations and the loop memo) and cset-union
;; (a merge that kept char sets sorted) — the file says why. A copy of vendored code is only safe while the original it
;; was copied from is still the original: bump vendor/irregex and upstream's fix or
;; rewrite would be shadowed by jolt's older copy, silently, with no build error
;; anywhere. (Same hazard host/chez/regex-dfa-check.ss guards for nfa->dfa.)
;;
;; So the upstream definition is PINNED here, as the read datum, and the gate fails
;; when the submodule's differs. The fix is never to re-pin blindly: port whatever
;; changed into regex-anchor-sre.scm, keeping the jolt change, then
;; `make regexanchorcheck-regen`.
;;
;; Comparison is on the datum, not the text, so reformatting and comments in
;; irregex are not drift — the same rule mirror-drift-check.ss uses.
(import (chezscheme))
(include "host/chez/gate-scan-lib.ss")

(define upstream-path "vendor/irregex/irregex.scm")
(define override-path "host/chez/java/regex-anchor-sre.scm")
(define pin-path "host/chez/regex-anchor-sre-upstream.scm")
(define pinned-names '("sre->procedure" "cset-union"))

(define (proc-datum path name)
  (let ((d (hashtable-ref (gs-top-procs path) name #f)))
    (unless d
      (printf "regex-anchor: ~a defines no ~a\n" path name)
      (exit 1))
    d))

(define (pin-name d) (symbol->string (car (cadr d))))

;; name -> pinned datum, or #f when there is no pin file.
(define (read-pins)
  (and (file-exists? pin-path)
       (let ((h (make-hashtable string-hash string=?)))
         (for-each (lambda (d) (hashtable-set! h (pin-name d) d))
                   (gs-read-forms pin-path))
         h)))

(define (write-pins! datums)
  (call-with-output-file pin-path
    (lambda (p)
      (display ";; PINNED COPY — do not edit by hand.\n" p)
      (display ";; Code from irregex, Copyright (c) 2005-2024 Alex Shinn, BSD-style license\n" p)
      (display ";; (licenses/BSD-irregex.txt).\n" p)
      (display ";;\n" p)
      (display ";; irregex's own sre->procedure and cset-union, as of the currently\n" p)
      (display ";; checked-out vendor/irregex. host/chez/java/regex-anchor-sre.scm holds\n" p)
      (display ";; jolt's replacements, and `make regexanchorcheck` fails when the two\n" p)
      (display ";; stop agreeing — see host/chez/regex-anchor-check.ss. Nothing loads\n" p)
      (display ";; this file.\n" p)
      (display ";;\n" p)
      (display ";; Re-pin with `make regexanchorcheck-regen` AFTER porting the upstream\n" p)
      (display ";; change into regex-anchor-sre.scm.\n" p)
      (for-each (lambda (d) (pretty-print d p)) datums))
    'truncate))

(define (main args)
  (for-each (lambda (f)
              (unless (file-exists? f)
                (printf "regex-anchor: MISSING file ~a\n" f)
                (printf "  (vendor submodules not initialized? run `git submodule update --init`)\n")
                (exit 1)))
            (list upstream-path override-path))
  ;; The override has to actually define each procedure it is shadowing, or
  ;; the vendored one is live and this gate is watching nothing.
  (for-each (lambda (n) (proc-datum override-path n)) pinned-names)
  (let ((upstream (map (lambda (n) (proc-datum upstream-path n)) pinned-names)))
    (cond
      ((member "--regen" args)
       (write-pins! upstream)
       (printf "regex-anchor: re-pinned ~a from ~a\n" pinned-names upstream-path)
       (exit 0))
      (else
       (let ((pins (read-pins)))
         (unless pins
           (printf "regex-anchor: no pin at ~a — run `make regexanchorcheck-regen`\n" pin-path)
           (exit 1))
         (let ((changed (let loop ((ns pinned-names) (ds upstream) (acc '()))
                          (cond ((null? ns) (reverse acc))
                                ((equal? (hashtable-ref pins (car ns) #f) (car ds))
                                 (loop (cdr ns) (cdr ds) acc))
                                (else (loop (cdr ns) (cdr ds) (cons (car ns) acc)))))))
           (cond
             ((null? changed)
              (printf "regex-anchor: passed (~a match the pinned upstream copies)\n" pinned-names)
              (exit 0))
             (else
              (for-each
                (lambda (n)
                  (printf "regex-anchor: irregex's ~a has CHANGED (or is not pinned) since\n" n)
                  (printf "           ~a was derived from it, so jolt is\n" override-path)
                  (printf "           shadowing a stale copy.\n"))
                changed)
              (printf "\nPort the upstream change into ~a — keeping the\n" override-path)
              (printf "changes marked there — then `make regexanchorcheck-regen`.\n")
              (exit 1)))))))))

(main (cdr (command-line)))
