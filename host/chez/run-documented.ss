;; run-documented.ss — the jolt half of the known-divergences gate.
;;
;; test/conformance/known-divergences.edn has two lists. :entries names corpus
;; rows and certify.clj already gates it for NEW and STALE. :documented is prose
;; about divergences that are NOT corpus rows, and nothing ever ran it. Making the
;; 33 checkable entries checkable found two whose divergence no longer existed at
;; all and five whose recorded JVM or jolt answer no run reproduces — including one
;; claiming resolve throws ClassNotFoundException, which it never does.
;;
;; So every :documented entry now carries a :check. Either
;;   :check {:expr "<expr>" :jvm "<rendered>" :jolt "<rendered>"}   machine-verified
;;   :check :prose  :why "<reason>"                                 deliberately not
;; and a missing :check fails the gate, so a new entry cannot arrive unverified.
;;
;; This runner owns the JOLT half: evaluate :expr here and require it to render
;; exactly :jolt. certify.clj owns the JVM half against reference Clojure, and
;; both ends additionally require :jvm and :jolt to DIFFER — an entry whose two
;; sides have converged documents a divergence that no longer exists.
;;
;;   chez --script host/chez/run-documented.ss            gate
;;   chez --script host/chez/run-documented.ss --record   print measured :jolt values
(import (chezscheme))

(load "host/chez/run-gate-harness.ss")
(load "host/chez/loader.ss")
(set-source-roots! ldr-install-roots)
(load-namespace "jolt.time.base")
(load "host/chez/run-case-isolation.ss")

(define record-mode?
  (let loop ((a (command-line-arguments)))
    (cond ((null? a) #f)
          ((string=? (car a) "--record") #t)
          (else (loop (cdr a))))))

(define (slurp path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((cs '()) (c (read-char p)))
        (if (eof-object? c) (list->string (reverse cs))
            (loop (cons c cs) (read-char p)))))))

(define registry
  (jolt-read-string (slurp "test/conformance/known-divergences.edn")))
(define (kw s) (keyword #f s))
(define entries (jolt-get registry (kw "documented")))

;; Render exactly as certify.clj's JVM half does: the readable printer for a
;; value, "throws <SimpleName>" for a raise. The simple name is the last dotted
;; segment of the class jolt reports, so the two halves name the same thing.
(define (kd-simple-name v)
  (let ((n (guard (e (#t jolt-nil)) (jolt-class-name (jolt-unwrap-throw v)))))
    (if (string? n) (jch-last-segment n) "Object")))

(define (kd-render expr)
  (let ((sink (open-output-string)))
    (guard (e (#t (string-append "throws " (kd-simple-name e))))
      ;; jolt-pr-str1 is pr-str: readable, and "nil" for nil. NOT jolt-repl-str
      ;; (the -e printer), which renders nil as the empty string and would make
      ;; every nil-valued entry disagree with the JVM half for no real reason.
      (jolt-pr-str1
        (parameterize ((current-output-port sink))
          (jolt-compile-eval (string-append "(do " expr ")") "user"))))))

;; Every :category in use must have a :legend line. A category is how a reader
;; decides whether a divergence is deliberate, and one with no legend entry says
;; nothing — :restrictive was in use with no line until this check went in.
(define (kd-check-legend!)
  (let ((legend (jolt-get registry (kw "legend")))
        (seen (make-hashtable string-hash string=?)))
    (for-each
      (lambda (lst)
        (let loop ((i 0))
          (when (< i (pvec-count lst))
            (let ((c (jolt-get (pvec-nth-d lst i jolt-nil) (kw "category"))))
              (when (and (keyword? c) (jolt-nil? (jolt-get legend c))
                         (not (hashtable-ref seen (keyword-t-name c) #f)))
                (hashtable-set! seen (keyword-t-name c) #t)
                (fail! ":legend" (string-append "category :" (keyword-t-name c)
                                                " is used but has no :legend entry"))))
            (loop (+ i 1)))))
      (list entries (jolt-get registry (kw "entries"))))))

(define pass 0)
(define fails '())
(define checked 0)
(define prose 0)
(define (fail! what msg) (set! fails (cons (cons what msg) fails)))

(kd-check-legend!)

(let loop ((i 0))
  (when (< i (pvec-count entries))
    (let* ((e (pvec-nth-d entries i jolt-nil))
           (behavior (jolt-get e (kw "behavior")))
           (label (if (string? behavior) behavior "<no :behavior>"))
           (check (jolt-get e (kw "check"))))
      (cond
        ((jolt-nil? check)
         (fail! label "no :check — add {:expr .. :jvm .. :jolt ..} or :prose with a :why"))
        ((eq? check (kw "prose"))
         (if (jolt-nil? (jolt-get e (kw "why")))
             (fail! label ":check :prose needs a :why saying why it is not machine-checkable")
             (set! prose (+ prose 1))))
        ((jolt-map? check)
         (let ((expr (jolt-get check (kw "expr")))
               (jvm  (jolt-get check (kw "jvm")))
               (jolt (jolt-get check (kw "jolt"))))
           (cond
             ((not (and (string? expr) (string? jvm) (string? jolt)))
              (fail! label ":check needs string :expr, :jvm and :jolt"))
             ((string=? jvm jolt)
              (fail! label (string-append "STALE — :jvm and :jolt agree (" jvm
                                          "), so this is no longer a divergence")))
             (else
              (set! checked (+ checked 1))
              (let ((got (kd-render expr)))
                (if record-mode?
                    (printf "  :expr ~s\n  :jolt ~s\n\n" expr got)
                    (if (string=? got jolt)
                        (set! pass (+ pass 1))
                        (fail! label (string-append "jolt side: want `" jolt "` got `" got
                                                    "`\n      expr: " expr)))))))))
        (else (fail! label ":check must be a map or :prose")))
      (zj-reset!))
    (loop (+ i 1))))

(if record-mode?
    (printf "\nrecorded ~a checkable entries\n" checked)
    (begin
      (printf "\ndocumented-divergence gate (jolt half): ~a/~a machine-checked entries pass"
              pass checked)
      (printf ", ~a prose\n" prose)
      (when (> (length fails) 0)
        (printf "\n~a FAIL(s):\n" (length fails))
        (for-each (lambda (f) (printf "  [~a]\n      ~a\n" (car f) (cdr f)))
                  (reverse fails)))))
(flush-output-port)
(exit (if (and (not record-mode?) (> (length fails) 0)) 1 0))
