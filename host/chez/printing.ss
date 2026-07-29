;; readable printer + output seams — the __pr-str1 / __write / __with-out-str
;; host seams the overlay's pr-str/pr/prn/print/println/*-str family is built on
;; (jolt-core/clojure/core/20-coll.clj).
;;
;; jolt-pr-str (rt.ss) is STR-style: strings render raw. pr-str needs READABLE
;; (pr) style: strings quoted+escaped at every nesting level. This adds the
;; readable renderer; it mirrors jolt-pr-str but quotes strings and recurses into
;; itself, delegating scalars (nil/bool/number/keyword/symbol/char/regex) to
;; jolt-pr-str (already readable for those). The canonical ORDERED printer is
;; still future work — unordered colls render in HAMT order, compared via `=`.

;; inner string escape (no surrounding quotes): " \ newline tab return backspace formfeed.
(define (jolt-str-escape s)
  (let loop ((cs (string->list s)) (acc '()))
    (if (null? cs)
        (list->string (reverse acc))
        (loop (cdr cs)
              (let ((c (car cs)))
                (case c
                  ((#\") (cons #\" (cons #\\ acc)))
                  ((#\\) (cons #\\ (cons #\\ acc)))
                  ((#\newline) (cons #\n (cons #\\ acc)))
                  ((#\tab) (cons #\t (cons #\\ acc)))
                  ((#\return) (cons #\r (cons #\\ acc)))
                  ((#\backspace) (cons #\b (cons #\\ acc)))
                  ((#\page) (cons #\f (cons #\\ acc)))
                  (else (cons c acc))))))))

;; A host shim registers a type's readable rendering via register-pr-readable-arm!,
;; or register-pr-arm! for types whose str and readable forms match (most host types:
;; inst, uuid, record, var, …). Disjoint types, checked before the base cases.
(define jolt-pr-readable-arms '())
(define (register-pr-readable-arm! pred render)
  (set! jolt-pr-readable-arms (cons (cons pred render) jolt-pr-readable-arms)))
(define (register-pr-arm! pred render)
  (register-pr-str-arm! pred render)
  (register-pr-readable-arm! pred render))

;; *print-namespace-maps* shared-ns detector: returns the namespace string when
;; the map is non-empty, the var is true, every key is a namespace-qualified
;; keyword, and they all share the same (non-nil) namespace. Otherwise #f.
(define (pr-ns-maps-shared-ns pairs)
  (and (pair? pairs)
       (jolt-truthy? (jolt-var-get (jolt-var "clojure.core" "*print-namespace-maps*")))
       (keyword? (caar pairs))
       (let ((ns (keyword-t-ns (caar pairs))))
         (and ns (not (string=? ns ""))
              (let all-ns? ((rest (cdr pairs)))
                (if (null? rest)
                    ns   ;; all keys checked → return the shared namespace
                    (and (keyword? (caar rest))
                         (let ((n (keyword-t-ns (caar rest))))
                           (and n (string=? n ns)
                                (all-ns? (cdr rest)))))))))))

(define (jolt-pr-readable-base x)
  (cond
    ((string? x) (string-append "\"" (jolt-str-escape x) "\""))
    ;; pr renders the infinities / NaN in READABLE form (##Inf reads back), unlike
    ;; str's "Infinity"/"-Infinity"/"NaN". Applies at every nesting level.
    ((and (flonum? x) (fl= x +inf.0)) "##Inf")
    ((and (flonum? x) (fl= x -inf.0)) "##-Inf")
    ((and (flonum? x) (not (fl= x x))) "##NaN")
    ;; pr of an exact integer outside long range carries the BigInt N suffix
    ;; ((pr-str 12345678901234567890) => "12345678901234567890N"); str doesn't.
    ((jolt-bigint-print? x) (string-append (number->string x) "N"))
    ;; transients print as a cold tagged type (print-method routes this through a
    ;; multimethod; the readable fallback renders it directly).
    ;; forward refs to transients.ss (loaded later) — resolved at call time.
    ((jolt-transient? x)
     (case (jolt-transient-kind x)
       ((vec) "#<transient vector>") ((set) "#<transient set>") (else "#<transient map>")))
    ((pvec? x) (if (jolt-print-hash?) "#"
                   (with-deeper-print
                     (string-append "[" (jolt-str-join (jolt-limited-vec-strs x jolt-pr-readable)) "]"))))
    ((pset? x) (if (jolt-print-hash?) "#"
                   (with-deeper-print
                     (string-append "#{" (jolt-str-join (jolt-limited-list-strs
                       (pset-fold x (lambda (e a) (cons (jolt-pr-readable e) a)) '()))) "}"))))
    ((pmap? x)
     (if (jolt-print-hash?) "#"
         (with-deeper-print
           (let* ((pairs (pmap-fold x (lambda (k v a) (cons (cons k v) a)) '()))
                  (ns (pr-ns-maps-shared-ns pairs)))
             (if ns
                 ;; #:ns{:key val, …} — emit name-only keys in sorted order
                 (string-append "#:" ns "{"
                                (jolt-str-join-comma
                                 (jolt-limited-list-strs
                                  (map (lambda (pr)
                                         (string-append (jolt-pr-readable (keyword #f (keyword-t-name (car pr))))
                                                        " " (jolt-pr-readable (cdr pr))))
                                       pairs)))
                                "}")
                 ;; standard {k v, …}
                 (string-append "{"
                                (jolt-str-join-comma
                                 (jolt-limited-list-strs
                                  (map (lambda (pr)
                                         (string-append (jolt-pr-readable (car pr)) " "
                                                        (jolt-pr-readable (cdr pr))))
                                       pairs)))
                                "}"))))))
    ((empty-list-t? x) (if (jolt-print-hash?) "#" "()"))
    ((cseq? x) (if (jolt-print-hash?) "#"
                   (with-deeper-print
                     (string-append "(" (jolt-str-join (jolt-limited-seq-strs x jolt-pr-readable)) ")"))))
    ;; Defer to the str-side printer, whose arms and base cases these share —
    ;; passing readable? so that if it reaches the #object[…] fallback the content
    ;; is QUOTED, which is the (pr x) vs (print x) difference on the JVM.
    (else (jolt-pr-str/readable x #t))))
(define (jolt-pr-readable-dispatch x)
  (let loop ((as jolt-pr-readable-arms))
    (cond ((null? as) (jolt-pr-readable-base x))
          (((caar as) x) ((cdar as) x))
          (else (loop (cdr as))))))

;; *print-meta* support. The var is def'd after this file loads, so capture its
;; cell lazily; jolt-var-get (patched by dyn-binding.ss) honors a `binding`.
(define pr-meta-cell #f)
(define (pr-print-meta?)
  (unless pr-meta-cell (set! pr-meta-cell (jolt-var "clojure.core" "*print-meta*")))
  (jolt-truthy? (jolt-var-get pr-meta-cell)))
;; The metadata to print before x, or jolt-nil. A var prints as #'ns/name (its
;; {:ns :name} is derived, not user metadata) and a procedure is opaque — skip both.
(define (pr-user-meta x)
  (if (or (var-cell? x) (procedure? x)) jolt-nil (jolt-meta x)))

(define (jolt-pr-readable x)
  (if (pr-print-meta?)
      (let ((m (pr-user-meta x)))
        (if (jolt-nil? m)
            (jolt-pr-readable-dispatch x)
            (string-append "^" (jolt-pr-readable-dispatch m) " " (jolt-pr-readable-dispatch x))))
      (jolt-pr-readable-dispatch x)))

;; __pr-str1: render ONE value readably (the overlay's pr-str joins these).
(define (jolt-pr-str1 x) (jolt-pr-readable x))

;; The value `jolt -e` echoes, and what the unit gate compares against. READABLE,
;; like Clojure's REPL, which prints with pr: a result reads back as the value it
;; names, so a nested string keeps its quotes, a char keeps its \c syntax, and a
;; host object prints #object[cls "content"]. This used to go through
;; jolt-final-str, the str-style renderer, which printed ["hi" \c 1] as [hi \c 1].
;; nil still renders as the empty string, so `-e` of a side-effecting form prints
;; nothing — which is what `clojure -M -e nil` does too.
(define (jolt-repl-str x) (if (jolt-nil? x) "" (jolt-pr-readable x)))

;; __write: push a string to output. Normally this goes to the current Chez port
;; (so __with-out-str's redirect captures it). When clojure.pprint is active it
;; installs __pprint-write-hook; jolt-write then offers each string to the hook,
;; which routes it column-aware into a clojure.pprint pretty-writer if *out* is
;; bound to one (returns truthy) and otherwise declines (returns nil) so the
;; string falls through to the port. This is the JVM behaviour where core print
;; honours *out*; jolt only needs it for the pretty-printer.
(define jolt-pprint-write-hook jolt-nil)
;; suppressed while __with-out-str captures output to a string port: there the
;; redirect, not *out*, defines where text goes (pr-str / print-str rely on it).
(define jolt-pprint-hook-suppressed (make-thread-parameter #f))
(define (jolt-write s)
  (cond ((and (not (jolt-nil? jolt-pprint-write-hook))
              (not (jolt-pprint-hook-suppressed))
              (jolt-truthy? (jolt-invoke jolt-pprint-write-hook s)))
         jolt-nil)
        ;; *out* rebound to a real writer: write through it, like the JVM's
        ;; (.write *out* s). Any value that carries a write method qualifies — a
        ;; host writer (StringWriter, PrintWriter) OR a deftype/reify/proxy one,
        ;; which is why this tests for a write METHOD rather than for jhost:
        ;; keying on the representation silently skipped every reify Writer.
        ;; The default port-writer over stdout keeps the fast port path below.
        ((let ((w (var-deref "clojure.core" "*out*")))
           (and (or (iface-method w "write" #f)
                    (and (jhost? w)
                         (not (and (string=? (jhost-tag w) "port-writer")
                                   (eq? (vector-ref (jhost-state w) 0) 'out)))))
                w))
         => (lambda (w) (record-method-dispatch w "write" (jolt-list s)) jolt-nil))
        (else (display s) jolt-nil)))
(def-var! "clojure.core" "__set-pprint-write-hook!"
  (lambda (f) (set! jolt-pprint-write-hook f) jolt-nil))
;; clojure.pprint wraps its writing in this so core print routes into the active
;; pretty-writer even under an outer with-out-str (which sets suppressed). A
;; pr-str/print-str nested inside then re-suppresses, so its capture still works.
(def-var! "clojure.core" "__with-pprint-routing"
  (lambda (thunk)
    (parameterize ((jolt-pprint-hook-suppressed #f)) (jolt-invoke thunk))))

;; __with-out-str: run a jolt thunk with output captured to a string, and return
;; the captured text.
;;
;; Two redirects have to agree here. with-output-to-string moves the CHEZ port,
;; which catches everything that reaches `display`; jolt-write separately honours
;; *out* when it holds a real writer. Redirecting only the port leaves an OUTER
;; (binding [*out* some-writer] …) in force, and jolt-write then sends the text to
;; that writer instead of the capture:
;;   (binding [*out* sw] (with-out-str (print "x")))  ; JVM: "x", sw empty
;; So push a *out* binding of our own, to the var's ROOT — the default stdout
;; port-writer, whose port resolves live to (current-output-port) and therefore
;; follows the redirect. Both mechanisms then point at the string port.
;;
;; Pushing a real binding rather than suppressing the *out* branch outright is
;; what keeps an INNER rebinding working: (with-out-str (binding [*out* sw] …))
;; pushes over this frame and still wins, exactly as on the JVM. The binding stack
;; lives in dyn-binding.ss, loaded after this file — resolved at call time.
(define (jolt-with-out-str thunk)
  (with-output-to-string
    (lambda ()
      (let ((cell (var-cell-lookup "clojure.core" "*out*")))
        (dynamic-wind
          (lambda ()
            (when cell
              (jolt-push-thread-bindings (jolt-hash-map cell (var-cell-root cell)))))
          (lambda () (parameterize ((jolt-pprint-hook-suppressed #t)) (jolt-invoke thunk)))
          (lambda () (when cell (jolt-pop-thread-bindings))))))))

;; __eprint / __eprintf: stderr seams. Flush each write — like the JVM's
;; auto-flushing System.err — so a long-running process (a server that never
;; returns from -main) shows its log lines instead of leaving them in a buffer
;; that only drains at exit.
(define (jolt-eprint s)
  (display s (current-error-port))
  (flush-output-port (current-error-port))
  jolt-nil)
(define (jolt-eprintf fmt . args)
  (apply fprintf (current-error-port) fmt args)
  (flush-output-port (current-error-port))
  jolt-nil)

(def-var! "clojure.core" "__pr-str1" jolt-pr-str1)
(def-var! "clojure.core" "__write" jolt-write)
(def-var! "clojure.core" "__with-out-str" jolt-with-out-str)
(def-var! "clojure.core" "__eprint" jolt-eprint)
(def-var! "clojure.core" "__eprintf" jolt-eprintf)
