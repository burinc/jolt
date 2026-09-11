;; regex-dfa-check.ss — the staleness gate for host/chez/regex-dfa.ss.
;;
;; regex-dfa.ss redefines ONE vendored procedure, irregex's nfa->dfa, with a copy
;; carrying two changes (a hashed seen-set and a work budget — the file says why).
;; A copy of vendored code is only safe while the original it was copied from is
;; still the original: bump vendor/irregex and upstream's fix or rewrite would be
;; shadowed by jolt's older copy, silently, with no build error anywhere.
;;
;; So the upstream definition is PINNED here, as the read datum, and the gate
;; fails when the submodule's differs. The fix is never to re-pin blindly: port
;; whatever changed into regex-dfa.ss, keeping the two marked jolt changes, and
;; then `make regexdfacheck-regen`.
;;
;; Comparison is on the datum, not the text, so reformatting and comments in
;; irregex are not drift — the same rule mirror-drift-check.ss uses.
(import (chezscheme))
(include "host/chez/gate-scan-lib.ss")

(define upstream-path "vendor/irregex/irregex.scm")
(define override-path "host/chez/regex-dfa.ss")
(define pin-path "host/chez/regex-dfa-upstream.scm")
(define pinned-name "nfa->dfa")

(define (proc-datum path name)
  (let ((d (hashtable-ref (gs-top-procs path) name #f)))
    (unless d
      (printf "regex-dfa: ~a defines no ~a\n" path name)
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
      (display ";; irregex's own nfa->dfa, as of the currently checked-out\n" p)
      (display ";; vendor/irregex. host/chez/regex-dfa.ss is jolt's replacement for it,\n" p)
      (display ";; and `make regexdfacheck` fails when the two stop agreeing — see\n" p)
      (display ";; host/chez/regex-dfa-check.ss. Nothing loads this file.\n" p)
      (display ";;\n" p)
      (display ";; Re-pin with `make regexdfacheck-regen` AFTER porting the upstream\n" p)
      (display ";; change into regex-dfa.ss.\n" p)
      (pretty-print datum p))
    'truncate))

(define (main args)
  (for-each (lambda (f)
              (unless (file-exists? f)
                (printf "regex-dfa: MISSING file ~a\n" f)
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
       (printf "regex-dfa: re-pinned ~a from ~a\n" pinned-name upstream-path)
       (exit 0))
      (else
       (let ((pinned (read-pin)))
         (cond
           ((not pinned)
            (printf "regex-dfa: no pin at ~a — run `make regexdfacheck-regen`\n" pin-path)
            (exit 1))
           ((equal? pinned upstream)
            (printf "regex-dfa: passed (~a matches the pinned upstream copy)\n" pinned-name)
            (exit 0))
           (else
            (printf "regex-dfa: irregex's ~a has CHANGED since host/chez/regex-dfa.ss\n" pinned-name)
            (printf "           was derived from it, so jolt is shadowing a stale copy.\n\n")
            (printf "Port the upstream change into ~a — keeping the two\n" override-path)
            (printf "changes marked `jolt:` there — then `make regexdfacheck-regen`.\n")
            (exit 1))))))))

(main (cdr (command-line)))
