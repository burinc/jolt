;; A Matcher owns its match state: repeated finds allocate the RESULT, never
;; the machinery. Each find on a matcher used to build a fresh irregex match
;; vector, a fresh (string start end) source triple and a chunker cons, and
;; irx-result built the groups vector through a list and apply — ~200 bytes
;; per attempt before any matching, on the call a tokenizer makes per token
;; (standard-clojure-style: 18k per 78 KB file, 76% of its parse allocation).
;; The matcher now keeps one match vector and one source triple, reset per
;; search the way irregex-fold reuses its own, and the groups vector is built
;; directly. Bytes are deterministic where nanoseconds are not, so the rows
;; are byte ceilings over many calls in one process, plus the JVM semantics
;; reuse must keep: .group reads the LAST match, and a failed find leaves no
;; match to read.
;;   chez --script test/chez/regex-matcher-test.ss
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (bytes-per n thunk)
  (thunk)
  (let ((b0 (sstats-bytes (statistics))))
    (do ((i 0 (fx+ i 1))) ((fx= i n)) (thunk))
    (quotient (- (sstats-bytes (statistics)) b0) n)))
(define n 50000)

(define txt "(defn foo [x]\n  (+ x 1))\n")
(define len (string-length txt))
(define ws (jolt-regex "^[ ,\\n\\r\\t]+"))          ; group-free: DFA
(define tok (jolt-regex "^(##)?([^()\\[\\]{}\\\"@~^;`#' \\n]+)"))  ; capturing: backtracker
(define m-ws (jolt-re-matcher ws txt))
(define m-tok (jolt-re-matcher tok txt))
(define at-ws (str-index-of txt " " 0))
(define at-tok (str-index-of txt "defn" 0))

(define ws-find (bytes-per n (lambda () (jolt-matcher-region m-ws at-ws len) (jolt-re-find m-ws))))
(define tok-find (bytes-per n (lambda () (jolt-matcher-region m-tok at-tok len) (jolt-re-find m-tok))))
(define tok-miss (bytes-per n (lambda () (jolt-matcher-region m-tok 0 len) (jolt-re-find m-tok))))
(define tok-look (bytes-per n (lambda () (jolt-matcher-region m-tok at-tok len) (jolt-matcher-looking-at m-tok))))
(printf "bytes/attempt: region+re-find ws hit ~a, token hit (2 groups) ~a, token miss ~a, region+lookingAt token ~a\n"
        ws-find tok-find tok-miss tok-look)
(ok "region + re-find on a group-free pattern allocates only the match string (<= 160 B, was 304)"
    (<= ws-find 160))
(ok "region + re-find on a capturing pattern keeps its match vector and source (<= 900 B, was 1184)"
    (<= tok-find 900))
(ok "a failed find allocates no result (<= 256 B, was 640)"
    (<= tok-miss 256))
(ok "region + lookingAt allocates no result vector (<= 640 B, was 848)"
    (<= tok-look 640))

;; semantics reuse must keep
(jolt-matcher-region m-tok at-tok len)
(ok "re-find answers the groups"
    (equal? (jolt-str (jolt-re-find m-tok)) "[\"defn\" nil \"defn\"]"))
(ok ".group reads the last match" (string=? (jolt-matcher-group m-tok 2) "defn"))
(ok ".start/.end read the last match"
    (and (= at-tok (irregex-match-start-index (matcher-t-last m-tok) 0))
         (= (+ at-tok 4) (irregex-match-end-index (matcher-t-last m-tok) 0))))
(jolt-matcher-region m-tok 0 len)
(ok "a failed find drops the last match" (and (jolt-nil? (jolt-re-find m-tok)) (not (matcher-t-last m-tok))))
(ok ".group after a failed find is the JVM's IllegalStateException"
    (guard (e (#t (let ((x (jolt-unwrap-throw e)))
                    (and (jolt-ex-info-record? x)
                         (equal? (jolt-ex-info-record-message x) "No match found")))))
      (jolt-matcher-group m-tok 0) #f))
(jolt-matcher-region m-tok (str-index-of txt "foo" 0) len)
(ok "a later find on the same matcher answers the new match, not the old"
    (and (equal? (jolt-str (jolt-re-find m-tok)) "[\"foo\" nil \"foo\"]")
         (string=? (jolt-matcher-group m-tok 0) "foo")))
;; two matchers on one pattern do not share state
(let ((m2 (jolt-re-matcher tok txt)))
  (jolt-matcher-region m2 at-tok len) (jolt-re-find m2)
  (ok "matchers on one pattern keep separate last matches"
      (and (string=? (jolt-matcher-group m2 0) "defn") (string=? (jolt-matcher-group m-tok 0) "foo"))))
;; the scanning find (no region) still advances and terminates
(let ((m3 (jolt-re-matcher (jolt-regex "o") txt)))
  (ok "successive finds walk every match then stop"
      (let loop ((k 0)) (if (jolt-nil? (jolt-re-find m3)) (= k 2) (loop (+ k 1))))))

(printf "regex-matcher: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
