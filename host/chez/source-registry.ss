;; source-registry.ss — map emitted procedures back to Clojure source for native
;; stack traces, and render an uncaught throwable.
;;
;; A direct-linked def compiles to (define jv$ns$name <fn>); the back end also
;; emits (jolt-register-source! "jv$ns$name" ns name file line) once per such def
;; — at definition time, so there is zero per-call cost. On an uncaught error we
;; walk Chez's native continuation frames, read each frame's procedure name, and
;; look it up here to print a Clojure backtrace.
;;
;; CAVEATS. Names map only for stable Chez procedure names — direct-link / AOT
;; closed-world builds. The open-world -e/repl/run path stores fns in var cells
;; as anonymous lambdas, so its frames don't map (the trace falls back to the
;; top-level location compile-eval.ss tracks). Pervasive tail-call optimization
;; also erases tail-called frames, so even a mapped trace shows only the non-tail
;; spine — the immediate error site is often a tail call and won't appear.

;; Keyed by the procedure name Chez actually reports for a frame — the SHORT
;; munged fn name (the letrec self-binding emit-fn uses), e.g. "deepest", not the
;; jv$ns$name global. Two vars in different namespaces can share a short name; an
;; 'ambiguous marker then keeps the frame name in the trace but drops the
;; (now-uncertain) ns/file:line, so a trace is never misattributed.
(define source-registry (make-hashtable string-hash string=?))

(define (jolt-register-source! procname ns nm file line)
  (let ((existing (hashtable-ref source-registry procname #f)))
    (cond
      ((not existing) (hashtable-set! source-registry procname (vector ns nm file line)))
      ((and (vector? existing)
            (or (not (equal? (vector-ref existing 0) ns))
                (not (equal? (vector-ref existing 1) nm))))
       (hashtable-set! source-registry procname 'ambiguous))))
  jolt-nil)
(def-var! "jolt.host" "register-source!" jolt-register-source!)

;; The continuation to walk for an uncaught value: the one jolt-throw captured for
;; THIS value (identity-tagged via jolt-throw-cont, so a stale entry from an
;; earlier caught throw is never reused), else a host condition's own
;; &continuation, else #f. raw may arrive as the &jolt-throw condition wrapping
;; the value (the built-binary launcher hands jolt-report-throwable the guard's
;; raw value) or already unwrapped (the cli unwraps first); unwrap here so the
;; identity match holds either way.
(define (jolt-error-continuation raw)
  (let* ((v (jolt-unwrap-throw raw))
         (tc (jolt-throw-cont)))
    (cond
      ((and (pair? tc) (eq? (car tc) v)) (cdr tc))
      ((and (condition? v) (continuation-condition? v)) (condition-continuation v))
      (else #f))))

;; A frame inspector's procedure name as a string, or #f for a non-frame / unnamed.
(define (srcreg-frame-name io)
  (and (guard (e (#t #f)) (eq? (io 'type) 'continuation))
       (let ((code (guard (e (#t #f)) (io 'code))))
         (and code
              (let ((nm (guard (e (#t #f)) (code 'name))))
                (cond ((string? nm) nm)
                      ((symbol? nm) (symbol->string nm))
                      (else #f)))))))

;; Frame names that are pure Chez / jolt-runtime plumbing — the eval boundary,
;; the var-cell trampoline, continuation/winder internals. They carry no Clojure
;; meaning, so an unmapped frame with one of these names is dropped from the trace
;; (a MAPPED frame is always kept — a jolt fn that happens to share the name still
;; resolves to its source). Any name Chez prefixes with `$` (system) or that jolt
;; prefixes with `jolt-` (host runtime) is plumbing too.
(define srcreg-plumbing-names
  (let ((h (make-hashtable string-hash string=?)))
    (for-each (lambda (s) (hashtable-set! h s #t))
              '("dynamic-wind" "winder-dummy" "ksrc" "invoke" "apply"
                "call-with-values" "call/cc" "call-with-current-continuation"
                "raise" "raise-continuable" "with-exception-handler" "guard"
                "eval" "compile" "interpret" "expand" "read" "load"
                ;; host dispatch/coercion helpers (not `jolt-` prefixed) that carry
                ;; no Clojure meaning in a trace
                "record-method-dispatch" "protocol-resolve" "devirt-resolve"
                "list->cseq" "host-static-call" "host-call"))
    h))
(define (srcreg-plumbing-name? nm)
  (or (hashtable-ref srcreg-plumbing-names nm #f)
      (and (fx>? (string-length nm) 0) (char=? (string-ref nm 0) #\$))
      (and (fx>=? (string-length nm) 5) (string=? (substring nm 0 5) "jolt-"))))

;; An inspector message that may return ZERO values (e.g. 'source-path when a
;; frame carries no source) — read it as one value or #f. `guard` alone cannot
;; catch a zero-value return, so the read goes through call-with-values with a
;; null-tolerant collector.
(define (srcreg-inspect-get io msg)
  (call-with-values (lambda () (guard (e (#t (values 'srcreg-inspect-err))) (io msg)))
    (lambda args (if (or (null? args) (eq? (car args) 'srcreg-inspect-err)) #f (car args)))))

;; A frame's source as (source-name . byte-offset), or #f. Read from the
;; inspector's 'source-object (which carries the sfd and the bfp/efp range)
;; rather than 'source-path: the latter reports only the path string for
;; eval'd code, while the source object always carries the positions.
(define (srcreg-frame-source-pair io)
  (guard (e (#t #f))
    (let ((so (srcreg-inspect-get io 'source-object)))
      (and so
           (let ((path (source-file-descriptor-path (source-object-sfd so)))
                 (bfp (source-object-bfp so)))
             (and (string? path) (fixnum? bfp) (cons path bfp)))))))

;; JOLT_DEBUG_FRAMES extra: the frame's source object, when it has one. For the
;; eval path that is (synthetic-name . offset) resolved through the eval marker
;; registry back to the ORIGINAL clj line — the surface trace-r2's gate asserts
;; on. Exception-proof: the debug print must never break the frame walk.
(define (srcreg-frame-source-debug io)
  (guard (e (#t ""))
    (let ((pair (srcreg-frame-source-pair io)))
      (if pair
          (let ((name (car pair)) (offset (cdr pair)))
            (string-append " source=" name "@" (number->string offset)
                           (if (jolt-eval-source-name? name)
                               (let ((l (jolt-eval-source-line name offset)))
                                 (if l (string-append " -> clj:L" (number->string l))
                                     " -> clj:?"))
                               "")))
          ""))))

;; A frame's OWN line — where its execution is paused, which Chez annotates with
;; the position of the call that CREATED the frame: the call site inside the
;; caller, exactly what the JVM prints for a frame. Resolve the frame's
;; (source-name . offset) through the marker lookup: a .scm path resolves via the
;; on-disk marker table (jolt-marker-line-in-file), a synthetic eval name via the
;; eval registry (jolt-eval-source-line). #f when the frame carries no source or
;; no marker precedes its offset — the renderer then falls back to the defn line.
;; Exception-proof: the reporter runs while an error is being reported.
(define (srcreg-frame-line-from-source-pair io)
  (guard (e (#t #f))
    (let ((pair (srcreg-frame-source-pair io)))
      (and pair
           (let ((name (car pair)) (offset (cdr pair)))
             (if (jolt-eval-source-name? name)
                 (jolt-eval-source-line name offset)
                 (jolt-marker-line-in-file name offset)))))))

;; Walk a continuation, returning its frames (innermost first) as (frame-name .
;; record) pairs. record is a source vector #(ns name file line) for a frame that
;; maps to registered Clojure source, the symbol 'ambiguous for a short name shared
;; across namespaces, or #f for an unmapped-but-named frame (the common case on the
;; open-world eval path, where nothing is registered — the bare frame name is still
;; a useful trace line). Plumbing frames (host spine, eval boundary) and unnamed
;; frames are skipped; raw depth is capped. Each frame carries the line reached
;; INSIDE it, from the R1/R2 marker lookup on its source object — the caller's
;; call site — so a rendered frame points at where it was when the error hit, not
;; where its fn was defined.
(define (jolt-frame-records k)
  ;; read the env at call time, not load time: a built binary runs top-level forms
  ;; at heap-build time, where this would always be unset.
  (let ((debug? (getenv "JOLT_DEBUG_FRAMES")))
   (guard (e (#t '()))
    (let loop ((io (inspect/object k)) (n 0) (acc '()))
      (if (or (not io) (fx>=? n 400))
          (reverse acc)
          (let* ((nm (srcreg-frame-name io))
                 (src (and nm (hashtable-ref source-registry nm #f)))
                 ;; keep a frame that maps, or any named frame that isn't plumbing
                 (keep? (and nm (or src (not (srcreg-plumbing-name? nm)))))
                 ;; the line reached inside this frame (only a mapped frame prints
                 ;; one, so only it pays the marker lookup)
                 (line (and src (srcreg-frame-line-from-source-pair io))))
            (when (and debug? nm)
              (display (string-append "  [frame] " nm (if src " *MAPPED*"
                                                          (if keep? "" " (skipped)"))
                                      (srcreg-frame-source-debug io) "\n")
                       (current-error-port)))
            (loop (guard (e (#t #f)) (io 'link)) (fx+ n 1)
                  (if keep? (cons (srcreg-frame nm src line) acc) acc))))))))

;; --- clj-line lookup for generated .scm offsets ---------------------------------
;;
;; The back end (backend_scheme.clj with-site) emits an inline Chez block comment
;; #|L<clj-line>|# immediately before every traced call site in the generated
;; .scm. A Chez frame's source object carries a byte offset into that file; a
;; backtrace must map it back to the ORIGINAL .clj line the site was emitted
;; from. Returns the line as a fixnum, or #f when no marker precedes the offset.
;;
;; The scan is FORWARD, tracking Scheme lexical state, and builds a sorted table
;; of (marker-start . line) pairs in ONE pass; a lookup is a binary search over
;; that table (the nearest preceding marker), O(log markers) per frame instead
;; of O(file). A backward scan could not tell a real marker from the same bytes
;; inside a user STRING LITERAL — a Clojure string like "#|L999|# oops" is
;; user-controlled, and every offset after it would resolve to a fabricated
;; line. The forward scanner skips:
;;   - "..." string literals, with \ escapes (an escaped \" does not end the
;;     string; \\ then a quote DOES — the backslash escapes exactly one char);
;;   - #| ... |# block comments, which NEST in Chez (a marker is recognized only
;;     when the comment is exactly #|L<digits>|# with an immediate close);
;;   - #\ character literals, so a #\" can't open a string or a #\| start a
;;     comment (defensive: the emitter renders chars as (integer->char N), never
;;     #\);
;;   - ; line comments (the emitter never emits one — a top-level form is one
;;     line, so a ; comment would swallow the rest of it — but they are free to
;;     skip).
;; Deliberately NOT handled (the emitter cannot produce them): #; datum
;; comments, and bar-delimited |symbol| syntax containing #|.
(define jolt-marker-cache-text (make-hashtable string-hash string=?))
(define jolt-marker-cache-file (make-hashtable string-hash string=?))

;; Forward scan -> sorted vector of (start . line) pairs, one per real marker.
(define (jolt-marker-table text)
  (define n (string-length text))
  (define (digit? c) (char<=? #\0 c #\9))
  (define (alpha? c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z)))
  (define (hex-digit? c)
    (or (digit? c) (char<=? #\a c #\f) (char<=? #\A c #\F)))
  ;; Is text[i..] exactly "#|L<digits>|#"?  (line . end) or #f.
  (define (marker-at? i)
    (and (<= (+ i 3) n)
         (char=? (string-ref text i) #\#)
         (char=? (string-ref text (+ i 1)) #\|)
         (char=? (string-ref text (+ i 2)) #\L)
         (let loop ((j (+ i 3)) (acc 0) (digits? #f))
           (cond
             ((and (< j n) (digit? (string-ref text j)))
              (loop (+ j 1) (+ (* acc 10)
                               (- (char->integer (string-ref text j))
                                  (char->integer #\0)))
                    #t))
             ((and digits? (< (+ j 1) n)
                   (char=? (string-ref text j) #\|)
                   (char=? (string-ref text (+ j 1)) #\#))
              (cons acc (+ j 2)))
             (else #f)))))
  (let scan ((i 0) (out '()))
    (cond
      ((>= i n) (list->vector (reverse out)))
      ;; string literal: \" stays inside, \\ does not escape a later quote
      ((char=? (string-ref text i) #\")
       (let skip ((j (+ i 1)))
         (cond
           ((>= j n) (scan n out))
           ((char=? (string-ref text j) #\\)
            (if (< (+ j 1) n) (skip (+ j 2)) (scan n out)))
           ((char=? (string-ref text j) #\") (scan (+ j 1) out))
           (else (skip (+ j 1))))))
      ;; #\ char literal: consume it whole so #\" etc. can't mislead the scan
      ((and (char=? (string-ref text i) #\#)
            (< (+ i 1) n)
            (char=? (string-ref text (+ i 1)) #\\))
       (cond
         ((>= (+ i 2) n) (scan n out))
         ((let ((c (string-ref text (+ i 2))))
            (or (char=? c #\x) (char=? c #\u)))
          ;; hex codepoint: #\x41, #\u0041, #\x(41), #\u(41)
          (if (and (< (+ i 3) n) (char=? (string-ref text (+ i 3)) #\())
              (let inner ((k (+ i 4)))
                (cond
                  ((and (< k n) (hex-digit? (string-ref text k))) (inner (+ k 1)))
                  ((and (< k n) (char=? (string-ref text k) #\))) (scan (+ k 1) out))
                  (else (scan (+ i 3) out))))
              (let skip ((j (+ i 3)))
                (cond ((and (< j n) (hex-digit? (string-ref text j))) (skip (+ j 1)))
                      (else (scan j out))))))
         ((alpha? (string-ref text (+ i 2)))
          ;; named char: #\space, #\newline, ...
          (let skip ((j (+ i 3)))
            (cond ((and (< j n) (alpha? (string-ref text j))) (skip (+ j 1)))
                  (else (scan j out)))))
         (else (scan (+ i 3) out))))
      ;; #| block comment (nests); our markers are exactly such comments
      ((and (char=? (string-ref text i) #\#)
            (< (+ i 1) n)
            (char=? (string-ref text (+ i 1)) #\|))
       (let ((m (marker-at? i)))
         (if m
             (scan (cdr m) (cons (cons i (car m)) out))
             (let skip ((j (+ i 2)) (depth 1))
               (cond
                 ((>= j n) (scan n out))
                 ((and (char=? (string-ref text j) #\#)
                       (< (+ j 1) n)
                       (char=? (string-ref text (+ j 1)) #\|))
                  (skip (+ j 2) (+ depth 1)))
                 ((and (char=? (string-ref text j) #\|)
                       (< (+ j 1) n)
                       (char=? (string-ref text (+ j 1)) #\#))
                  (if (= depth 1) (scan (+ j 2) out) (skip (+ j 2) (- depth 1))))
                 (else (skip (+ j 1) depth)))))))
      ;; ; line comment
      ((char=? (string-ref text i) #\;)
       (let skip ((j (+ i 1)))
         (cond
           ((>= j n) (scan n out))
           ((char=? (string-ref text j) #\newline) (scan (+ j 1) out))
           (else (skip (+ j 1))))))
      (else (scan (+ i 1) out)))))

;; Rightmost marker start <= offset, else #f. Binary search over the sorted
;; table; an offset past the last marker (or past the end of the file) lands on
;; the last marker, matching the old backward scan. An offset exactly AT a
;; marker's start resolves to that marker (its bytes begin there).
(define (jolt-marker-line-from-table table offset)
  (let loop ((lo 0) (hi (- (vector-length table) 1)) (best #f))
    (cond
      ((> lo hi) best)
      (else
       (let ((mid (quotient (+ lo hi) 2)))
         (if (<= (car (vector-ref table mid)) offset)
             (loop (+ mid 1) hi (cdr (vector-ref table mid)))
             (loop lo (- mid 1) best)))))))

(define (jolt-marker-line-at-offset text offset)
  (let ((tbl (hashtable-ref jolt-marker-cache-text text #f)))
    (if tbl
        (jolt-marker-line-from-table tbl offset)
        (let ((tbl (jolt-marker-table text)))
          ;; content-keyed: exact (never stale), and a backtrace resolves many
          ;; frames against the same generated text. Cap at 16 entries so a
          ;; long-lived process can't accumulate every file it ever touched.
          (when (fx>=? (hashtable-size jolt-marker-cache-text) 16)
            (hashtable-clear! jolt-marker-cache-text))
          (hashtable-set! jolt-marker-cache-text text tbl)
          (jolt-marker-line-from-table tbl offset)))))

;; --- eval-path source registry -------------------------------------------------
;; On the eval path (an AOT cache MISS) the emitted Scheme is a transient string:
;; it is gone by the time anything throws. To let a backtrace resolve a frame's
;; (source-name . offset) back to a clj line, compile-eval.ss registers the marker
;; table for the text under a SYNTHETIC source name before eval'ing it. The name
;; is never a filesystem path (jolt-eval-source-name?), so a consumer knows to
;; consult this registry instead of reading a .scm off disk. Populated only when
;; tracing is on; with tracing off the whole block costs nothing.
;;
;; Growth is bounded: jolt-eval-source-max tables, oldest evicted FIFO. A table
;; is one (marker-start . clj-line) pair per traced call site — a few hundred
;; bytes for a typical top-level form — so the registry stays under roughly
;; jolt-eval-source-max * (form size) no matter how long a REPL/nREPL session
;; runs, and the most recent forms (the set a fresh backtrace can mention) are
;; exactly the ones kept.
;;
;; Thread-safety: futures/agents compile on their own threads, so two threads
;; must not draw the same counter value or interleave table inserts. A mutex
;; guards counter increment + insert; that is one acquisition per top-level
;; form, under tracing only, negligible against the analysis+emit already paid.
(define jolt-eval-source-max 4096)
(define jolt-eval-source-counter 0)
(define jolt-eval-source-mutex (make-mutex))
(define jolt-eval-marker-registry (make-hashtable string-hash string=?))
(define jolt-eval-source-queue '())          ; names in insertion order (FIFO)
(define jolt-eval-source-queue-tail '())
(define (jolt-eval-queue-push! name)
  (let ((c (cons name '())))
    (if (null? jolt-eval-source-queue-tail)
        (begin (set! jolt-eval-source-queue c)
               (set! jolt-eval-source-queue-tail c))
        (begin (set-cdr! jolt-eval-source-queue-tail c)
               (set! jolt-eval-source-queue-tail c)))))
(define (jolt-eval-queue-pop!)
  (when (pair? jolt-eval-source-queue)
    (let ((name (car jolt-eval-source-queue)))
      (set! jolt-eval-source-queue (cdr jolt-eval-source-queue))
      (when (null? jolt-eval-source-queue) (set! jolt-eval-source-queue-tail '()))
      name)))
;; Register the marker table for one eval'd Scheme text; returns the synthetic
;; source name to pass make-source-file-descriptor. Once per top-level form.
(define (jolt-register-eval-marker-table! scm)
  (mutex-acquire jolt-eval-source-mutex)
  (let ((name (string-append "jolt-eval-src-"
                             (number->string jolt-eval-source-counter))))
    (set! jolt-eval-source-counter (+ jolt-eval-source-counter 1))
    (when (fx>=? (hashtable-size jolt-eval-marker-registry) jolt-eval-source-max)
      (let ((old (jolt-eval-queue-pop!)))
        (when old (hashtable-delete! jolt-eval-marker-registry old))))
    (hashtable-set! jolt-eval-marker-registry name (jolt-marker-table scm))
    (jolt-eval-queue-push! name)
    (mutex-release jolt-eval-source-mutex)
    name))
;; Resolve an eval-path frame's (name . offset) to a clj line, or #f when the
;; name was evicted / never registered or no marker precedes the offset.
(define (jolt-eval-source-line name offset)
  (let ((tbl (hashtable-ref jolt-eval-marker-registry name #f)))
    (and tbl (jolt-marker-line-from-table tbl offset))))
;; Is this source name a registry key rather than a real file? The distinguisher
;; between "consult the eval registry" and "read a .scm off disk": every name
;; this registry mints is "jolt-eval-src-" followed by decimal digits, and no
;; generated artifact on disk is ever named that.
(define (jolt-eval-source-name? name)
  (and (string? name)
       (let ((n (string-length name)))
         (and (fx>=? n 14)
              (string=? (substring name 0 14) "jolt-eval-src-")
              (let loop ((i 14))
                (or (fx>=? i n)
                    (and (char<=? #\0 (string-ref name i) #\9)
                         (loop (fx+ i 1)))))))))

;; Convenience wrapper for a generated file on disk. Cached per path+mtime: the
;; same .scm serves every frame of a backtrace, so read+scan it once. Whole-
;; second mtime granularity means a file regenerated within the same second can
;; serve a stale table — acceptable on a debug path, never a correctness claim.
(define (jolt-marker-line-in-file path offset)
  (define (read-table)
    (call-with-input-file path
      (lambda (p) (jolt-marker-table (get-string-all p)))))
  (let* ((mtime (time-second (file-modification-time path)))
         (entry (hashtable-ref jolt-marker-cache-file path #f)))
    (unless (and entry (= (car entry) mtime))
      (set! entry (cons mtime (read-table)))
      (hashtable-set! jolt-marker-cache-file path entry))
    (jolt-marker-line-from-table (cdr entry) offset)))

;; Render a list of (frame-name . record) pairs (innermost/deepest first) to a
;; backtrace string. record is a source vector #(ns name file line) -> "ns/name
;; (file:line)", or 'ambiguous / #f -> the bare frame name. A run of the same
;; frame-name collapses to one "name (xN)" line (deep recursion, or a hot fn a
;; loop re-enters), and the number of distinct lines is capped.
;; A frame to render: #(frame-name record own-line). own-line is the line reached
;; INSIDE that frame (#f when unknown), which is what the JVM prints per frame and
;; what a reader needs; the record's own line is where the function was DEFINED and
;; is only the fallback.
(define (srcreg-frame name record line) (vector name record line))
(define (srcreg-frame-nm f) (vector-ref f 0))
(define (srcreg-frame-rec f) (vector-ref f 1))
(define (srcreg-frame-line f) (vector-ref f 2))

(define (jolt-render-recs recs)
  (let ((port (open-output-string)))
    (let loop ((rs recs) (shown 0))
      (if (or (null? rs) (fx>=? shown 30))
          (get-output-string port)
          (let* ((f (car rs)) (frame-name (srcreg-frame-nm f)) (r (srcreg-frame-rec f)))
            ;; count a maximal run of the same frame-name
            (let run ((tail (cdr rs)) (cnt 1))
              (if (and (pair? tail) (string=? (srcreg-frame-nm (car tail)) frame-name))
                  (run (cdr tail) (fx+ cnt 1))
                  (begin
                    (put-string port "    ")
                    (if (vector? r)
                        (let* ((ns (vector-ref r 0)) (nm (vector-ref r 1))
                               (file (vector-ref r 2))
                               ;; the line reached in this frame, else where it was defined
                               (line (or (srcreg-frame-line f) (vector-ref r 3))))
                          (put-string port ns) (put-string port "/") (put-string port nm)
                          (when (string? file)
                            (put-string port " (") (put-string port file)
                            (put-string port ":") (put-string port (number->string line))
                            (put-string port ")")))
                        (put-string port frame-name))   ; 'ambiguous / unmapped: bare name
                    (when (fx>? cnt 1)
                      (put-string port " (x") (put-string port (number->string cnt)) (put-string port ")"))
                    (put-char port #\newline)
                    (loop tail (fx+ shown 1))))))))))

;; The tail-site continuation marks rendered as a backtrace, or #f when tracing is
;; off / no marked frame is live. A mapped frame is kept; else drop plumbing (same
;; rule as the continuation path) so the two sources read consistently.
;; The marks captured at the throw (rt.ss jolt-throw-marks) give one RIB per live
;; marked frame; each rib is #(count buf) of site literals ('("ns/fn" . line)),
;; and every entry carries the line of the tail call IN ITS OWN fn — no caller
;; line shift anywhere. This path (REPL/nREPL via jolt.host/backtrace-string, and
;; the no-continuation fallback in jolt-backtrace-string) renders EVERY live
;; marked frame's chain, innermost first — exact, no returned residue, strictly
;; better than the old bounded-window ring.
(define (jolt-history-backtrace)
  (let* ((marks (jolt-throw-marks))
         (ribs (if marks (continuation-marks->list marks jolt-trace-key) '()))
         (cont-names (let ((h (make-hashtable string-hash string=?))) h))
         (chain (let loop ((ribs ribs) (acc '()))
                  (if (null? ribs)
                      acc
                      (loop (cdr ribs)
                            (append acc (jolt-marks-tail-frames (car ribs) cont-names))))))
         (site (jolt-throw-site))
         (recs (if (jolt-site-splice? site cont-names chain '())
                   (cons (jolt-site-frame site) chain)
                   chain)))
    (and (pair? recs) (jolt-render-recs recs))))

;; Recover TCO-erased frames from the tail-site continuation marks. `rib` is the
;; innermost live rib (continuation-marks-first of the marks captured at the
;; throw), decoded to (qname . own-line) entries, deepest first: the tail chain
;; between the throw and the deepest live frame. `cont-names` is a string-set of
;; the frame names the live continuation already reports. Only entries GENUINELY
;; ABSENT from the continuation are taken — a frame that is live cannot have been
;; TCO-erased, so a mark copy of it is either a duplicate of the continuation or
;; a dead frame's residue, and both must be dropped. NO line shift: each entry
;; carries the line of the tail call IN ITS OWN fn. A rib holds at most 8
;; entries; when more were recorded (count > 8) the oldest count-8 are gone, so
;; render the survivors plus an elision marker.
(define (jolt-marks-tail-frames rib cont-names)
  (let* ((cnt (vector-ref rib 0)) (buf (vector-ref rib 1))
         (n (fxmin cnt 8)))
    (let loop ((k 0) (acc '()))
      (if (fx>=? k n)
          (let ((acc (if (fx>? cnt 8)
                         (cons (srcreg-frame (string-append "(elided "
                                                            (number->string (fx- cnt 8))
                                                            " tail frames)")
                                             #f #f)
                               acc)
                         acc)))
            (reverse acc))
          (let* ((e (vector-ref buf (fxand (fx- (fx- cnt 1) k) 7)))
                 (nm (car e)) (line (cdr e))
                 (src (hashtable-ref source-registry nm #f)))
            (loop (fx+ k 1)
                  (if (and (not (hashtable-ref cont-names nm #f))
                           (or src (not (srcreg-plumbing-name? nm))))
                      (cons (srcreg-frame nm src (and (fixnum? line) (fx>? line 0) line)) acc)
                      acc)))))))

;; The innermost frame, spliced from the vreg site (rt.ss jolt-throw-site) that the
;; throw's own call site stored — the one frame neither the continuation (TCO
;; erased) nor the tail chain (a native-op / throw site records no mark) can name.
;; Rendered innermost-first, before the chain.
(define (jolt-site-frame site)
  (let ((nm (car site)) (line (cdr site)))
    (srcreg-frame nm (hashtable-ref source-registry nm #f)
                  (and (fixnum? line) (fx>? line 0) line))))
;; Anti-dup belt plus the R2 staleness validator (bead jolt-knn8). Splice the
;; site IFF (1) its name is absent from the live continuation (a live frame
;; cannot have been TCO-erased); (2) it differs from the chain's deepest entry
;; (when they agree, the chain already names the frame); and (3) the compile-
;; time callsite table AGREES: only tail sites write the site vreg now, so the
;; raise-time stash can be a returned chain's residue — the pair is trusted
;; only when the innermost live context (the chain's deepest entry, else the
;; innermost continuation frame) statically calls the fn the pair names. A
;; site the table has no entry for (a dynamic callee) falls back to the belt
;; alone — bounded, and strictly no worse than R1.
(define (jolt-site-splice? site cont-names chain cont)
  (and (pair? site)
       (let ((nm (car site)))
         (and (not (hashtable-ref cont-names nm #f))
              (or (null? chain)
                  (not (string=? (srcreg-frame-nm (car chain)) nm)))
              ;; Two candidate contexts, because either may be the innermost:
              ;; the chain's deepest entry (the marked frame's last tail site)
              ;; or the innermost continuation frame (deeper when the throw
              ;; left live frames, e.g. a non-tail call chain below the marked
              ;; frame). ACCEPT if any registered context calls nm, or if any
              ;; context is unregistered (a dynamic site — no evidence);
              ;; REJECT only when every known context disagrees. A rejected
              ;; pair is exactly a returned tail site's residue.
              (let ((ctxs (append (if (pair? chain) (list (car chain)) '())
                                  (if (pair? cont) (list (car cont)) '()))))
                (or (null? ctxs)
                    (let check ((cs ctxs) (any-unknown #f))
                      (if (null? cs)
                          any-unknown
                          (let ((expected (jolt-callsite-callees
                                           (srcreg-frame-nm (car cs))
                                           (srcreg-frame-line (car cs)))))
                            (cond
                              ((not expected) (check (cdr cs) #t))
                              ((member nm expected) #t)
                              (else (check (cdr cs) any-unknown))))))))))))

;; Where the tail chain belongs among the continuation frames. The chain's
;; frames run OUTSIDE the fn the chain's deepest site tail-called; when the
;; throw left that fn's frame live (a non-tail throw inside it), the
;; continuation reports it — and any frames deeper than it — ABOVE the chain.
;; Splice the chain after the OUTERMOST cont frame named by the deepest site's
;; static callee (jolt-callsite-callee), so a caller can never render above
;; its callee. When the callee is unknown or absent from the continuation
;; (the throw was at the chain fn's tail — the common case), the chain goes on
;; top as before. Fixes the app.sitestale-shaped ordering the R1 fixtures never
;; exercised: their throws were all in tail position.
(define (jolt-splice-chain chain cont cont-names)
  (if (null? chain)
      cont
      (let ((es (jolt-callsite-callees (srcreg-frame-nm (car chain))
                                       (srcreg-frame-line (car chain)))))
        (if (and es (exists (lambda (x) (hashtable-ref cont-names x #f)) es))
            (let ((last (let scan ((cs cont) (i 0) (last -1))
                          (if (null? cs)
                              last
                              (scan (cdr cs) (fx+ i 1)
                                    (if (member (srcreg-frame-nm (car cs)) es) i last))))))
              (if (fx<? last 0)
                  (append chain cont)
                  (let split ((k 0) (cs cont) (acc '()))
                    (if (fx>? k last)
                        (append (reverse acc) chain cs)
                        (split (fx+ k 1) (cdr cs) (cons (car cs) acc))))))
            (append chain cont)))))

;; Multi-line backtrace for an uncaught value, built from the CONTINUATION with
;; the tail-site marks consulted only for frames TCO erased:
;;   1. The innermost frame from the vreg site (jolt-throw-site), when it survives
;;      the anti-dup belt (not in the continuation, and not the chain's deepest
;;      entry — R1 addendum).
;;   2. The innermost live rib (continuation-marks-first of the marks captured at
;;      the throw) — the tail chain between the throw and the deepest live frame.
;;      Only entries absent from the continuation are spliced in, so a dead frame's
;;      residue cannot appear.
;;   3. The live continuation (jolt-frame-records) — the exact non-tail spine,
;;      each frame at the line of the call that created it.
;; No continuation (a host condition raised outside jolt-throw): fall back to the
;; whole marked chain as before, since there is no exact source to prefer. #f when
;; neither source yields a frame (the caller then prints just the location).
(define (jolt-backtrace-string v)
  (let ((k (jolt-error-continuation v)))
    (if (not k)
        (jolt-history-backtrace)
        (let* ((cont (jolt-frame-records k))
               (cont-names (let ((h (make-hashtable string-hash string=?)))
                             (for-each (lambda (f)
                                         (hashtable-set! h (srcreg-frame-nm f) #t))
                                       cont)
                             h))
               (marks (jolt-throw-marks))
               (rib (and marks (continuation-marks-first marks jolt-trace-key)))
               (chain (if (and rib (vector? rib))
                          (jolt-marks-tail-frames rib cont-names)
                          '()))
               (site (jolt-throw-site))
               (recs (let ((body (jolt-splice-chain chain cont cont-names)))
                       (if (jolt-site-splice? site cont-names chain cont)
                           (cons (jolt-site-frame site) body)
                           body))))
          (and (pair? recs) (jolt-render-recs recs))))))

;; Exposed for the REPL / nREPL error paths, which catch errors themselves instead
;; of going through the uncaught reporter. Returns the "  trace:\n<frames>" block
;; from the tail-frame HISTORY only — the live continuation in a REPL is just the
;; REPL's own machinery — or nil when tracing is off (so a caller can when-let).
(def-var! "jolt.host" "backtrace-string"
  (lambda ()
    (let ((bt (jolt-history-backtrace)))
      (if bt (string-append "  trace:\n" bt) jolt-nil))))

;; Render an uncaught jolt throw (any value, not just a Chez condition) to a port:
;; an ex-info shows its message + ex-data (+ a host cause); anything else is
;; pr-str'd. Shared by the cli (cli.ss) and a built binary's launcher (build.ss).
(define (jolt-render-throwable raw port)
  (let ((v (jolt-unwrap-throw raw)))
    (if (jolt-ex-info-record? v)
        (begin
          (display "Unhandled exception: " port)
          (display (jolt-str-render-one (jolt-ex-info-record-message v)) port)
          (newline port)
          (let ((data (jolt-ex-info-record-data v)))
            (unless (jolt-nil? data)
              (display "  ex-data: " port) (display (jolt-pr-str data) port) (newline port)))
          (let ((cause (jolt-ex-info-record-cause v)))
            (when (condition? cause)
              (display "  cause: " port)
              (display (with-output-to-string (lambda () (display-condition cause))) port)
              (newline port))))
        (begin
          (display "Unhandled exception: " port)
          (display (if (condition? v) (with-output-to-string (lambda () (display-condition v))) (jolt-pr-str v)) port)
          (newline port)))))

;; Render the throwable, then its Clojure backtrace when one maps. The caller adds
;; any top-level source location (the runtime cli does; a built binary has none).
(define (jolt-report-throwable v port)
  (jolt-render-throwable v port)
  (let ((bt (jolt-backtrace-string v)))
    (when bt (display "  trace:\n" port) (display bt port))))

;; ---- #error print form (pr/pr-str) and toString (str) for ex-info records ----

;; Walk the cause chain of a jolt-ex-info-record, returning a list of cause entries
;; (innermost first). Each entry is a vector [class-name message data].
(define (jolt-error-via-chain rec)
  (let loop ((r rec) (acc '()))
    (let ((class-name (jolt-ex-info-record-class-name r))
          (msg (jolt-ex-info-record-message r))
          (data (jolt-ex-info-record-data r))
          (cause (jolt-ex-info-record-cause r)))
      (let ((new-acc (cons (vector class-name msg data) acc)))
        (if (jolt-ex-info-record? cause)
            (loop cause new-acc)
            (reverse new-acc))))))

;; Render a single :via entry as a string map.
(define (jolt-error-render-via-entry entry)
  (let* ((class-name (vector-ref entry 0))
         (msg (vector-ref entry 1))
         (data (vector-ref entry 2))
         (type-str (jolt-pr-str (jolt-symbol #f class-name)))
         (msg-str (jolt-pr-readable msg))
         (has-data (not (jolt-nil? data))))
    (string-append " {:type " type-str
                   " :message " msg-str
                   (if has-data (string-append " :data " (jolt-pr-readable data)) "")
                   " :at nil}")))

;; Render the :via chain list.
(define (jolt-error-render-via chain)
  (string-append "[" (jolt-str-join (map jolt-error-render-via-entry chain)) "]"))

;; #error print form for jolt-ex-info-records (pr/pr-str). Matches JVM shape:
;; #error {:cause <root-msg> :data {...} :via [{...}] :trace [[...]...]}
;; :trace is always [] here — frame records are only accessible during a throw.
(register-pr-arm! jolt-ex-info-record?
  (lambda (x)
    (let* ((chain (jolt-error-via-chain x))
           (root-cause (vector-ref (car (reverse chain)) 1))
           (data (jolt-ex-info-record-data x))
           (via-str (jolt-error-render-via chain)))
      (string-append "#error {\n :cause " (jolt-pr-readable root-cause)
                     (if (jolt-nil? data) "" (string-append "\n :data " (jolt-pr-readable data)))
                     "\n :via " via-str
                     "\n :trace []"
                     "}"))))

;; toString (str/print) for ex-info records: "ClassName: message data"
(register-str-render! jolt-ex-info-record?
  (lambda (x)
    (let* ((class-name (jolt-ex-info-record-class-name x))
           (msg (jolt-ex-info-record-message x))
           (data (jolt-ex-info-record-data x)))
      (string-append class-name ": " (jolt-str-render-one msg)
                     (if (jolt-nil? data) ""
                         (string-append " " (jolt-pr-str data)))))))

;; count on ex-info / host throwable records throws UnsupportedOperationException
;; matching JVM: "count not supported on this type: <SimpleClassName>"
(register-count-arm! jolt-ex-info-record?
  (lambda (coll)
    (jolt-throw (jolt-host-throwable "java.lang.UnsupportedOperationException"
                   (string-append "count not supported on this type: "
                                  (simple-class-name (jolt-ex-info-record-class-name coll)))))))
