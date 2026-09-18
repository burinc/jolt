;; regex-dfa-test.ss — the DFA work budget in host/chez/regex-dfa.ss (#945).
;;
;; A group-free pattern compiles to irregex's DFA unless the conversion runs past
;; the state cap or, since #945, past a deterministic work budget; either answer
;; is "compile the backtracking matcher instead". The property gated here is
;; that choice itself, not the time it takes: the pattern from #945 (a 50-way
;; alternation with unbounded `.*` branches, which took ~5s / never finished) must
;; trip the budget and get the backtracker, a small pattern must still get a DFA,
;; and the two engines must agree on every match — the budget is a match-time
;; optimization, never a semantics change.
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
(ok "a plain alternation compiles to a DFA" (eq? (engine-of "foo|bar|baz") 'dfa))

;; 2. the #945 pattern trips the budget: backtracker, and it still answers
(ok "#945 pattern takes the backtracker under the budget" (eq? (engine-of p945) 'backtrack))
(ok "#945 pattern finds 500" (equal? (all-matches p945 "HTTP 500") '((5 . 8))))
(ok "#945 pattern finds a phrase" (equal? (all-matches p945 "socket hang up") '((0 . 14))))
(ok "#945 pattern misses zzz" (null? (all-matches p945 "zzz")))

;; 3. the budget changes the engine, not the answers. The #945 pattern is past
;; the state cap as well, so lifting the budget buys it nothing; take patterns
;; that DO get a DFA, drop the budget to zero so the same patterns take the
;; backtracker, and the two engines must agree on every input.
(define patterns
  '("a.*b" "foo|bar|baz" "(?i)rate.?limit|timed? out|upstream.*unavailable"
    "[0-9]+|x.y" "colou?r|gr[ae]y" "stream error: .*closed|eof"))
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

(printf "regex-dfa: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
