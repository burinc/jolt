;; build-segments-test.ss — where bld-emit-runtime ends a boot image segment.
;;
;;   a. bld-scan-line! answers "top-level boundary" only between forms: never
;;      inside a form, a string, a block comment or a |symbol| that spans lines,
;;      and not after a prefix (quote, quasiquote, unquote, datum comment) whose
;;      datum is on the next line. Parens inside strings, char literals and
;;      comments do not count.
;;   b. a file larger than the segment size is broken inside it, at form
;;      boundaries, so no segment overshoots by a whole file: a segment's image
;;      over a standard chunk took a fresh oversize chunk when the free
;;      segments were fragmented, and a closed-world boot's peak moved 4MB with
;;      comment-only edits.
;;   c. a file the scanner cannot follow to a clean end stops the build, rather
;;      than risking a break inside a string.
;;
;;   chez --script test/chez/build-segments-test.ss
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

;; the boundary answer after each of LINES, scanned in order as one file (not
;; map: Chez's map applies in no particular order)
(define (boundaries . lines)
  (let ((st (bld-make-form-state)))
    (let loop ((ls lines) (acc '()))
      (if (null? ls)
          (reverse acc)
          (loop (cdr ls) (cons (bld-scan-line! st (car ls)) acc))))))

;; --- (a) ----------------------------------------------------------------------
(ok "(a) a complete form, a comment and a blank line are boundaries"
    (equal? (boundaries "(define x 1)" ";; (not code" "") '(#t #t #t)))
(ok "(a) inside a multi-line form is not"
    (equal? (boundaries "(define (f x)" "  (g x))") '(#f #t)))
(ok "(a) parens in a string spanning lines do not count"
    (equal? (boundaries "(define s \"a (" "(b\" )" "(define t 2)") '(#f #t #t)))
(ok "(a) an escaped quote stays in the string"
    (equal? (boundaries "(define s \"a \\\" (\")") '(#t)))
(ok "(a) char literals do not open or close anything"
    (equal? (boundaries "(list #\\( #\\\" #\\; #\\))") '(#t)))
(ok "(a) a block comment spanning lines, nested, is not code"
    (equal? (boundaries "#| (" "#| ) |# (" "|#" "(x)") '(#f #f #t #t)))
(ok "(a) a |symbol| holding parens and quotes"
    (equal? (boundaries "(define |a(\"b| 1)") '(#t)))
(ok "(a) a trailing quote or datum comment waits for its datum"
    (equal? (boundaries "'" "(x)" "#;" "(y)" "`" "(z)") '(#f #t #f #t #f #t)))
(ok "(a) a line comment's parens do not count"
    (equal? (boundaries "(define x 1) ; (" "(define y 2)") '(#t #t)))
(ok "(a) brackets nest like parens"
    (equal? (boundaries "(let ([x 1]" "      [y 2])" "  x)") '(#f #f #t)))

;; --- (b) and (c) --------------------------------------------------------------
(define work (string-append (host-temp-dir) "/jolt-segments-test-" (number->string (get-process-id))))
(define (spit path s)
  (let ((p (open-output-file path 'replace))) (put-string p s) (close-port p)))
(system (string-append "mkdir -p '" work "'"))

;; emit a (load PATH) line the way bld-emit-runtime does, with LIMIT as the
;; segment size; the emitted text
(define (emit-load path limit)
  (let-values (((out get) (open-string-output-port)))
    (let ((saved bld-segment-source-bytes))
      (set! bld-segment-source-bytes limit)
      (set! bld-segment-out out)
      (set! bld-segment-pending 0)
      (dynamic-wind
        void
        (lambda () (bld-inline-line (string-append "(load \"" path "\")") out 0))
        (lambda () (set! bld-segment-source-bytes saved) (set! bld-segment-out #f)))
      (get))))
(define break-line "(define jolt-boot-segment-break '$install-library-entry)")

;; 200 three-line forms, each holding a string with a newline and parens
(define big (string-append work "/big.ss"))
(spit big
  (apply string-append
    (map (lambda (i)
           (string-append "(define (f" (number->string i) " x)\n"
                          "  (string-append x \"(\n)\"))\n"))
         (iota 200))))
(let* ((text (emit-load big 1000))
       (lines (bld-string-lines text))
       (breaks (length (filter (lambda (l) (string=? l break-line)) lines))))
  (ok "(b) a file over the segment size is broken inside it" (> breaks 5))
  ;; every break sits after a form's last line, never inside one
  (ok "(b) each break follows the end of a form"
      (let loop ((ls lines) (prev #f))
        (cond ((null? ls) #t)
              ((string=? (car ls) break-line)
               (and prev (string=? prev ")\"))") (loop (cdr ls) (car ls))))
              (else (loop (cdr ls) (car ls))))))
  (ok "(b) the emitted file still reads as the same forms plus the breaks"
      (let ((p (open-input-string text)))
        (let loop ((n 0))
          (let ((d (read p)))
            (if (eof-object? d) (= n (+ 200 breaks)) (loop (+ n 1))))))))

(define unbalanced (string-append work "/unbalanced.ss"))
(spit unbalanced "(define s \"never closed)\n(define t 1)\n")
(ok "(c) a file that does not end clean stops the build"
    (guard (e (#t (and (message-condition? e)
                       (bld-contains? (condition-message e) "lost track of top-level forms"))))
      (emit-load unbalanced 10)
      #f))

(system (string-append "rm -rf '" work "'"))
(printf "\nbuild segments: ~a passed, ~a failed\n" (- total fails) fails)
(when (> fails 0) (exit 1))
