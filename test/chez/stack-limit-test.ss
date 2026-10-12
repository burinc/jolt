;; test/chez/stack-limit-test.ss — the stack depth limit (rt.ss
;; jolt-install-stack-limit!, the adapter's sa-current-stack-bytes and
;; sa-gc-install-after-rendezvous!). Run:
;;   chez --script test/chez/stack-limit-test.ss   (wired into `make stacklimit`)
;;
;; The pieces a process-level run cannot reach on every host: JOLT_STACK_LIMIT's
;; parser, the default's precedence (RLIMIT_AS, then RLIMIT_DATA, then physical
;; RAM; macOS refuses `ulimit -v` and `ulimit -d`, so only Linux can drive the
;; real thing from a shell), and that the measurement tracks depth. The
;; end-to-end behaviour (the throw, its class, catching it, carrying on after)
;; is test/stack_limit_test.clj, run against the binary by the same gate.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

;; --- 1. JOLT_STACK_LIMIT's spelling ------------------------------------------
(printf "== 1. parsing ==\n")
(for-each
  (lambda (c)
    (let ((got (jolt-stack-limit-parse (car c))))
      (ok (format "1. ~s -> ~s (got ~s)" (car c) (cdr c) got) (equal? got (cdr c)))))
  `(("1048576" . 1048576)
    ("64k" . 65536) ("64K" . 65536)
    ("512m" . 536870912) ("512M" . 536870912)
    ("2g" . 2147483648) ("2G" . 2147483648)
    ("-1" . off)
    ;; everything else is a configuration error, refused by name at startup
    ("" . #f) ("abc" . #f) ("0" . #f) ("0m" . #f) ("-2" . #f) ("-1m" . #f)
    ("1.5g" . #f) ("12x" . #f) ("m" . #f) ("2gb" . #f) (" 2g" . #f) ("off" . #f)))

;; --- 2. the default: 80% of the first finite memory limit ---------------------
(printf "== 2. default precedence ==\n")
(define gib (* 1024 1024 1024))
(ok "2a. RLIMIT_AS wins over RLIMIT_DATA and RAM"
    (= (jolt-stack-limit-default (* 8 gib) (* 4 gib) (* 64 gib)) (quotient (* 8 gib 4) 5)))
(ok "2b. RLIMIT_DATA when RLIMIT_AS is unlimited"
    (= (jolt-stack-limit-default #f (* 4 gib) (* 64 gib)) (quotient (* 4 gib 4) 5)))
(ok "2c. physical RAM when neither rlimit is set"
    (= (jolt-stack-limit-default #f #f (* 64 gib)) (quotient (* 64 gib 4) 5)))
(ok "2d. nothing readable: no limit rather than a guess"
    (not (jolt-stack-limit-default #f #f #f)))
(ok "2e. an exact integer, floored"
    (eqv? (jolt-stack-limit-default 1001 #f #f) 800))

;; The real readings on this host: each an exact positive integer or #f.
(define (reading? x) (or (not x) (and (exact? x) (integer? x) (> x 0))))
(ok "2f. RLIMIT_AS reads as bytes or #f" (reading? (jolt-rlimit-bytes 'as)))
(ok "2g. RLIMIT_DATA reads as bytes or #f" (reading? (jolt-rlimit-bytes 'data)))
(ok "2h. the default on this host is a number (physical RAM is readable)"
    (let ((d (jolt-stack-limit-default (jolt-rlimit-bytes 'as) (jolt-rlimit-bytes 'data)
                                       (heap-phys-from-sysconf))))
      (and (exact? d) (> d 0))))

;; --- 3. the measurement follows depth -----------------------------------------
(printf "== 3. measurement ==\n")
(define (depth-probe n)
  (if (= n 0)
      (sa-current-stack-bytes)
      (let ((r (depth-probe (- n 1)))) r)))
(let ((shallow (sa-current-stack-bytes))
      (deep (depth-probe 1000000)))
  (ok (format "3a. a 1M-frame recursion measures deeper (~a -> ~a bytes)" shallow deep)
      (and (integer? shallow) (integer? deep) (> (- deep shallow) (* 4 1024 1024)))))
;; the memo: the same depth read twice answers the same, and a read after the
;; recursion returned is back near the start
(let* ((a (depth-probe 200000)) (b (depth-probe 200000)) (c (sa-current-stack-bytes)))
  ;; within a segment: where the splits fall can differ between two runs
  (ok (format "3b. repeatable (~a, ~a)" a b) (< (abs (- a b)) 65536))
  (ok (format "3c. unwound (~a)" c) (< c (quotient a 2))))

;; --- 4. enforcement, in process -------------------------------------------------
(printf "== 4. enforcement ==\n")
(define (runaway n) (+ 1 (runaway n)))
(define (caught-class thunk)
  (guard (e (#t (let ((v (jolt-unwrap-throw e)))
                    (if (jolt-ex-info-record? v) (jolt-ex-info-record-class-name v) v))))
    (thunk)
    'returned))
(jolt-stack-limit-set! (* 32 1024 1024))
(ok "4a. installed" (= (jolt-stack-limit) (* 32 1024 1024)))
(let ((c (caught-class (lambda () (runaway 1)))))
  (ok (format "4b. runaway recursion raises StackOverflowError (got ~s)" c)
      (equal? c "java.lang.StackOverflowError")))
(let ((c (caught-class (lambda () (runaway 1)))))
  (ok (format "4c. and again after the first unwound (got ~s)" c)
      (equal? c "java.lang.StackOverflowError")))
(ok "4d. ordinary depth still works under the limit" (= 100000 (let d ((n 100000)) (if (= n 0) 0 (+ 1 (d (- n 1)))))))
(jolt-stack-limit-set! #f)
(ok "4e. disabled" (not (jolt-stack-limit)))
(ok "4f. disabled: a recursion past the old limit completes"
    (= 3000000 (let d ((n 3000000)) (if (= n 0) 0 (+ 1 (d (- n 1)))))))

(printf "\n~a checks, ~a failed\n" total fails)
(when (> fails 0) (exit 1))
(printf "stack-limit gate: PASS\n")
