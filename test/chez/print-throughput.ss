;; print-throughput.ss — perf probe for the print/pr value seams, 200000 values
;; each. Run: chez --script test/chez/print-throughput.ss (or `make printperf`).
;;
;; Values are INTEGERS, deliberately. A string short-circuits in the first cond
;; arm of the readable renderer, so a string loop measures almost none of the
;; dispatch this guards and reads well under a real print-heavy program; an
;; integer walks the base cases and, before the fast path, both arm registries.
;; An earlier version of this probe printed strings and reported a number a real
;; `jolt run` did not reproduce.
;;
;; Two regressions this stands guard over, both over 200k values:
;;   - binding *print-readably* per value through the dynamic-var machinery
;;     (~770ns/value): print 235ms -> 404ms.
;;   - routing print through the readable renderer without the fast path, so
;;     every value tests ~40 host-type arm predicates that cannot match it:
;;     print 235ms -> 272ms.
;; Current shape: print ~224ms, pr-str ~162ms. The bounds are generous because
;; absolute numbers drift ~7% between sessions and more on loaded CI — they catch
;; an order-of-magnitude regression, not a few percent. To judge a change, A/B/A
;; it in ONE session against a real `jolt run` program rather than trusting the
;; absolute number here.
(import (chezscheme))
(load "host/chez/rt.ss")
(set-chez-ns! "clojure.core")
(load "host/chez/seed/prelude.ss")
(load "host/chez/post-prelude.ss")
(set-chez-ns! "user")
(load "host/chez/host-contract.ss")
(load "host/chez/seed/image.ss")
(load "host/chez/compile-eval.ss")

(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000.0 (time-second t)) (/ (time-nanosecond t) 1000000.0))))

(define runs 3)
(define (best-ms expr)
  (let loop ((i 0) (best +inf.0))
    (if (fx>= i runs)
        best
        (let ((t0 (now-ms)))
          (jolt-compile-eval expr "user")
          (loop (fx+ i 1) (min best (- (now-ms) t0)))))))

(define failed? #f)
(define (report! label expr bound)
  (let ((ms (best-ms expr)))
    (printf "~a 200000 values: ~a ms (best of ~a)\n"
            label (/ (round (* 100 ms)) 100.0) runs)
    (when (> ms bound)
      (set! failed? #t)
      (printf "  FAIL: over the ~a ms guard\n" bound))))

(report! "print " "(with-out-str (dotimes [i 200000] (print i)))" 700)
(report! "pr-str" "(with-out-str (dotimes [i 200000] (pr-str i)))" 600)
(when failed? (exit 1))
