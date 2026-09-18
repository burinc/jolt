;; An unhinted method call allocates the call-site argument vector and, at
;; most, one Scheme list of those arguments — never a seq walk per arm.
;;
;; record-method-dispatch walks the registered arms in priority order and each
;; arm answers or 'passes. An arm that converted the rest args BEFORE testing
;; whether the receiver was its own (seq->list: a cseq plus a cons per arg)
;; charged every receiver below it for the conversion: a 2-arg (.region m a b)
;; on a Matcher — priority 42, under the dotform arm at 30 — allocated 576
;; bytes in dispatch alone, before the method ran. standard-clojure-style's
;; parser makes 18k such calls per 78 KB file. Bytes are deterministic where
;; nanoseconds are not, so the invariant is a byte ceiling per call, measured
;; over many calls in one process.
;;   chez --script test/chez/method-dispatch-alloc-test.ss
(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define n 200000)
(define (bytes-per thunk)
  (thunk)
  (let ((b0 (sstats-bytes (statistics))))
    (do ((i 0 (fx+ i 1))) ((fx= i n)) (thunk))
    (quotient (- (sstats-bytes (statistics)) b0) n)))

(define txt (make-string 4096 #\a))
(define m (jolt-re-matcher (jolt-regex "^a+") txt))
(define args2 (jolt-vector 0 100))

;; what the call site itself pays: the argument vector
(define site (bytes-per (lambda () (jolt-vector 0 100))))
(define region (bytes-per (lambda () (record-method-dispatch m "region" (jolt-vector 0 100)))))
(define region-count (bytes-per (lambda () (record-method-dispatch m "regionStart" jolt-nil))))
(printf "bytes/call: arg vector ~a, .region ~a, .regionStart ~a\n" site region region-count)

(ok ".region on a Matcher allocates the arg vector plus at most one arg list (<= site + 64)"
    (<= region (+ site 64)))
(ok "a no-arg method on a late-arm receiver allocates nothing in dispatch"
    (= region-count 0))
;; the arms still answer
(ok ".region set the region"
    (and (record-method-dispatch m "region" (jolt-vector 3 100))
         (= 3 (record-method-dispatch m "regionStart" jolt-nil))))

(printf "method-dispatch-alloc: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
