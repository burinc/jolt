;; regex-dfa-test.ss — the DFA work budget in host/chez/regex-dfa.ss (#945).
;;
;; A group-free pattern compiles to irregex's DFA unless jolt's own engine rule
;; declines it (#1062), or the conversion runs past the state cap or, since #945,
;; past a deterministic work budget; every one of those answers is "compile the
;; backtracking matcher instead". The property gated here is that choice itself,
;; not the time it takes: the pattern from #945 (a 50-way alternation with
;; unbounded `.*` branches, which took ~5s / never finished) must trip the budget
;; and get the backtracker, a pattern of the shape the DFA is kept FOR must still
;; get a DFA, and the two engines must agree on every match — the budget is a
;; match-time optimization, never a semantics change.
;;
;; #1062 added the rule in front: the DFA is kept only for a pattern backtracking
;; would run superlinearly, i.e. one with an unbounded repetition that has
;; consuming pattern after it (#".*z"). Everything else takes the backtracking
;; matcher, which is faster AND leftmost-first like java.util.regex, where the DFA
;; is leftmost-longest. The rows below pin both halves of that.
;;
;; No clock anywhere: an absolute ceiling false-fails on a slow runner and passes
;; on a fast one while hiding a regression, and a ratio needs two arms of the
;; same shape, which "compiles or does not" does not have.
;;   chez --script test/chez/regex-dfa-test.ss
(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define p945
  (string-append
   "(?i)overloaded|rate.?limit|too many requests|429|500|502|503|504|524|"
   "service.?unavailable|server.?error|internal.?error|provider.?returned.?error|"
   "exceeded request buffer limit while retrying upstream|network.?error|"
   "connection.?error|connection.?refused|connection.?lost|connection.?reset|"
   "connection.?abort|broken pipe|forcibly closed|other side closed|fetch failed|"
   "getaddrinfo|ENOTFOUND|EAI_AGAIN|upstream.?connect|upstream.*unavailable|"
   "reset before headers|socket hang up|socket connection was closed|"
   "stream error: .*closed|eof|timed? out|timeout|terminated|websocket.?closed|"
   "websocket.?error|ended without|header parser received no bytes|"
   "stream ended before message_stop|stream ended before a terminal response event|"
   "http2 request did not get a response|rst.?stream|retry delay|"
   "you can retry your request|please retry your request|ResourceExhausted"))

;; regex.ss caches the built engine by source, so an arm that changes the budget
;; has to drop the cache first or it reads the other arm's engine back.
(define (fresh!) (hashtable-clear! regex-cache))

;; The engine a pattern gets: 'dfa when irregex built one, 'backtrack otherwise.
(define (engine-of pattern-string)
  (let ((irx (regex-t-irx (jolt-regex pattern-string))))
    (if (irregex-dfa irx) 'dfa 'backtrack)))

;; Every match of `pattern` over `s`, as (start . end) pairs, through the same
;; scanning entry point re-seq uses.
(define (all-matches pattern-string s)
  (let ((irx (regex-t-irx (jolt-regex pattern-string))))
    (let loop ((i 0) (acc '()))
      (let ((m (and (<= i (string-length s)) (irx-search-from irx s i))))
        (if (not m)
            (reverse acc)
            (let ((ms (irregex-match-start-index m 0)) (me (irregex-match-end-index m 0)))
              (loop (if (> me ms) me (+ me 1)) (cons (cons ms me) acc))))))))

;; 1. a small group-free pattern still gets the DFA
(ok "a.*b compiles to a DFA" (eq? (engine-of "a.*b") 'dfa))
;; …and a pattern backtracking handles linearly does not: nothing follows the
;; repetition in #"[a-z]+", and #"foo|bar|baz" has no repetition at all.
(ok "a plain alternation takes the backtracker" (eq? (engine-of "foo|bar|baz") 'backtrack))
(ok "a trailing repetition takes the backtracker" (eq? (engine-of "[a-z]+") 'backtrack))
(ok "a repetition before an anchor takes the backtracker" (eq? (engine-of "\\s+$") 'backtrack))
(ok "a repetition before a consumer keeps the DFA" (eq? (engine-of "[a-z]+@") 'dfa))
(ok "a nested repetition keeps the DFA" (eq? (engine-of "(?:a+)+") 'dfa))

;; 2. the #945 pattern trips the budget: backtracker, and it still answers
(ok "#945 pattern takes the backtracker under the budget" (eq? (engine-of p945) 'backtrack))
(ok "#945 pattern finds 500" (equal? (all-matches p945 "HTTP 500") '((5 . 8))))
(ok "#945 pattern finds a phrase" (equal? (all-matches p945 "socket hang up") '((0 . 14))))
(ok "#945 pattern misses zzz" (null? (all-matches p945 "zzz")))

;; 3. the budget changes the engine, not the answers. The #945 pattern is past
;; the state cap as well, so lifting the budget buys it nothing; take patterns
;; that DO get a DFA, drop the budget to zero so the same patterns take the
;; backtracker, and the two engines must agree on every input.
;; Patterns that still GET a DFA — the budget arm needs one to take away. Each
;; has an unbounded repetition with consuming pattern after it, which is the shape
;; the DFA is kept for.
(define patterns
  '("a.*b" "(?i)rate.?limit|timed? out|upstream.*unavailable"
    "x.*y|p.*q" "stream error: .*closed|eof"))
(define inputs
  '("HTTP 500" "socket hang up" "zzz" "upstream x y z unavailable" "stream error: foo closed"
    "Rate Limit" "TIMED OUT" "timeout" "aXXb ab a" "eof" "colour gray grey color"
    "" "5" "x1y x2y" "the stream error: closed and closed again" "foobarbaz"))
(define (matrix) (map (lambda (p) (map (lambda (s) (all-matches p s)) inputs)) patterns))
(for-each (lambda (p) (ok (format "~s gets a DFA at the default budget" p) (eq? (engine-of p) 'dfa)))
          patterns)
(define with-dfa (matrix))
(define saved-budget jolt-dfa-work-budget)
(set! jolt-dfa-work-budget 0)
(fresh!)
(for-each (lambda (p) (ok (format "~s takes the backtracker at budget 0" p) (eq? (engine-of p) 'backtrack)))
          patterns)
(define with-backtracker (matrix))
(set! jolt-dfa-work-budget saved-budget)
(fresh!)
(for-each
  (lambda (p a b)
    (for-each (lambda (s x y) (ok (format "~s agrees on ~s under both engines" p s) (equal? x y)))
              inputs a b))
  patterns with-dfa with-backtracker)
(ok "the budget is restored" (eq? (engine-of "a.*b") 'dfa))

;; 4. the budget is what decides for a pattern of this shape. The #945 pattern
;; is the WHOLE story only with a clock — its DFA completes in ~5s when the
;; budget is lifted — so the row that proves the budget FIRES uses its first 30
;; alternatives: at the default budget they take the backtracker, with the budget
;; lifted they get a DFA (~250ms here), and the two agree. Delete the budget check
;; from nfa->dfa and the first row below fails, because the DFA then completes.
(define p945-30
  (let loop ((cs (string->list p945)) (bars 0) (acc '()))
    (cond ((or (null? cs) (= bars 30)) (list->string (reverse acc)))
          ((char=? (car cs) #\|) (loop (cdr cs) (+ bars 1) (cons (car cs) acc)))
          (else (loop (cdr cs) bars (cons (car cs) acc))))))
(define p945-30 (substring p945-30 0 (- (string-length p945-30) 1)))   ; drop the trailing |
(fresh!)
(ok "30 alternatives of #945 trip the budget at its default" (eq? (engine-of p945-30) 'backtrack))
(define bt-30 (map (lambda (s) (all-matches p945-30 s)) inputs))
(set! jolt-dfa-work-budget (* 1000 saved-budget))
(fresh!)
(ok "…and get a DFA once the budget is lifted" (eq? (engine-of p945-30) 'dfa))
(define dfa-30 (map (lambda (s) (all-matches p945-30 s)) inputs))
(set! jolt-dfa-work-budget saved-budget)
(fresh!)
(for-each (lambda (s x y) (ok (format "30-alt pattern agrees on ~s under both engines" s) (equal? x y)))
          inputs bt-30 dfa-30)

;; 5. leftmost-FIRST, which is what routing these patterns to the backtracking
;; matcher buys (#1062). java.util.regex takes the first alternative that matches,
;; not the longest; irregex's DFA is POSIX leftmost-longest, so while #"a|ab" got
;; a DFA it answered "ab" on "ab" where the JVM answers "a". No groups are needed
;; to see it, which is why "non-capturing patterns keep the DFA" was not safe.
(fresh!)
(ok "a|ab takes the first alternative" (equal? (all-matches "a|ab" "ab") '((0 . 1))))
(ok "(?:a|ab) takes the first alternative" (equal? (all-matches "(?:a|ab)" "ab") '((0 . 1))))
(ok "ab|a still takes the first alternative" (equal? (all-matches "ab|a" "ab") '((0 . 2))))
(ok "foo|foobar takes the first alternative" (equal? (all-matches "foo|foobar" "foobar") '((0 . 3))))

(printf "regex-dfa: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
