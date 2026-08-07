;; portability-check.ss — PSL R1: Chez-ism census + portability lint (allowlist mode).
;;
;; Reads every handwritten host .ss file (host/chez/*.ss and host/chez/java/*.ss,
;; excluding seed/ and stub/) AS DATA under the build's Chez, walks each datum
;; collecting:
;;   - every symbol in OPERATOR position (car of a pair), and
;;   - every blocklisted identifier in ANY position (thread parameters, FFI type
;;     tokens and the like are passed as values, not called).
;; The matched identifiers are checked against host/chez/portability-blocklist.txt
;; and host/chez/portability-allowlist.txt. Reading Scheme as text would lie
;; (comments, strings, #|...|# blocks); reading it as data does not.
;;
;; Modes (exactly one):
;;   (default)        gate — exit 1 on a hit the file's allowlist does not cover,
;;                    and on any allowlist line whose hit no longer exists (stale;
;;                    the allowlist only ever shrinks truthfully)
;;   --regen          rewrite portability-allowlist.txt from current hits
;;   --census         emit .dirge/psl-census.md (per-tier per-file inventory)
;;   --dump-operators print "symbol<tab>count" for every operator-position symbol
;;                    across the scan, descending (dev aid: the blocklist should
;;                    absorb every genuine Chez-ism this shows)
;;
;; The default reader already accepts the Chez lexical syntax these files use:
;; #! directives, #; datum comments, nested #|...|# blocks, #vfx(...), #& boxes
;; and #3%/#% unsafe-primitive wrappers (read as ($primitive [level] name) pairs,
;; whose primitive name is recovered as an operator; $primitive itself is
;; blocklisted in the chez-unsafe tier, so unsafe-primitive use shows up in the
;; census). A file that fails to read is a LINT HOLE, not something to skip: it
;; is reported by name and the check exits non-zero. Binding positions
;; (lambda/let/define/do/case-lambda params, quote bodies, set! targets, case
;; clause datums) are walked past so a local named `format` is not mistaken for
;; a call to Chez format; parameterize/fluid-let params ARE walked, because they
;; are passed as values, not bound; syntax-rules templates are walked for hits
;; only. The checker scans ITSELF like any other host file (its printf/format/
;; sort use is allowlisted like any other current reality) — self-referential
;; linting is the honest state, and keeps scanned-N equal to the ls count.
(import (chezscheme))

(define excluded-dirs '("seed" "stub"))

;; ---------------------------------------------------------------------------
;; small string helpers (no string-prefix?/suffix?/trim — not all builds export)
;; ---------------------------------------------------------------------------

(define (starts-with? s p)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

(define (has-suffix? s p)
  (let ((ls (string-length s)) (lp (string-length p)))
    (and (>= ls lp) (string=? (substring s (- ls lp) ls) p))))

(define (char-ws? c)
  (or (char=? c #\space) (char=? c #\tab) (char=? c #\newline)
      (char=? c #\return) (char=? c #\page)))

(define (string->tokens s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (cond
        ((>= i n) (reverse acc))
        ((char-ws? (string-ref s i)) (loop (+ i 1) acc))
        (else
         (let scan ((j i))
           (if (and (< j n) (not (char-ws? (string-ref s j))))
               (scan (+ j 1))
               (loop j (cons (substring s i j) acc)))))))))

(define (strip-comment s)
  (let ((n (string-length s)))
    (let loop ((i 0))
      (cond
        ((>= i n) s)
        ((or (char=? (string-ref s i) #\#) (char=? (string-ref s i) #\;))
         (substring s 0 i))
        (else (loop (+ i 1)))))))

(define (read-lines path)
  (let ((p (open-input-file path)))
    (let loop ((acc '()))
      (let ((l (get-line p)))
        (if (eof-object? l)
            (begin (close-port p) (reverse acc))
            (loop (cons l acc)))))))

;; ---------------------------------------------------------------------------
;; paths resolve from the script's own location, so the checker works from any
;; CWD (the Makefile target and the sh wrapper run it from the repo root, but
;; --regen/--census must not depend on that)
;; ---------------------------------------------------------------------------

(define (script-arg cl)
  (let loop ((l cl))
    (cond ((null? l) #f)
          ((string=? (car l) "--script") (and (pair? (cdr l)) (cadr l)))
          (else (loop (cdr l))))))

(define script-path
  (or (script-arg (command-line)) "host/chez/portability-check.ss"))

(define host-dir
  (let ((n (string-length script-path))
        (m (string-length "portability-check.ss")))
    (substring script-path 0 (- n m))))

(define repo-root
  (if (has-suffix? host-dir "/host/chez")
      (substring host-dir 0 (- (string-length host-dir)
                               (string-length "/host/chez")))
      ""))

(define (rooted p)
  (if (string=? repo-root "") p (string-append repo-root "/" p)))

(define scope-root (rooted "host/chez"))
(define blocklist-file (rooted "host/chez/portability-blocklist.txt"))
(define allowlist-file (rooted "host/chez/portability-allowlist.txt"))
(define census-file (rooted ".dirge/psl-census.md"))

(define target-owned-files
  ;; A target-owned file is a per-target implementation a port REPLACES rather
  ;; than migrates: today the adapter runtime (the sanctioned home of the
  ;; forbidden names) and the Chez-tuned hash implementation. PSL R10 strict
  ;; lint: the allowlist may ONLY name these files. A real forbidden-name use
  ;; in any other file is a signal to route through the adapter, never to
  ;; allowlist.
  '("host/chez/scheme-adapter-runtime.ss"
    "host/chez/hasheq.ss"))

;; ---------------------------------------------------------------------------
;; blocklist: identifier symbol -> tier name (tier headers are "# tier: NAME")
;; ---------------------------------------------------------------------------

(define blocklist (make-eq-hashtable))
(define tier-order '())

(define (tier-header? line)
  (let ((toks (string->tokens line)))
    (and (>= (length toks) 3)
         (string=? (car toks) "#")
         (string=? (cadr toks) "tier:"))))

(define (tier-header-name line)
  (caddr (string->tokens line)))

(define (read-blocklist path)
  (for-each
    (lambda (line)
      (cond
        ((tier-header? line)
         (let ((name (tier-header-name line)))
           (unless (member name tier-order)
             (set! tier-order (append tier-order (list name))))))
        (else
         (let* ((t (strip-comment line))
                (toks (string->tokens t)))
           (cond
             ((null? toks) #f)
             ((or (starts-with? t "#") (starts-with? t ";")) #f)
             ((null? tier-order)
              (error 'portability-check
                     "identifier before any # tier: header" line))
             (else
              (hashtable-set! blocklist (string->symbol (car toks))
                              (car (reverse tier-order)))))))))
    (read-lines path)))

(define (blocklist-tier sym)
  (hashtable-ref blocklist sym #f))

(define (srfi-tier? tier) (and tier (starts-with? tier "srfi-")))

;; ---------------------------------------------------------------------------
;; contract: identifiers every target's adapter must provide (CONTRACT.txt).
;; Contract names are allowed everywhere with NO allowlist lines, but still
;; count in the census under "contract:<tier>". The contract file uses the
;; same "# tier: NAME" format as the blocklist.
;; ---------------------------------------------------------------------------

(define contract-file (rooted "host/scheme-adapter/CONTRACT.txt"))
(define contract (make-eq-hashtable))
(define contract-tiers '())

(define (contract-arg cl)
  (let loop ((l cl))
    (cond ((null? l) #f)
          ((and (string=? (car l) "--contract") (pair? (cdr l))) (cadr l))
          (else (loop (cdr l))))))

(define (read-contract path)
  (for-each
    (lambda (line)
      (cond
        ((tier-header? line)
         (let ((name (tier-header-name line)))
           (unless (member name contract-tiers)
             (set! contract-tiers (append contract-tiers (list name))))))
        (else
         (let* ((t (strip-comment line))
                (toks (string->tokens t)))
           (cond
             ((null? toks) #f)
             ((or (starts-with? t "#") (starts-with? t ";")) #f)
             ((null? contract-tiers)
              (error 'portability-check
                     "contract identifier before any # tier: header" line))
             (else
              (hashtable-set! contract
                              (string->symbol (car toks))
                              (car (reverse contract-tiers)))))))
        ))
    (read-lines path)))

(define (contract-tier sym)
  (let ((t (hashtable-ref contract sym #f)))
    (and t (string-append "contract:" t))))

(define (tier-of sym)
  (or (contract-tier sym) (blocklist-tier sym)))

(define (contract-tier? tier)
  (and tier (starts-with? tier "contract:")))

(define (census-tiers)
  (append (map (lambda (t) (string-append "contract:" t)) contract-tiers)
          tier-order))

(define (check-contract-overlap)
  (for-each
    (lambda (sym)
      (when (blocklist-tier sym)
        (error 'portability-check
               "name in both CONTRACT.txt and the blocklist:" sym)))
    (vector->list (hashtable-keys contract))))

;; ---------------------------------------------------------------------------
;; allowlist: list of (file-string . identifier-symbol)
;; ---------------------------------------------------------------------------

(define (read-allowlist path)
  (let loop ((lines (read-lines path)) (acc '()))
    (if (null? lines)
        (reverse acc)
        (let ((toks (string->tokens (strip-comment (car lines)))))
          (loop (cdr lines)
                (if (and (= (length toks) 2)
                         (has-suffix? (car toks) ".ss"))
                    (cons (cons (car toks) (string->symbol (cadr toks))) acc)
                    acc))))))

;; ---------------------------------------------------------------------------
;; file discovery: *.ss under scope-root, excluding seed/ and stub/
;; ---------------------------------------------------------------------------

(define (scan-dir d acc)
  (for-each
    (lambda (e)
      (unless (member e excluded-dirs)
        (let ((p (string-append d "/" e)))
          (cond
            ((file-directory? p) (set! acc (scan-dir p acc)))
            ((has-suffix? e ".ss") (set! acc (cons p acc)))
            (else #f)))))
    (directory-list d))
  acc)

(define (find-files)
  (sort-list (scan-dir scope-root '()) string<?))

;; Chez's sort takes (sort predicate list); this wrapper keeps the call sites'
;; (sort-list lst predicate) shape while passing the comparator first to sort.
(define (sort-list lst cmp)
  (sort cmp lst))

;; ---------------------------------------------------------------------------
;; data walker
;; ---------------------------------------------------------------------------

(define (make-counter) (make-eq-hashtable))
(define (bump! t k) (hashtable-set! t k (+ 1 (hashtable-ref t k 0))))

(define (counter->alist t)
  (let ((ks (hashtable-keys t)))
    (map (lambda (k) (cons k (hashtable-ref t k 0))) (vector->list ks))))

(define (walk-bodies body ops hits)
  (for-each (lambda (x) (walk x ops hits)) body))

(define (walk-bindings bindings ops hits)
  (for-each (lambda (b)
              (when (and (pair? b) (pair? (cdr b)))
                (walk (cadr b) ops hits)))
            bindings))

;; (let ((v i) ...) body ...) or named (let name ((v i) ...) body ...);
;; also let-values, whose binding shape is ((formals expr) ...).
(define (walk-let d ops hits)
  (let* ((named (symbol? (cadr d)))
         (bindings (if named (caddr d) (cadr d)))
         (body (if named (cdddr d) (cddr d))))
    (walk-bindings bindings ops hits)
    (walk-bodies body ops hits)))

(define (walk-do d ops hits)
  ;; (do ((v i s) ...) (test r ...) body ...) — walk init AND step; the test
  ;; clause is walked as a datum (its (exit ...) etc. are real calls).
  (for-each
    (lambda (b)
      (when (and (pair? b) (pair? (cdr b)))
        (walk (cadr b) ops hits)
        (when (pair? (cddr b)) (walk (caddr b) ops hits))))
    (cadr d))
  (when (pair? (cdr d)) (walk (caddr d) ops hits))
  (walk-bodies (cdddr d) ops hits))

(define (walk-pair d ops hits)
  (let ((h (car d)))
    (cond
      ((eq? h 'quote) #f)
      ((memq h '(lambda named-lambda)) (walk-bodies (cddr d) ops hits))
      ((eq? h 'case-lambda)
       (for-each (lambda (cl) (walk-bodies (cdr cl) ops hits)) (cdr d)))
      ((memq h '(let let* letrec letrec* let-values let*-values))
       (walk-let d ops hits))
      ((eq? h 'do) (walk-do d ops hits))
      ((memq h '(define define-syntax))
       (if (and (pair? (cdr d)) (pair? (cadr d)))
           (walk-bodies (cddr d) ops hits)
           (walk-bodies (cdr d) ops hits)))
      ((memq h '(define-record-type define-condition-type))
       (walk-bodies (cdr d) ops hits))
      ((eq? h 'define-values) (walk-bodies (cddr d) ops hits))
      ((memq h '(parameterize fluid-let fluid-let*))
       (walk-bindings (cadr d) ops hits)
       (walk-bodies (cddr d) ops hits))
      ((eq? h 'set!) (when (pair? (cdr d)) (walk (caddr d) ops hits)))
      ((eq? h 'rec) (walk-bodies (cdr d) ops hits))
      ((eq? h 'case)
       (walk (cadr d) ops hits)
       (for-each (lambda (cl) (walk-bodies (cdr cl) ops hits)) (cddr d)))
      ((eq? h 'syntax-rules)
       ;; macro templates are data, but blocklisted literals inside them are
       ;; real Chez-isms (hasheq.ss's u32 macro wraps #3%bitwise-and) — scan
       ;; each rule's template for HITS only, skipping ops-bumping so pattern
       ;; variables don't pollute the operator census
       (for-each
         (lambda (cl)
           (when (and (pair? cl) (pair? (cdr cl)))
             (walk-hits-only (cadr cl) hits)))
         (cddr d)))
      (else
       (when (symbol? h)
         (bump! ops h)
         (let ((tier (tier-of h)))
           (when tier (bump! hits h))))
       (when (and (eq? h '$primitive) (pair? (cdr d)))
         (let ((last (let tail ((l (cdr d)))
                       (if (null? (cdr l)) (car l) (tail (cdr l))))))
           (when (symbol? last) (bump! ops last))))
       ;; walk each argument as a datum (tolerating dotted tails) — arguments
       ;; are VALUE positions, so a symbol argument is hits-checked but never
       ;; ops-bumped as if it were an operator
       (let loop ((l (cdr d)))
         (unless (null? l)
           (walk (if (pair? l) (car l) l) ops hits)
           (when (pair? l) (loop (cdr l)))))
       (when (pair? h) (walk h ops hits))))))

(define (walk d ops hits)
  (cond
    ((symbol? d)
     (let ((tier (tier-of d)))
       (when tier (bump! hits d))))
    ((pair? d) (walk-pair d ops hits))
    ((vector? d) (vector-for-each (lambda (x) (walk x ops hits)) d))
    ((box? d) (walk (unbox d) ops hits))
    (else #f)))

;; hits-only walk: no operator-position collection, used inside macro templates
;; (syntax-rules) where pattern variables would pollute the operator census.
(define (walk-hits-only d hits)
  (cond
    ((symbol? d)
     (let ((tier (tier-of d)))
       (when tier (bump! hits d))))
    ((pair? d)
     (walk-hits-only (car d) hits)
     (let loop ((l (cdr d)))
       (unless (null? l)
         (walk-hits-only (if (pair? l) (car l) l) hits)
         (when (pair? l) (loop (cdr l))))))
    ((vector? d) (vector-for-each (lambda (x) (walk-hits-only x hits)) d))
    ((box? d) (walk-hits-only (unbox d) hits))
    (else #f)))

;; ---------------------------------------------------------------------------
;; scanning
;; ---------------------------------------------------------------------------

(define (read-datums path)
  (let ((p (open-input-file path)))
    (let loop ((acc '()))
      (let ((x (read p)))
        (if (eof-object? x)
            (begin (close-port p) (reverse acc))
            (loop (cons x acc)))))))

;; scan one file -> (ops-alist . hits-alist); entries are (identifier . count)
(define (scan-file path)
  (let ((ops (make-counter)) (hits (make-counter)))
    (for-each (lambda (d) (walk d ops hits)) (read-datums path))
    (cons (counter->alist ops) (counter->alist hits))))

;; scan all files -> (results . errors); result entry = (file ops hits)
(define (scan-all files)
  (let loop ((files files) (acc '()) (errors '()))
    (if (null? files)
        (cons (reverse acc) (reverse errors))
        (let ((f (car files)))
          (guard (e [#t (loop (cdr files) acc (cons (list f (condition-message e)) errors))])
            (let ((r (scan-file f)))
              (loop (cdr files) (cons (list f (car r) (cdr r)) acc) errors)))))))

;; ---------------------------------------------------------------------------
;; gate
;; ---------------------------------------------------------------------------

(define (hits-of file results)
  (let ((entry (assoc file results)))
    (if entry (caddr entry) '())))

;; an allowlist line (file-string . identifier-symbol) covers a hit exactly when
;; both match
(define (covered-by-allowlist? file id allow)
  (let loop ((l allow))
    (cond
      ((null? l) #f)
      ((and (string=? (car (car l)) file)
            (eq? (cdr (car l)) id))
       #t)
      (else (loop (cdr l))))))

(define (not-target-owned-files lines)
  ;; Allowlist lines whose file is not target-owned. The rule is STRUCTURAL:
  ;; it fires even when the line's hit is real, because a real forbidden-name
  ;; use in a normal file is exactly what must be routed through the adapter.
  (let loop ((l lines) (bad '()))
    (cond
      ((null? l) (reverse bad))
      ((member (car (car l)) target-owned-files) (loop (cdr l) bad))
      (else (loop (cdr l) (cons (car (car l)) bad))))))

(define (run-gate results errors)
  (let ((allow (read-allowlist allowlist-file)))
    (define fail 0)
    (define stale 0)
    ;; every non-srfi-tier hit (file . id) must be covered by an allowlist line;
    ;; srfi-portable hits are wholesale-allowed (see the blocklist header)
    (for-each
      (lambda (r)
        (let ((file (car r)))
          (for-each
            (lambda (hit)
              (let ((id (car hit)))
                (unless (or (contract-tier? (tier-of id))
                            (srfi-tier? (tier-of id))
                            (covered-by-allowlist? file id allow))
                  (printf "  ~a:~a\n" file id)
                  (set! fail (+ fail 1)))))
            (caddr r))))
      results)
    (for-each
      (lambda (line)
        (unless (assq (cdr line) (hits-of (car line) results))
          (printf "  STALE ~a ~a\n" (car line) (cdr line))
          (set! stale (+ stale 1))))
      allow)
    ;; STRICT LINT (PSL R10): the allowlist may only name target-owned files.
    ;; This fails STRUCTURALLY — a real hit in a non-target-owned file is
    ;; exactly what must be routed through the adapter, not allowlisted.
    (for-each
      (lambda (f)
        (printf "  NOT-TARGET-OWNED ~a: not target-owned; route through the adapter instead of allowlisting\n" f)
        (set! fail (+ fail 1)))
      (not-target-owned-files allow))
    (for-each (lambda (e) (printf "  READ-ERROR ~a: ~a\n" (car e) (cadr e))) errors)
    (printf "portability check: scanned ~a files\n" (length results))
    (if (and (= fail 0) (= stale 0) (null? errors))
        (begin (printf "portability check: passed\n") 0)
        (begin (printf "portability check: FAILED\n") 1))))

;; ---------------------------------------------------------------------------
;; regen: rewrite the allowlist from current hits (srfi-portable is wholesale-
;; allowed, so its hits never get allowlist lines)
;; ---------------------------------------------------------------------------

(define (write-allowlist rows)
  (let ((p (open-output-file allowlist-file '(replace))))
    (display
      (string-append
        "# host/chez/portability-allowlist.txt — generated file, do not hand-edit.\n"
        "# Regenerate with: sh host/chez/portability-check.sh --regen\n"
        "# Lines: <file> <identifier>. A line whose hit disappears is STALE and fails the gate.\n"
        "# srfi-portable tier hits and CONTRACT names are never listed here.\n")
      p)
    (for-each
      (lambda (row)
        (display (car row) p)
        (display " " p)
        (display (symbol->string (cadr row)) p)
        (newline p))
      rows)
    (close-port p)))

(define (run-regen results errors)
  (define rows '())
  (for-each
    (lambda (r)
      (for-each
        (lambda (hit)
          (let* ((id (car hit)) (tier (tier-of id)))
            (unless (or (contract-tier? tier) (srfi-tier? tier))
              (set! rows (cons (list (car r) id) rows)))))
        (caddr r)))
    results)
  (let ((sorted (sort-list rows
                      (lambda (a b)
                        (or (string<? (car a) (car b))
                            (and (string=? (car a) (car b))
                                 (string<? (symbol->string (cadr a))
                                           (symbol->string (cadr b)))))))))
    (let ((bad (not-target-owned-files sorted)))
      (if (null? bad)
          (begin
            (write-allowlist sorted)
            (printf "portability check: regenerated ~a lines\n" (length sorted))
            (printf "portability check: scanned ~a files\n" (length results))
            (for-each (lambda (e) (printf "  READ-ERROR ~a: ~a\n" (car e) (cadr e))) errors)
            (if (null? errors) 0 1))
          (begin
            (for-each
              (lambda (f)
                (printf "  NOT-TARGET-OWNED ~a: not target-owned; route through the adapter instead of allowlisting\n" f))
              bad)
            (printf "portability check: regen aborted — allowlist may only name target-owned files\n")
            1)))))

;; ---------------------------------------------------------------------------
;; census: emit .dirge/psl-census.md
;; ---------------------------------------------------------------------------

(define (hits-total hits)
  (let loop ((l hits) (n 0))
    (if (null? l) n (loop (cdr l) (+ n (cdar l))))))

(define (hits-in-tier hits tier)
  (filter (lambda (h) (string=? (tier-of (car h)) tier)) hits))

(define (ids-cell ids)
  (let loop ((l ids) (acc '()))
    (if (null? l)
        (apply string-append (reverse acc))
        (loop (cdr l) (cons (format "~a (~a), " (car (car l)) (cdr (car l))) acc)))))

(define (write-tier-table p tier rows)
  (format p "\n## tier: ~a\n\n" tier)
  (display "| file | identifiers (count) | total |\n" p)
  (display "| --- | --- | --- |\n" p)
  (for-each
    (lambda (r)
      (let* ((file (car r))
             (ids (sort-list (hits-in-tier (caddr r) tier)
                        (lambda (a b)
                          (or (> (cdr a) (cdr b))
                              (and (= (cdr a) (cdr b))
                                   (string<? (symbol->string (car a))
                                             (symbol->string (car b))))))))
             (total (hits-total ids)))
        (format p "| ~a | ~a | ~a |\n" file (ids-cell ids) total)))
    (sort-list rows
          (lambda (a b)
            (let ((ta (hits-total (caddr a)))
                  (tb (hits-total (caddr b))))
              (or (> ta tb)
                  (and (= ta tb) (string<? (car a) (car b)))))))))

(define (write-census results errors)
  (let* ((per-tier (map (lambda (tier)
                          (cons tier
                                (filter (lambda (r)
                                          (pair? (hits-in-tier (caddr r) tier)))
                                        results)))
                        (census-tiers)))
         (tier-totals (map (lambda (tt)
                             (cons (car tt)
                                   (let loop ((rs (cdr tt)) (n 0))
                                     (if (null? rs)
                                         n
                                         (loop (cdr rs)
                                               (+ n (hits-total (hits-in-tier (caddr (car rs)) (car tt)))))))))
                           per-tier))
         (grand-total (let loop ((tt tier-totals) (n 0))
                         (if (null? tt) n (loop (cdr tt) (+ n (cdr (car tt)))))))
         (file-totals (sort-list (map (lambda (r) (cons (car r) (hits-total (caddr r))))
                                 results)
                            (lambda (a b)
                              (or (> (cdr a) (cdr b))
                                  (and (= (cdr a) (cdr b))
                                       (string<? (car a) (car b))))))))
    (let ((p (open-output-file census-file '(replace))))
      (display
        (string-append
          "# PSL Chez-ism census\n\n"
          "Regenerated file — do not hand-edit. Regenerate from the repo root with\n\n"
          "    sh host/chez/portability-check.sh --census\n"
          "    (or: make census)\n\n"
          "Reads every handwritten host `.ss` (`host/chez/*.ss` + `host/chez/java/*.ss`,\n"
          "excluding `seed/` and `stub/`) as data, collects every operator-position symbol\n"
          "plus every blocklisted or CONTRACT-listed identifier in any position, and counts\n"
          "those matching the blocklist or `host/scheme-adapter/CONTRACT.txt`. This is the\n"
          "work-list for rounds R2-R9; each round shrinks the allowlist and this census\n"
          "together.\n\n")
        p)
      (format p "Scanned ~a files; ~a blocklisted identifiers in ~a tiers; ~a contract identifiers in ~a tiers; ~a total hits.\n\n"
              (length results) (hashtable-size blocklist) (length tier-order)
              (hashtable-size contract) (length contract-tiers) grand-total)
      (display "## Hits by tier\n\n" p)
      (for-each
        (lambda (tt)
          (let ((nfiles (length (cdr (assoc (car tt) per-tier)))))
            (format p "- ~a: ~a hits (~a file~a)\n" (car tt) (cdr tt) nfiles
                    (if (= nfiles 1) "" "s"))))
        tier-totals)
      (display "\n## Top-5 files by hit count\n\n" p)
      (let loop ((l file-totals) (n 1))
        (when (and (pair? l) (<= n 5))
          (format p "~a. ~a — ~a\n" n (caar l) (cdar l))
          (loop (cdr l) (+ n 1))))
      (for-each (lambda (tt)
                  (write-tier-table p (car tt) (cdr (assoc (car tt) per-tier))))
                tier-totals)
      (close-port p))
    (for-each (lambda (e) (printf "  READ-ERROR ~a: ~a\n" (car e) (cadr e))) errors)
    (printf "portability check: census written to ~a\n" census-file)
    (printf "portability check: scanned ~a files\n" (length results))
    (if (null? errors) 0 1)))
(define (run-dump-operators results)
  (let ((agg (make-counter)))
    (for-each
      (lambda (r)
        (for-each (lambda (h) (bump! agg (car h)))
                  (cadr r)))
      results)
    (for-each
      (lambda (h) (printf "~a\t~a\n" (car h) (cdr h)))
      (sort-list (counter->alist agg)
            (lambda (a b)
              (or (> (cdr a) (cdr b))
                  (and (= (cdr a) (cdr b))
                       (string<? (symbol->string (car a))
                                 (symbol->string (car b)))))))))
  (printf "portability check: scanned ~a files\n" (length results))
  0)
(define (main args)
  (let ((mode (cond
                ((member "--regen" args) 'regen)
                ((member "--census" args) 'census)
                ((member "--dump-operators" args) 'dump)
                (else 'gate))))
    (read-blocklist blocklist-file)
    (let ((cf (or (contract-arg args) contract-file)))
      (when (file-exists? cf) (read-contract cf)))
    (check-contract-overlap)
    (printf "portability check: blocklist loaded, ~a identifiers in ~a tiers; contract ~a identifiers in ~a tiers\n"
            (hashtable-size blocklist) (length tier-order)
            (hashtable-size contract) (length contract-tiers))
    (let* ((files (find-files))
           (scanned (scan-all files))
           (results (car scanned))
           (errors (cdr scanned)))
      (case mode
        ((gate) (run-gate results errors))
        ((regen) (run-regen results errors))
        ((census) (write-census results errors))
        ((dump) (run-dump-operators results))))))
(exit (main (command-line)))
