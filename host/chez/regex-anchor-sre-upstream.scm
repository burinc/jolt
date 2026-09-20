;; PINNED COPY — do not edit by hand.
;;
;; irregex's own sre->procedure, as of the currently checked-out
;; vendor/irregex. host/chez/java/regex-anchor-sre.scm is jolt's
;; replacement for it, and `make regexanchorcheck` fails when the two
;; stop agreeing — see host/chez/regex-anchor-check.ss. Nothing loads
;; this file.
;;
;; Re-pin with `make regexanchorcheck-regen` AFTER porting the upstream
;; change into regex-anchor-sre.scm.
(define (sre->procedure sre . o)
  (define names
    (if (and (pair? o) (pair? (cdr o)))
        (cadr o)
        (sre-names sre 1 '())))
  (let lp ([sre sre]
           [n 1]
           [flags (if (pair? o) (car o) ~none)]
           [next (lambda (cnk init src str i end matches fail)
                   (irregex-match-start-chunk-set! matches 0 (car init))
                   (irregex-match-start-index-set! matches 0 (cdr init))
                   (irregex-match-end-chunk-set! matches 0 src)
                   (irregex-match-end-index-set! matches 0 i)
                   (%irregex-match-fail-set! matches fail)
                   matches)])
    (define (rec sre) (lp sre n flags next))
    (cond
      [(pair? sre)
       (if (string? (car sre))
           (sre-cset->procedure
             (sre->cset (car sre) (flag-set? flags ~case-insensitive?))
             next)
           (case (car sre)
             [(~ - & /)
              (sre-cset->procedure
                (sre->cset sre (flag-set? flags ~case-insensitive?))
                next)]
             [(or)
              (case (length (cdr sre))
                [(0) (lambda (cnk init src str i end matches fail) (fail))]
                [(1) (rec (cadr sre))]
                [else
                 (let* ([first (rec (cadr sre))]
                        [rest (lp (sre-alternate (cddr sre))
                                  (+ n (sre-count-submatches (cadr sre)))
                                  flags
                                  next)])
                   (lambda (cnk init src str i end matches fail)
                     (first cnk init src str i end matches
                       (lambda ()
                         (rest cnk init src str i end matches fail)))))])]
             [(w/case)
              (lp (sre-sequence (cdr sre))
                  n
                  (flag-clear flags ~case-insensitive?)
                  next)]
             [(w/nocase)
              (lp (sre-sequence (cdr sre))
                  n
                  (flag-join flags ~case-insensitive?)
                  next)]
             [(w/utf8)
              (lp (sre-sequence (cdr sre))
                  n
                  (flag-join flags ~utf8?)
                  next)]
             [(w/noutf8)
              (lp (sre-sequence (cdr sre))
                  n
                  (flag-clear flags ~utf8?)
                  next)]
             [(seq :)
              (case (length (cdr sre))
                [(0) next]
                [(1) (rec (cadr sre))]
                [else
                 (let ([rest (lp (sre-sequence (cddr sre))
                                 (+ n (sre-count-submatches (cadr sre)))
                                 flags
                                 next)])
                   (lp (cadr sre) n flags rest))])]
             [(?)
              (let ([body (rec (sre-sequence (cdr sre)))])
                (lambda (cnk init src str i end matches fail)
                  (body cnk init src str i end matches
                    (lambda ()
                      (next cnk init src str i end matches fail)))))]
             [(??)
              (let ([body (rec (sre-sequence (cdr sre)))])
                (lambda (cnk init src str i end matches fail)
                  (next cnk init src str i end matches
                    (lambda ()
                      (body cnk init src str i end matches fail)))))]
             [(*)
              (cond
                [(sre-empty? (sre-sequence (cdr sre)))
                 (error "invalid sre: empty *" sre)]
                [else
                 (let ([body (rec (list '+ (sre-sequence (cdr sre))))])
                   (lambda (cnk init src str i end matches fail)
                     (body cnk init src str i end matches
                       (lambda ()
                         (next cnk init src str i end matches fail)))))])]
             [(*?)
              (cond
                [(sre-empty? (sre-sequence (cdr sre)))
                 (error "invalid sre: empty *?" sre)]
                [else
                 (letrec ([body (lp (sre-sequence (cdr sre))
                                    n
                                    flags
                                    (lambda (cnk init src str i end matches
                                             fail)
                                      (next cnk init src str i end matches
                                        (lambda ()
                                          (body cnk init src str i end
                                            matches fail)))))])
                   (lambda (cnk init src str i end matches fail)
                     (next cnk init src str i end matches
                       (lambda ()
                         (body cnk init src str i end matches fail)))))])]
             [(+)
              (cond
                [(sre-empty? (sre-sequence (cdr sre)))
                 (error "invalid sre: empty +" sre)]
                [else
                 (letrec ([body (lp (sre-sequence (cdr sre))
                                    n
                                    flags
                                    (lambda (cnk init src str i end matches
                                             fail)
                                      (body cnk init src str i end matches
                                        (lambda ()
                                          (next cnk init src str i end
                                            matches fail)))))])
                   body)])]
             [(=) (rec `(** ,(cadr sre) ,(cadr sre) ,@(cddr sre)))]
             [(>=) (rec `(** ,(cadr sre) #f ,@(cddr sre)))]
             [(**)
              (cond
                [(or (and (number? (cadr sre))
                          (number? (caddr sre))
                          (> (cadr sre) (caddr sre)))
                     (and (not (cadr sre)) (caddr sre)))
                 (lambda (cnk init src str i end matches fail) (fail))]
                [else
                 (letrec ([from (cadr sre)]
                          [to (caddr sre)]
                          [body-contents (sre-sequence (cdddr sre))]
                          [body (lambda (count)
                                  (lp body-contents
                                      n
                                      flags
                                      (lambda (cnk init src str i end
                                               matches fail)
                                        (if (and to (= count to))
                                            (next cnk init src str i end
                                              matches fail)
                                            ((body (+ 1 count)) cnk init src str i end
                                              matches
                                              (lambda ()
                                                (if (>= count from)
                                                    (next cnk init src str
                                                      i end matches fail)
                                                    (fail))))))))])
                   (if (and (zero? from) to (zero? to))
                       next
                       (lambda (cnk init src str i end matches fail)
                         ((body 1) cnk init src str i end matches
                           (lambda ()
                             (if (zero? from)
                                 (next cnk init src str i end matches fail)
                                 (fail)))))))])]
             [(**?)
              (cond
                [(or (and (number? (cadr sre))
                          (number? (caddr sre))
                          (> (cadr sre) (caddr sre)))
                     (and (not (cadr sre)) (caddr sre)))
                 (lambda (cnk init src str i end matches fail) (fail))]
                [else
                 (letrec ([from (cadr sre)]
                          [to (caddr sre)]
                          [body-contents (sre-sequence (cdddr sre))]
                          [body (lambda (count)
                                  (lp body-contents
                                      n
                                      flags
                                      (lambda (cnk init src str i end
                                               matches fail)
                                        (if (< count from)
                                            ((body (+ 1 count)) cnk init src str i end
                                              matches fail)
                                            (next cnk init src str i end
                                              matches
                                              (lambda ()
                                                (if (and to (= count to))
                                                    (fail)
                                                    ((body (+ 1 count)) cnk init src str i
                                                      end matches
                                                      fail))))))))])
                   (if (and (zero? from) to (zero? to))
                       next
                       (lambda (cnk init src str i end matches fail)
                         (if (zero? from)
                             (next cnk init src str i end matches
                               (lambda ()
                                 ((body 1) cnk init src str i end matches
                                   fail)))
                             ((body 1) cnk init src str i end matches
                               fail)))))])]
             [(word) (rec `(seq bow ,@(cdr sre) eow))]
             [(word+)
              (rec `(seq bow
                         (+ (& (or alphanumeric "_") (or ,@(cdr sre))))
                         eow))]
             [(posix-string) (rec (string->sre (cadr sre)))]
             [(look-ahead)
              (let ([check (lp (sre-sequence (cdr sre))
                               n
                               flags
                               (lambda (cnk init src str i end matches
                                        fail)
                                 i))])
                (lambda (cnk init src str i end matches fail)
                  (if (check cnk init src str i end matches (lambda () #f))
                      (next cnk init src str i end matches fail)
                      (fail))))]
             [(neg-look-ahead)
              (let ([check (lp (sre-sequence (cdr sre))
                               n
                               flags
                               (lambda (cnk init src str i end matches
                                        fail)
                                 i))])
                (lambda (cnk init src str i end matches fail)
                  (if (check cnk init src str i end matches (lambda () #f))
                      (fail)
                      (next cnk init src str i end matches fail))))]
             [(look-behind neg-look-behind)
              (let ([check (lp (sre-sequence
                                 (cons '(* any) (append (cdr sre) '(eos))))
                               n
                               flags
                               (lambda (cnk init src str i end matches
                                        fail)
                                 i))])
                (lambda (cnk init src str i end matches fail)
                  (let* ([cnk* (wrap-end-chunker cnk src i)]
                         [str* ((chunker-get-str cnk*) (car init))]
                         [i* (cdr init)]
                         [end* ((chunker-get-end cnk*) (car init))])
                    (if ((if (eq? (car sre) 'look-behind)
                             (lambda (x) x)
                             not)
                          (check cnk* init (car init) str* i* end* matches
                            (lambda () #f)))
                        (next cnk init src str i end matches fail)
                        (fail)))))]
             [(atomic)
              (let ([once (lp (sre-sequence (cdr sre))
                              n
                              flags
                              (lambda (cnk init src str i end matches fail)
                                i))])
                (lambda (cnk init src str i end matches fail)
                  (let ([j (once cnk init src str i end matches
                             (lambda () #f))])
                    (if j
                        (next cnk init src str j end matches fail)
                        (fail)))))]
             [(if)
              (let* ([test-submatches (sre-count-submatches (cadr sre))]
                     [pass (lp (caddr sre)
                               flags
                               (+ n test-submatches)
                               next)]
                     [fail (if (pair? (cdddr sre))
                               (lp (cadddr sre)
                                   (+ n
                                      test-submatches
                                      (sre-count-submatches (caddr sre)))
                                   flags
                                   next)
                               (lambda (cnk init src str i end matches
                                        fail)
                                 (fail)))])
                (cond
                  [(or (number? (cadr sre)) (symbol? (cadr sre)))
                   (let ([index (if (symbol? (cadr sre))
                                    (cond
                                      [(assq (cadr sre) names) => cdr]
                                      [else
                                       (error "unknown named backref in SRE IF"
                                         sre)])
                                    (cadr sre))])
                     (lambda (cnk init src str i end matches fail2)
                       (if (%irregex-match-end-chunk matches index)
                           (pass cnk init src str i end matches fail2)
                           (fail cnk init src str i end matches fail2))))]
                  [else
                   (let ([test (lp (cadr sre) n flags pass)])
                     (lambda (cnk init src str i end matches fail2)
                       (test cnk init src str i end matches
                         (lambda ()
                           (fail cnk init src str i end matches
                             fail2)))))]))]
             [(backref backref-ci)
              (let ([n (cond
                         [(number? (cadr sre)) (cadr sre)]
                         [(assq (cadr sre) names) => cdr]
                         [else
                          (error "unknown backreference" (cadr sre))])]
                    [compare (if (or (eq? (car sre) 'backref-ci)
                                     (flag-set? flags ~case-insensitive?))
                                 string-ci=?
                                 string=?)])
                (lambda (cnk init src str i end matches fail)
                  (let ([s (irregex-match-substring matches n)])
                    (if (not s)
                        (fail)
                        (let lp ([src src]
                                 [str str]
                                 [i i]
                                 [end end]
                                 [j 0]
                                 [len (string-length s)])
                          (cond
                            [(<= len (- end i))
                             (cond
                               [(compare
                                  (substring s j (string-length s))
                                  (substring str i (+ i len)))
                                (next cnk init src str (+ i len) end
                                  matches fail)]
                               [else (fail)])]
                            [else
                             (cond
                               [(compare
                                  (substring s j (+ j (- end i)))
                                  (substring str i end))
                                (let ([src2 ((chunker-get-next cnk) src)])
                                  (if src2
                                      (lp src2 ((chunker-get-str cnk) src2)
                                          ((chunker-get-start cnk) src2)
                                          ((chunker-get-end cnk) src2)
                                          (+ j (- end i))
                                          (- len (- end i)))
                                      (fail)))]
                               [else (fail)])]))))))]
             [(dsm)
              (lp (sre-sequence (cdddr sre)) (+ n (cadr sre)) flags next)]
             [($ submatch)
              (let ([body (lp (sre-sequence (cdr sre))
                              (+ n 1)
                              flags
                              (lambda (cnk init src str i end matches fail)
                                (let ([old-source (%irregex-match-end-chunk
                                                    matches
                                                    n)]
                                      [old-index (%irregex-match-end-index
                                                   matches
                                                   n)])
                                  (irregex-match-end-chunk-set!
                                    matches
                                    n
                                    src)
                                  (irregex-match-end-index-set!
                                    matches
                                    n
                                    i)
                                  (next cnk init src str i end matches
                                    (lambda ()
                                      (irregex-match-end-chunk-set!
                                        matches
                                        n
                                        old-source)
                                      (irregex-match-end-index-set!
                                        matches
                                        n
                                        old-index)
                                      (fail))))))])
                (lambda (cnk init src str i end matches fail)
                  (let ([old-source (%irregex-match-start-chunk matches n)]
                        [old-index (%irregex-match-start-index matches n)])
                    (irregex-match-start-chunk-set! matches n src)
                    (irregex-match-start-index-set! matches n i)
                    (body cnk init src str i end matches
                      (lambda ()
                        (irregex-match-start-chunk-set!
                          matches
                          n
                          old-source)
                        (irregex-match-start-index-set!
                          matches
                          n
                          old-index)
                        (fail))))))]
             [(=> submatch-named) (rec `(submatch ,@(cddr sre)))]
             [else (error "unknown regexp operator" sre)]))]
      [(symbol? sre)
       (case sre
         [(any)
          (lambda (cnk init src str i end matches fail)
            (if (< i end)
                (next cnk init src str (+ i 1) end matches fail)
                (let ([src2 ((chunker-get-next cnk) src)])
                  (if src2
                      (let ([str2 ((chunker-get-str cnk) src2)]
                            [i2 ((chunker-get-start cnk) src2)]
                            [end2 ((chunker-get-end cnk) src2)])
                        (next cnk init src2 str2 (+ i2 1) end2 matches
                          fail))
                      (fail)))))]
         [(nonl)
          (lambda (cnk init src str i end matches fail)
            (if (< i end)
                (if (not (eqv? #\newline (string-ref str i)))
                    (next cnk init src str (+ i 1) end matches fail)
                    (fail))
                (let ([src2 ((chunker-get-next cnk) src)])
                  (if src2
                      (let ([str2 ((chunker-get-str cnk) src2)]
                            [i2 ((chunker-get-start cnk) src2)]
                            [end2 ((chunker-get-end cnk) src2)])
                        (if (not (eqv? #\newline (string-ref str2 i2)))
                            (next cnk init src2 str2 (+ i2 1) end2 matches
                              fail)
                            (fail)))
                      (fail)))))]
         [(bos)
          (lambda (cnk init src str i end matches fail)
            (if (and (eq? src (car init)) (eqv? i (cdr init)))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(bol)
          (lambda (cnk init src str i end matches fail)
            (if (let ([ch (if (> i ((chunker-get-start cnk) src))
                              (string-ref str (- i 1))
                              (chunker-prev-char cnk init src))])
                  (or (not ch) (eqv? #\newline ch)))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(bow)
          (lambda (cnk init src str i end matches fail)
            (if (and (if (> i ((chunker-get-start cnk) src))
                         (not (char-alphanumeric?
                                (string-ref str (- i 1))))
                         (let ([ch (chunker-prev-char cnk init src)])
                           (or (not ch) (not (char-alphanumeric? ch)))))
                     (if (< i end)
                         (char-alphanumeric? (string-ref str i))
                         (let ([next ((chunker-get-next cnk) src)])
                           (and next
                                (char-alphanumeric?
                                  (string-ref
                                    ((chunker-get-str cnk) next)
                                    ((chunker-get-start cnk) next)))))))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(eos)
          (lambda (cnk init src str i end matches fail)
            (if (and (>= i end) (not ((chunker-get-next cnk) src)))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(eol)
          (lambda (cnk init src str i end matches fail)
            (if (if (< i end)
                    (eqv? #\newline (string-ref str i))
                    (let ([src2 ((chunker-get-next cnk) src)])
                      (if (not src2)
                          #t
                          (eqv?
                            #\newline
                            (string-ref
                              ((chunker-get-str cnk) src2)
                              ((chunker-get-start cnk) src2))))))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(eow)
          (lambda (cnk init src str i end matches fail)
            (if (and (if (< i end)
                         (not (char-alphanumeric? (string-ref str i)))
                         (let ([ch (chunker-next-char cnk src)])
                           (or (not ch) (not (char-alphanumeric? ch)))))
                     (if (> i ((chunker-get-start cnk) src))
                         (char-alphanumeric? (string-ref str (- i 1)))
                         (let ([prev (chunker-prev-char cnk init src)])
                           (or (not prev) (char-alphanumeric? prev)))))
                (next cnk init src str i end matches fail)
                (fail)))]
         [(nwb)
          (lambda (cnk init src str i end matches fail)
            (let ([c1 (if (< i end)
                          (string-ref str i)
                          (chunker-next-char cnk src))]
                  [c2 (if (> i ((chunker-get-start cnk) src))
                          (string-ref str (- i 1))
                          (chunker-prev-char cnk init src))])
              (if (and c1
                       c2
                       (if (char-alphanumeric? c1)
                           (char-alphanumeric? c2)
                           (not (char-alphanumeric? c2))))
                  (next cnk init src str i end matches fail)
                  (fail))))]
         [(epsilon) next]
         [else
          (let ([cell (assq sre sre-named-definitions)])
            (if cell (rec (cdr cell)) (error "unknown regexp" sre)))])]
      [(char? sre)
       (if (flag-set? flags ~case-insensitive?)
           (lambda (cnk init src str i end matches fail)
             (if (>= i end)
                 (let lp ([src2 ((chunker-get-next cnk) src)])
                   (if src2
                       (let ([str2 ((chunker-get-str cnk) src2)]
                             [i2 ((chunker-get-start cnk) src2)]
                             [end2 ((chunker-get-end cnk) src2)])
                         (if (>= i2 end2)
                             (lp ((chunker-get-next cnk) src2))
                             (if (char-ci=? sre (string-ref str2 i2))
                                 (next cnk init src2 str2 (+ i2 1) end2
                                   matches fail)
                                 (fail))))
                       (fail)))
                 (if (char-ci=? sre (string-ref str i))
                     (next cnk init src str (+ i 1) end matches fail)
                     (fail))))
           (lambda (cnk init src str i end matches fail)
             (if (>= i end)
                 (let lp ([src2 ((chunker-get-next cnk) src)])
                   (if src2
                       (let ([str2 ((chunker-get-str cnk) src2)]
                             [i2 ((chunker-get-start cnk) src2)]
                             [end2 ((chunker-get-end cnk) src2)])
                         (if (>= i2 end2)
                             (lp ((chunker-get-next cnk) src2))
                             (if (char=? sre (string-ref str2 i2))
                                 (next cnk init src2 str2 (+ i2 1) end2
                                   matches fail)
                                 (fail))))
                       (fail)))
                 (if (char=? sre (string-ref str i))
                     (next cnk init src str (+ i 1) end matches fail)
                     (fail)))))]
      [(string? sre) (rec (sre-sequence (string->list sre)))]
      [else (error "unknown regexp" sre)])))
