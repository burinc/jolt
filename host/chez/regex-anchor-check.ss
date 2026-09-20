;; regex-anchor-check.ss — the staleness gate for host/chez/java/regex-anchor-sre.scm.
;;
;; regex-anchor-sre.scm redefines ONE vendored procedure, irregex's sre->procedure,
;; with a copy carrying one change (an O(1) fast path for one-unit look-behind —
;; the file says why). A copy of vendored code is only safe while the original it
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
(define pinned-name "sre->procedure")

(define (proc-datum path name)
  (let ((d (hashtable-ref (gs-top-procs path) name #f)))
    (unless d
      (printf "regex-anchor: ~a defines no ~a\n" path name)
      (exit 1))
    d))

(define (read-pin)
  (and (file-exists? pin-path)
       (let ((forms (gs-read-forms pin-path)))
         (and (pair? forms) (car forms)))))

(define (write-pin! datum)
  (call-with-output-file pin-path
    (lambda (p)
      (display ";; PINNED COPY — do not edit by hand.\n" p)
      (display ";;\n" p)
      (display ";; irregex's own sre->procedure, as of the currently checked-out\n" p)
      (display ";; vendor/irregex. host/chez/java/regex-anchor-sre.scm is jolt's\n" p)
      (display ";; replacement for it, and `make regexanchorcheck` fails when the two\n" p)
      (display ";; stop agreeing — see host/chez/regex-anchor-check.ss. Nothing loads\n" p)
      (display ";; this file.\n" p)
      (display ";;\n" p)
      (display ";; Re-pin with `make regexanchorcheck-regen` AFTER porting the upstream\n" p)
      (display ";; change into regex-anchor-sre.scm.\n" p)
      (pretty-print datum p))
    'truncate))

(define (main args)
  (for-each (lambda (f)
              (unless (file-exists? f)
                (printf "regex-anchor: MISSING file ~a\n" f)
                (printf "  (vendor submodules not initialized? run `git submodule update --init`)\n")
                (exit 1)))
            (list upstream-path override-path))
  ;; The override has to actually define the procedure it is shadowing, or the
  ;; vendored one is live and this gate is watching nothing.
  (proc-datum override-path pinned-name)
  (let ((upstream (proc-datum upstream-path pinned-name)))
    (cond
      ((member "--regen" args)
       (write-pin! upstream)
       (printf "regex-anchor: re-pinned ~a from ~a\n" pinned-name upstream-path)
       (exit 0))
      (else
       (let ((pinned (read-pin)))
         (cond
           ((not pinned)
            (printf "regex-anchor: no pin at ~a — run `make regexanchorcheck-regen`\n" pin-path)
            (exit 1))
           ((equal? pinned upstream)
            (printf "regex-anchor: passed (~a matches the pinned upstream copy)\n" pinned-name)
            (exit 0))
           (else
            (printf "regex-anchor: irregex's ~a has CHANGED since ~a\n" pinned-name override-path)
            (printf "           was derived from it, so jolt is shadowing a stale copy.\n\n")
            (printf "Port the upstream change into ~a — keeping the\n" override-path)
            (printf "change marked there — then `make regexanchorcheck-regen`.\n")
            (exit 1))))))))

(main (cdr (command-line)))
