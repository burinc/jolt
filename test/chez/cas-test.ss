;; test/chez/cas-test.ss — compare-and-swap is STRONG: it answers #f only when
;; the value is not the expected one. Run: chez --script test/chez/cas-test.ss
;; (wired into `make cas`, part of `make ci`).
;;
;; WHY. Chez's $record-cas! is one ldxr/stxr attempt on AArch64 (s/arm64.ss
;; asm-cas): stxr fails whenever the core's exclusive monitor was cleared
;; between the two — a context switch, or another core storing into the same
;; reservation granule — and the primitive then answers #f with the field still
;; holding the expected value. That is a weak CAS, and every caller that read
;; the #f as "somebody else got there first" was wrong once in a few hundred
;; thousand under load: compare-and-set! told ring-chez-adapter's worker its
;; connection was claimed by another owner, the worker walked away, and the
;; connection was served by nobody (one in ~1400 accepts under ab on an M-series
;; Mac; never on x86, whose cmpxchg cannot fail spuriously). sa-record-cas! now
;; retries while the field still holds `old`, so the answer means what every
;; caller took it to mean.
;;
;; Scenario 2 and 3 are REPRODUCERS, not smokes: on the weak primitive they
;; count a handful of spurious failures per million attempts on Apple silicon
;; (5-8 per 2M measured), and zero on x86 whatever the primitive does. A pass
;; here on ARM is the property; a pass on x86 is only the semantics.

(import (chezscheme))
(load "host/chez/rt.ss")

(define total 0)
(define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n" name)))

(printf "== compare-and-swap is strong ==\n")

;; --- 1. semantics ------------------------------------------------------------
(printf "\n== 1. semantics ==\n")
(define-record-type cell (fields (mutable v) (mutable w)) (nongenerative cas-test-cell))
(define c (make-cell 'a 'b))
(ok "1. sa-record-cas! swaps when the field is eq? to old" (eq? #t (sa-record-cas! c 0 'a 'x)))
(ok "1. ...and the field moved" (eq? (cell-v c) 'x))
(ok "1. sa-record-cas! refuses when the field is not eq? to old" (eq? #f (sa-record-cas! c 0 'a 'y)))
(ok "1. ...and the field stayed" (eq? (cell-v c) 'x))
(ok "1. ...and the neighbouring field is untouched" (eq? (cell-w c) 'b))
(define a (jolt-atom-new #f))
(ok "1. compare-and-set! swaps when the value is eq? to old" (eq? #t (jolt-compare-and-set! a #f #t)))
(ok "1. ...and the value moved" (eq? #t (jolt-deref a)))
(ok "1. compare-and-set! refuses when the value is not eq? to old" (eq? #f (jolt-compare-and-set! a #f 'x)))
(ok "1. ...and the value stayed" (eq? #t (jolt-deref a)))

;; --- the harness: one CASer, many neighbour writers ---------------------------
;; The CASer allocates every record itself, so targets sit next to the fields the
;; writers store into — the same cache line, which is what clears an exclusive
;; monitor. Nobody but the CASer ever touches the field it swaps, so every #f it
;; is answered while the field still holds the expected value is spurious.
(define writers 8)
(define (mono-secs)
  (let ((t (current-time 'time-monotonic)))
    (+ (time-second t) (/ (exact->inexact (time-nanosecond t)) 1e9))))
(define (with-writers hammer! body)
  (let ((stop? (box #f)) (running 0) (mu (make-mutex)))
    (let spawn ((w 0))
      (when (fx<? w writers)
        (with-mutex mu (set! running (fx+ running 1)))
        (fork-thread (lambda ()
                       (let loop ((i w))
                         (unless (unbox stop?)
                           (hammer! i)
                           (loop (fx+ i 7))))
                       (with-mutex mu (set! running (fx- running 1)))))
        (spawn (fx+ w 1))))
    (let ((result (body)))
      (set-box! stop? #t)
      (let ((deadline (+ (mono-secs) 30)))
        (let wait ()
          (when (and (fx>? running 0) (< (mono-secs) deadline))
            (sleep (make-time 'time-duration 10000000 0))
            (wait))))
      result)))

;; --- 2. the primitive under neighbour stores ---------------------------------
(printf "\n== 2. sa-record-cas! with 8 threads storing into the next field ==\n")
(define n2 500000)
(define rounds 6)
(define cells (let ((v (make-vector n2)))
                (let fill ((i 0)) (when (fx<? i n2) (vector-set! v i (make-cell 0 0)) (fill (fx+ i 1))))
                v))
(define spurious2
  (with-writers
    (lambda (i) (cell-w-set! (vector-ref cells (fxmod i n2)) i))
    (lambda ()
      (let round ((r 0) (bad 0))
        (if (fx<? r rounds)
            (round (fx+ r 1)
                   (let loop ((i 0) (bad bad))
                     (if (fx<? i n2)
                         (loop (fx+ i 1)
                               (if (sa-record-cas! (vector-ref cells i) 0 r (fx+ r 1)) bad (fx+ bad 1)))
                         bad)))
            bad)))))
(printf "  ~a attempts, ~a spurious failure(s)\n" (* n2 rounds) spurious2)
(ok "2. sa-record-cas! never refused a field that held the expected value" (= spurious2 0))
(ok "2. every field reached the final round" 
    (let check ((i 0)) (or (fx=? i n2) (and (fx=? (cell-v (vector-ref cells i)) rounds) (check (fx+ i 1))))))

;; --- 3. compare-and-set! with neighbouring atoms under reset! ------------------
;; The adapter's shape: one thread's atoms allocated together, a claim CASed on
;; one while another thread reset!s the one beside it.
(printf "\n== 3. compare-and-set! with 8 threads reset!-ing the neighbouring atom ==\n")
(define n3 500000)
(define pairs (let ((v (make-vector n3)))
                (let fill ((i 0))
                  (when (fx<? i n3)
                    (vector-set! v i (cons (jolt-atom-new 0) (jolt-atom-new 0)))
                    (fill (fx+ i 1))))
                v))
(define spurious3
  (with-writers
    (lambda (i) (jolt-reset! (cdr (vector-ref pairs (fxmod i n3))) i))
    (lambda ()
      (let round ((r 0) (bad 0))
        (if (fx<? r rounds)
            (round (fx+ r 1)
                   (let loop ((i 0) (bad bad))
                     (if (fx<? i n3)
                         (loop (fx+ i 1)
                               (if (jolt-compare-and-set! (car (vector-ref pairs i)) r (fx+ r 1)) bad (fx+ bad 1)))
                         bad)))
            bad)))))
(printf "  ~a attempts, ~a spurious failure(s)\n" (* n3 rounds) spurious3)
(ok "3. compare-and-set! never refused a value that was the expected one" (= spurious3 0))
(ok "3. every atom reached the final round"
    (let check ((i 0)) (or (fx=? i n3) (and (eqv? (jolt-deref (car (vector-ref pairs i))) rounds) (check (fx+ i 1))))))

(printf "\ncas-test: ~a checks, ~a failure(s)\n" total fails)
(if (= fails 0)
    (begin (printf "cas-test: PASS — compare-and-swap is strong\n") (exit 0))
    (exit 1))
