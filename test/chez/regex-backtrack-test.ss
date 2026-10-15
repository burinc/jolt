;; regex-backtrack-test.ss — the backtracking matcher on the shapes it used to
;; refuse, hang on, or take exponential time over.
;;
;; host/chez/java/regex-anchor-sre.scm is jolt's copy of irregex's sre->procedure
;; and cset-union, and three of its changes are gated here:
;;
;;   jolt-0e5k  a repetition over a body that can match empty — (?:c?)*, (x?)*y,
;;              (?:.*?|a)+ — runs under java.util.regex's rule (an empty
;;              iteration ends the loop), where irregex threw "invalid sre:
;;              empty *" or looped forever.
;;   jolt-yqr   an unbounded top-level loop remembers the positions at which it
;;              already failed, as the JVM's Loop does (posIndex), so nested
;;              quantifiers the JVM runs in linear time no longer take time
;;              exponential in the input: one fuzzed pattern took 15 s on 32
;;              characters. Counted bodies are compiled once, not per iteration.
;;   jolt-t16   cset-union keeps a char set sorted, so [^a]|\s matches "A".
;;
;; Every expected answer is java.util.regex's (JDK 21): each row is a pattern,
;; an input, and every match a Matcher.find loop reports, as (start end group...)
;; with #f for a group that did not participate. Rows run under a fixed budget of
;; engine ticks, not a clock: the exponential rows need billions where the memo
;; leaves them a few hundred thousand, so running out is the failure and no
;; machine is too slow for the budget.
;;   chez --script test/chez/regex-backtrack-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define budget 50000000)

;; Every match of pattern over s, as the JVM's find loop reports them.
(define (all-finds pattern s)
  (let ((mt (jolt-re-matcher (jolt-regex pattern) s)))
    (let lp ((acc '()))
      (if (eq? (jolt-re-find mt) jolt-nil)
          (reverse acc)
          (let* ((m (matcher-t-last mt))
                 (n (irregex-match-num-submatches m)))
            (lp (cons (cons* (irregex-match-start-index m 0)
                             (irregex-match-end-index m 0)
                             (let g ((i 1))
                               (if (> i n)
                                   '()
                                   (cons (and (irregex-match-substring m i)
                                              (list (irregex-match-start-index m i)
                                                    (irregex-match-end-index m i)))
                                         (g (+ i 1))))))
                      acc)))))))

;; The finds within the budget, or 'out-of-budget.
(define (budgeted-finds pattern s)
  ((make-engine (lambda () (all-finds pattern s)))
   budget
   (lambda (ticks v) v)
   (lambda (k) 'out-of-budget)))

(define vectors
  '(
    ("(a|aa)*b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ())
    ("(a|aa)*?b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ())
    ("(a+)+b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ())
    ("(?:a|a)*b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ())
    ("(\\w|\\w\\w)*!" "abcabcabcabcabcabcabcabcabcabc" ())
    ("(.{0,2}?c|b+[ab]c*?|(?:(c{0,2}?|ab|ba)*?(a*|b*c*)(c??|aaa|a{1,3}?)+?|.??(?:b).).)*a[ab]|[ab]{1,3}?[ab]|[ab]{1,3}?." "bbbcacccbbbcacccbbbcacccbbbcaccc" ((0 2 #f #f #f #f) (2 4 #f #f #f #f) (4 6 #f #f #f #f) (8 10 #f #f #f #f) (10 12 #f #f #f #f) (12 14 #f #f #f #f) (16 18 #f #f #f #f) (18 20 #f #f #f #f) (20 22 #f #f #f #f) (24 26 #f #f #f #f) (26 28 #f #f #f #f) (28 30 #f #f #f #f)))
    ("(?:x|xy)*yz" "xyxyxyxyz" ((0 9)))
    ("(a|ab)*c" "abababac" ((0 8 (6 7))))
    ("(ab|a)*?b" "aab" ((0 3 (1 2))))
    ("(a|b)*\\1" "abab" ())
    ("(?:a|b)*?(?<=a)b" "aab" ((0 3)))
    ("(?:c?)*" "ccd" ((0 2) (2 2) (3 3)))
    ("(x?)*y" "xxy" ((0 3 (2 2))))
    ("(?:.*?|a)+" "abcbb" ((0 0) (1 1) (2 2) (3 3) (4 4) (5 5)))
    ("(a?){2,}" "ab" ((0 1 (1 1)) (1 1 (1 1)) (2 2 (2 2))))
    ("(^)*x" "x" ((0 1 #f)))
    ("((^))*" "x" ((0 0 #f (0 0)) (1 1 #f #f)))
    ("((?=x)|(?=y))*" "x" ((0 0 (0 0)) (1 1 #f)))
    ("[^a]|\\s" "acAb\n " ((1 2) (2 3) (3 4) (4 5) (5 6)))
    ("[^b-y]|[a-z&&[^c]]|\\d" "bcd5Z" ((0 1) (2 3) (3 4) (4 5)))
    ("(?:ab|a){2,4}?c" "aaababc" ((0 7)))
    ("(?:a|b){0,40}c" "abababc" ((0 7)))
    ))

(for-each
  (lambda (row)
    (let ((got (budgeted-finds (car row) (cadr row))))
      (ok (format "~s over ~s: ~s, the JVM's ~s" (car row) (cadr row) got (caddr row))
          (equal? got (caddr row)))))
  vectors)

;; The memo is per match attempt: a pattern that failed from one start must still
;; match from a later one, and a second string must not see the first's memo.
(ok "a memoized loop still matches from a later start"
    (equal? (budgeted-finds "(a|aa)*b" "aaaaaaaaaaaaaaaaaaaaxaab") '((21 24 (22 23)))))
(ok "…and on a second input after a failed first"
    (equal? (budgeted-finds "(a|aa)*b" "aab") '((0 3 (1 2)))))

;; A thread matching the same compiled pattern concurrently keeps its own
;; empty-iteration cells and memo: both answer as they would alone.
(let* ((p "(x?)*y|(a|aa)*b")
       (inputs (list "xxy" "aaab" "aaaaaaaaaaaaaaaaaaaay"))
       (alone (map (lambda (s) (all-finds p s)) inputs))
       (m (make-mutex)) (c (make-condition)) (done 0) (bad 0))
  (do ((t 0 (+ t 1))) ((= t 4))
    (fork-thread
      (lambda ()
        (do ((k 0 (+ k 1))) ((= k 200))
          (unless (equal? (map (lambda (s) (all-finds p s)) inputs) alone)
            (with-mutex m (set! bad (+ bad 1)))))
        (with-mutex m (set! done (+ done 1)) (condition-broadcast c)))))
  (with-mutex m (let wait () (unless (= done 4) (condition-wait c m) (wait))))
  (ok "concurrent matches of one pattern agree with a lone one" (= bad 0)))

;; A thread forked after this one has run a memoized match inherits every thread
;; parameter it set, as the same object, so per-attempt state kept in one was
;; shared: each thread's attempt reset the memo the others were using, and the
;; exponential rows went exponential again. Each thread here must finish its
;; matches within the budget while the others run the same ones.
(let* ((p "(a|aa)*b")
       (s (make-string 30 #\a))
       (_ (budgeted-finds p s))
       (m (make-mutex)) (c (make-condition)) (done 0) (bad 0))
  (do ((t 0 (+ t 1))) ((= t 4))
    (fork-thread
      (lambda ()
        ;; each thread its own string: another thread's attempt pointed the
        ;; shared memo at its string, which switched it off for this one
        (do ((k 0 (+ k 1)) (s (string-copy s))) ((= k 20))
          (unless (equal? (budgeted-finds p s) '())
            (with-mutex m (set! bad (+ bad 1)))))
        (with-mutex m (set! done (+ done 1)) (condition-broadcast c)))))
  (with-mutex m (let wait () (unless (= done 4) (condition-wait c m) (wait))))
  (ok "threads forked after a memoized match keep their own memo" (= bad 0)))

;; jolt-t16: a union of char sets is a sorted, disjoint range list, whatever the
;; order its parts overlap in. Checked against membership over random sets.
(define (members cs) (filter (lambda (i) (cset-contains? cs (integer->char i))) (iota 130)))
(define (sorted? cs)
  (let lp ((rs (vector->list cs)) (prev -2))
    (or (null? rs)
        (and (char<=? (caar rs) (cdar rs))
             (> (char->integer (caar rs)) (+ prev 1))
             (lp (cdr rs) (char->integer (cdar rs)))))))
(define (random-cset)
  (let lp ((k (random 5)) (cs (vector)))
    (if (zero? k)
        cs
        (let* ((lo (+ 40 (random 40))) (hi (+ lo (random 8))))
          (lp (- k 1) (cset-union cs (range->cset (integer->char lo) (integer->char hi))))))))
(let lp ((t 0) (bad 0))
  (if (= t 2000)
      (ok "cset-union is sorted and has exactly the members of both" (= bad 0))
      (let* ((a (random-cset)) (b (random-cset)) (u (cset-union a b))
             (want (filter (lambda (i) (or (memv i (members a)) (memv i (members b)))) (iota 130))))
        (lp (+ t 1) (if (and (sorted? u) (equal? (members u) want)) bad (+ bad 1))))))

(printf "regex-backtrack: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
