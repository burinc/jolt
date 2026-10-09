;; collect-safe-stress.ss — collect-safe foreign calls under collections, for
;; jolt's lockfree-activation kernel patch (run by
;; collect-safe-activation-test.sh, plain Chez, no jolt). Threads park in
;; collect-safe calls while others allocate and request collections: a
;; collect-safe qsort whose collect-safe callback allocates (activation of a
;; thread that is in C, and back), sleepers in collect-safe usleep, sleepers in
;; a freshly compiled foreign procedure (young code the collector would move
;; if nothing locked it), plain callers, and a thread taking the tc mutex
;; from Scheme over and over, against the collections and returns that take
;; it to convert threads in collect-safe calls and to undo a conversion.
;; Every result is checked, a thread that raises is reported, and the run
;; must finish.
(load-shared-object #f)
(define usleep (foreign-procedure __collect_safe "usleep" (unsigned-32) int))
(define qsort (foreign-procedure __collect_safe "qsort" (void* size_t size_t void*) void))
(define safe-abs (foreign-procedure __collect_safe "abs" (int) int))
(define cmp
  (foreign-callable __collect_safe
    (lambda (a b)
      (let ([x (foreign-ref 'int a 0)] [y (foreign-ref 'int b 0)])
        (make-vector 8 x)                    ; allocate inside the callback
        (cond [(< x y) -1] [(> x y) 1] [else 0])))
    (void* void*) int))
(lock-object cmp)
(define cmp-addr (foreign-callable-entry-point cmp))
(define errors 0)
(define m (make-mutex))
(define (fail! what) (with-mutex m (set! errors (+ errors 1))) (printf "FAIL ~a\n" what))
(define (sorter rounds)
  (do ([r 0 (fx+ r 1)]) ((fx= r rounds))
    (let* ([n 200] [buf (foreign-alloc (* 4 n))])
      (do ([i 0 (fx+ i 1)]) ((fx= i n)) (foreign-set! 'int buf (* 4 i) (random 100000)))
      (qsort buf n 4 cmp-addr)
      (do ([i 1 (fx+ i 1)]) ((fx= i n))
        (when (> (foreign-ref 'int buf (* 4 (- i 1))) (foreign-ref 'int buf (* 4 i))) (fail! "unsorted")))
      (foreign-free buf))))
(define (sleeper rounds) (do ([r 0 (fx+ r 1)]) ((fx= r rounds)) (usleep 2000)))
;; The return address of a collect-safe call points into the code the
;; foreign-procedure form compiled to. Compile a fresh one each round, so
;; that code is young (gen 0, the generation the collector copies) while the
;; thread sleeps in it and the churners collect.
(define (fresh-sleeper rounds)
  (do ([r 0 (fx+ r 1)]) ((fx= r rounds))
    (let ([f (eval '(foreign-procedure __collect_safe "usleep" (unsigned-32) int))])
      (f 3000)
      (unless (fx= 0 (f 1)) (fail! "fresh usleep")))))
;; Take the tc mutex from Scheme the way with-tc-mutex does (record
;; definitions, the expander, port and hashtable internals all do). A plain
;; acquire converts nothing: only collect, compute-size-increments and a
;; thread waiting for a collection deactivate the threads sitting in
;; collect-safe calls on their behalf, and a converted thread takes this
;; mutex on its way back. This contends with both, and checks the count
;; those conversions keep never drops below this thread's own place.
(define (tc-mutex-taker rounds)
  (let ([tcm #%$tc-mutex])
    (do ([r 0 (fx+ r 1)]) ((fx= r rounds))
      (disable-interrupts)
      (mutex-acquire tcm)
      (unless (fx>= (#%$top-level-value '$active-threads) 1) (fail! "active count"))
      (mutex-release tcm)
      (enable-interrupts))))
(define (caller n)
  (let loop ([i 0])
    (when (fx< i n)
      (unless (fx= (safe-abs (fx- 0 i)) i) (fail! "abs"))
      (loop (fx+ i 1)))))
(define (churner rounds)
  (do ([r 0 (fx+ r 1)]) ((fx= r rounds))
    (let loop ([i 0] [acc '()]) (when (fx< i 20000) (loop (fx+ i 1) (cons (make-string 4) acc))))
    (when (fx= 0 (fxmod r 10)) (collect-rendezvous))))
(define done 0) (define c (make-condition))
(define (spawn thunk)
  (fork-thread
    (lambda ()
      (guard (e [#t (fail! (call-with-string-output-port (lambda (p) (display-condition e p))))])
        (thunk))
      (with-mutex m (set! done (+ done 1)) (condition-signal c)))))
(define jobs
  (list (lambda () (sorter 300)) (lambda () (sorter 300))
        (lambda () (sleeper 1500)) (lambda () (sleeper 1500))
        (lambda () (caller 20000000)) (lambda () (caller 20000000))
        (lambda () (fresh-sleeper 600)) (lambda () (fresh-sleeper 600))
        (lambda () (tc-mutex-taker 2000000))
        (lambda () (churner 400)) (lambda () (churner 400))))
(for-each spawn jobs)
(with-mutex m (let w () (unless (= done (length jobs)) (condition-wait c m) (w))))
(printf "stress: ~a errors, ~a collections\n" errors (collections))
(exit (if (= errors 0) 0 1))
