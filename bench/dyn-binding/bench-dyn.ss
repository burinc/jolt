;; bench/dyn-binding/bench-dyn.ss — the dynamic-var binding stack (jolt-3bo).
;;
;; One phase per invocation:  chez --script bench/dyn-binding/bench-dyn.ss <phase>
;; Run the whole set via bench/dyn-binding/run.sh, wired in as `make dynbench`.
;; Opt-in; NOT part of make test / make ci.
;;
;; WHAT THIS IS FOR. Reading a dynamic var and pushing a binding frame trade
;; against each other, and every design for the stack picks a point on that
;; trade. This harness measures BOTH sides so the choice is made on numbers:
;;
;;   read    lookup cost against stack DEPTH, for the three answers that behave
;;           differently — bound in the innermost frame, bound in the bottom
;;           frame, bound nowhere.
;;   width   lookup cost against the number of DISTINCT vars in scope, at a
;;           fixed depth. A design that indexes by var pays here; one that walks
;;           frames does not.
;;   push    push+pop throughput against frame size, at a shallow and a deep
;;           stack. This is the side a faster lookup is likely to charge, and
;;           `binding` is hot — the compiler's back end pushes a frame per fn
;;           literal and per arity.
;;   emit    the workload that raised this (jolt-puw): analyze + passes + emit
;;           of N nested fn literals. The back end binds 4 vars per literal and
;;           2 more per arity, so the stack is ~2N deep while the innermost body
;;           keeps reading vars bound at the bottom or nowhere.
;;   compile a real namespace compiled from source, end to end. The guard on the
;;           other side: if a lookup fix charges push too much, this is where it
;;           shows up, because ordinary code pushes far more than it nests.
;;
;; Every timing is a median of repeated trials, not a single run, and each phase
;; prints the raw per-trial numbers so a noisy machine is visible rather than
;; averaged away.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(printf "bench: chez ~a threaded ~a\n" (scheme-version) (threaded?))
(flush-output-port (current-output-port))

(define argv (command-line))
(define (arg i dflt) (if (fx<? i (length argv)) (list-ref argv i) dflt))

(define (mono-nanos)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000000000 (time-second t)) (time-nanosecond t))))

;; median of TRIALS runs of THUNK, in nanoseconds. Median and not mean: one GC
;; landing inside a trial should not move the reported number.
(define (median-ns trials thunk)
  (let loop ((i 0) (acc '()))
    (if (fx=? i trials)
        (let ((s (sort < acc))) (list-ref s (quotient trials 2)))
        (let* ((t0 (mono-nanos))
               (_ (thunk))
               (t1 (mono-nanos)))
          (loop (fx+ i 1) (cons (- t1 t0) acc))))))

(define (ns-per median-total reps) (/ (exact->inexact median-total) reps))

;; --- the probe vars ----------------------------------------------------------
;; Real interned cells marked ^:dynamic, so push goes through the same validation
;; the product does. Named apart from anything the runtime binds itself.
(define dyn-meta (jolt-hash-map (keyword #f "dynamic") #t))
(define (probe-var i)
  (let ((c (jolt-var "bench.dyn" (string-append "*p" (number->string i) "*"))))
    (var-cell-meta-set! c dyn-meta)
    c))
(define probes (let loop ((i 0) (acc '()))
                 (if (fx=? i 64) (reverse acc) (loop (fx+ i 1) (cons (probe-var i) acc)))))
(define (nth-probe i) (list-ref probes i))
;; never pushed by anything: the "bound nowhere" answer
(define absent (probe-var 999))

(define (push-frame! cells val)
  (jolt-push-thread-bindings
   (let loop ((cs cells) (m (jolt-hash-map)))
     (if (null? cs) m (loop (cdr cs) (pmap-assoc m (car cs) val))))))

(define (push-depth! d cell)
  (let loop ((i 0)) (when (fx<? i d) (push-frame! (list cell) i) (loop (fx+ i 1)))))
(define (pop-n! d)
  (let loop ((i 0)) (when (fx<? i d) (jolt-pop-thread-bindings) (loop (fx+ i 1)))))

;; The read under test is the one compiled code actually emits — var-cell-deref,
;; the already-resolved-cell path — not the internal dyn-binding-value, so the
;; number includes whatever the read path costs around the lookup.
(define (read-loop cell reps)
  (lambda ()
    (let loop ((n 0)) (when (fx<? n reps) (var-cell-deref cell) (loop (fx+ n 1))))))

;; --- 1. read: cost against DEPTH ---------------------------------------------
;; Three answers, one stack. innermost: the var the top frame binds. bottom: the
;; var only the very first frame binds, so a walk has to cross everything.
;; absent: bound nowhere, which a walk can only answer by crossing everything.
;;
;; The BOTTOM frame binds both, so `inner` is in the innermost frame at every
;; depth including 1. Binding it only in frames 1..d-1 left the innermost column
;; measuring an unbound var at depth 1, i.e. the absent case under another name.
(define (phase-read)
  (define reps 200000)
  (printf "phase: read (~a reps per trial, ns/read)\n" reps)
  (printf "~10a ~14a ~14a ~14a\n" "depth" "innermost" "bottom" "absent")
  (for-each
   (lambda (d)
     (let ((bottom (nth-probe 0)) (inner (nth-probe 1)))
       (push-frame! (list bottom inner) 'b)
       (push-depth! (fx- d 1) inner)
       (let ((i (ns-per (median-ns 5 (read-loop inner reps)) reps))
             (b (ns-per (median-ns 5 (read-loop bottom reps)) reps))
             (a (ns-per (median-ns 5 (read-loop absent reps)) reps)))
         (printf "~10a ~14,2f ~14,2f ~14,2f\n" d i b a))
       (pop-n! d)))
   '(1 2 4 8 16 32 64 128 256 512))
  (printf "read: done\n"))

;; --- 2. read: cost against WIDTH ---------------------------------------------
;; One frame, W distinct vars in it, and the stack kept shallow. A frame-walking
;; design is O(W) inside the frame's alist; an indexed one is flat.
(define (phase-width)
  (define reps 200000)
  (printf "phase: width (one frame, W distinct vars, ~a reps per trial, ns/read)\n" reps)
  (printf "~10a ~14a ~14a\n" "width" "first-in-frame" "last-in-frame")
  (for-each
   (lambda (w)
     (let ((cells (let loop ((i 0) (acc '()))
                    (if (fx=? i w) (reverse acc) (loop (fx+ i 1) (cons (nth-probe i) acc))))))
       (push-frame! cells 'v)
       (let ((f (ns-per (median-ns 5 (read-loop (car cells) reps)) reps))
             (l (ns-per (median-ns 5 (read-loop (list-ref cells (fx- w 1)) reps)) reps)))
         (printf "~10a ~14,2f ~14,2f\n" w f l))
       (jolt-pop-thread-bindings)))
   '(1 2 4 8 16 32 64))
  (printf "width: done\n"))

;; --- 3. push+pop throughput ---------------------------------------------------
;; The side a faster lookup is likely to charge. Measured at a SHALLOW stack (the
;; ordinary case — a binding in a hot fn) and at a DEEP one (a design whose push
;; copies an index proportional to what is already in scope pays only here).
(define (phase-push)
  (define reps 100000)
  (printf "phase: push (~a push+pop pairs per trial, ns/pair)\n" reps)
  (printf "~10a ~10a ~14a\n" "base-depth" "frame-vars" "ns/push+pop")
  (for-each
   (lambda (base)
     (push-depth! base (nth-probe 0))
     (for-each
      (lambda (k)
        (let* ((cells (let loop ((i 0) (acc '()))
                        (if (fx=? i k) (reverse acc) (loop (fx+ i 1) (cons (nth-probe i) acc)))))
               (frame (let loop ((cs cells) (m (jolt-hash-map)))
                        (if (null? cs) m (loop (cdr cs) (pmap-assoc m (car cs) 7)))))
               (t (median-ns 5 (lambda ()
                                 (let loop ((n 0))
                                   (when (fx<? n reps)
                                     (jolt-push-thread-bindings frame)
                                     (jolt-pop-thread-bindings)
                                     (loop (fx+ n 1))))))))
          (printf "~10a ~10a ~14,2f\n" base k (ns-per t reps))))
      '(1 4 16))
     (pop-n! base))
   '(0 64 256))
  (printf "push: done\n"))

;; --- 4. emit: the jolt-puw workload -------------------------------------------
;; N nested fn literals. The back end binds per literal and per arity, so this is
;; the shape whose cost is quadratic in N when a lookup is O(depth). Reported per
;; stage, because only emit is expected to move.
(define (nest-src n)
  (let loop ((i (fx- n 1)) (s "0"))
    (if (fx<? i 0)
        s
        (loop (fx- i 1)
              (string-append "(fn* [w" (number->string i) "] " s ")")))))
(define (phase-emit)
  (printf "phase: emit (N nested fn literals, ms per stage)\n")
  (printf "~8a ~12a ~12a ~12a ~12a\n" "N" "analyze" "passes" "emit" "text-bytes")
  (for-each
   (lambda (n)
     (let* ((src (string-append "(fn [] " (nest-src n) ")"))
            (form (jolt-ce-read src))
            (ctx (make-analyze-ctx "bench.dyn"))
            (a-node #f) (p-node #f) (out #f)
            (ta (median-ns 3 (lambda () (set! a-node (jolt-ce-analyze ctx form)))))
            (tp (median-ns 3 (lambda () (set! p-node (jolt-ce-run-passes a-node ctx)))))
            (te (median-ns 3 (lambda () (set! out (jolt-ce-emit p-node))))))
       (printf "~8a ~12,2f ~12,2f ~12,2f ~12a\n"
               n (/ ta 1e6) (/ tp 1e6) (/ te 1e6) (string-length out))))
   '(30 60 120 240))
  (printf "emit: done\n"))

;; --- 5. compile: the guard on the push side -----------------------------------
;; A real namespace, compiled from source the way the loader does it. Ordinary
;; code is wide and shallow — many pushes, little nesting — so a lookup fix that
;; charges push shows up here and nowhere else in this file.
(define (phase-compile)
  (define file (arg 2 "stdlib/clojure/set.clj"))
  (printf "phase: compile (~a)\n" file)
  (let* ((src (call-with-input-file file
                (lambda (p)
                  (let loop ((acc '()))
                    (let ((c (read-char p)))
                      (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc))))))))
         (n (string-length src))
         ;; analyze+emit every top-level form, without evaluating any of them:
         ;; evaluation would run the ns form and change what later forms resolve
         ;; to, and the cost under test is the compile, not the load.
         ;; the reader's own termination protocol (compile-eval.ss): it is a form
         ;; when the index ADVANCED and rdr-eof? is false. Testing eof alone spins
         ;; forever on trailing whitespace, which is how every source file ends.
         (once (lambda ()
                 (let loop ((i 0) (total 0))
                   (let-values (((f j) (rdr-read-form src i n)))
                     (if (or (not (> j i)) (rdr-eof? f))
                         total
                         (let ((ctx (make-analyze-ctx "bench.dyn.compile")))
                           (loop j (+ total
                                      (guard (e (#t 0))
                                        (string-length
                                         (jolt-ce-emit (jolt-ce-run-passes
                                                        (jolt-ce-analyze ctx f) ctx)))))))))))))
    (let ((t (median-ns 5 once)))
      (printf "compile ~a: ~,2f ms (emitted ~a bytes)\n" file (/ t 1e6) (once)))))

(case (string->symbol (arg 1 "usage"))
  ((read)    (phase-read))
  ((width)   (phase-width))
  ((push)    (phase-push))
  ((emit)    (phase-emit))
  ((compile) (phase-compile))
  (else
   (printf "usage: bench-dyn.ss <phase>\n")
   (printf "  read | width | push | emit | compile [FILE]\n")
   (exit 1)))
(exit 0)
