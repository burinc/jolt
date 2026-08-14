;; RRB property gate: pvec-catvec / pvec-slice against a naive list model, with
;; structural invariants checked after every mutating op. Run:
;;   chez --script test/chez/rrb-property-test.ss
;;
;; Seeded pseudo-random op sequences drive a pool of (model . pvec) pairs
;; through conj/pop/assoc/nth/catvec/slice/rebuild; after every op the pvec
;; must equal its model element-for-element through pvec-v, pvec-nth-d, AND the
;; seq/reduce walk, and every trie node must satisfy the RRB invariants
;; (cumulative size tables matching subtree counts, child bounds, leftwise
;; density of plain nodes, classic shape under a plain root). The seed prints
;; on failure so a red run reproduces.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (fail! seed step msg)
  (set! fails (+ fails 1))
  (printf "FAIL seed=~a step=~a: ~a\n" seed step msg))

;; --- deterministic PRNG (xorshift64*) ---------------------------------------
(define rng-state 1)
(define (rng-seed! s) (set! rng-state (if (= s 0) 88172645463325252 s)))
(define (rng!)
  (let* ((x rng-state)
         (x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 13)) #xFFFFFFFFFFFFFFFF))
         (x (bitwise-xor x (bitwise-arithmetic-shift-right x 7)))
         (x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 17)) #xFFFFFFFFFFFFFFFF)))
    (set! rng-state x)
    x))
(define (rnd n) (mod (rng!) n))     ; 0..n-1

;; --- structural invariants ---------------------------------------------------
;; -> subtree count, raising on any violated invariant
(define (check-node node level path)
  (cond
    ((fx=? level 0)
     (unless (vector? node) (error 'rrb-check (format "leaf not a vector at ~a" path)))
     (let ((n (vector-length node)))
       (unless (and (fx>=? n 1) (fx<=? n 32))
         (error 'rrb-check (format "leaf width ~a at ~a" n path)))
       n))
    ((rrbnode? node)
     (let* ((sizes (rrbnode-sizes node)) (cs (rrbnode-children node))
            (n (vector-length cs)))
       (unless (fx=? n (vector-length sizes))
         (error 'rrb-check (format "sizes/children length mismatch at ~a" path)))
       (unless (and (fx>=? n 1) (fx<=? n 32))
         (error 'rrb-check (format "branch width ~a at ~a" n path)))
       (let loop ((i 0) (sum 0))
         (if (fx<? i n)
             (let ((c (check-node (vector-ref cs i) (fx- level 5) (cons i path))))
               (unless (fx=? (vector-ref sizes i) (fx+ sum c))
                 (error 'rrb-check (format "size[~a]=~a, want ~a at ~a"
                                           i (vector-ref sizes i) (fx+ sum c) path)))
               (loop (fx+ i 1) (fx+ sum c)))
             sum))))
    ((vector? node)
     ;; plain branch: leftwise dense — all but the last child full for their level
     (let ((n (vector-length node)) (full (fxsll 1 level)))
       (unless (and (fx>=? n 1) (fx<=? n 32))
         (error 'rrb-check (format "plain branch width ~a at ~a" n path)))
       (let loop ((i 0) (sum 0))
         (if (fx<? i n)
             (let ((c (check-node (vector-ref node i) (fx- level 5) (cons i path))))
               (when (and (fx<? i (fx- n 1)) (fx>? n 1) (not (fx=? c full)))
                 (error 'rrb-check (format "plain prefix child ~a count ~a (full ~a) at ~a"
                                           i c full path)))
               (loop (fx+ i 1) (fx+ sum c)))
             sum))))
    (else (error 'rrb-check (format "unknown node kind at ~a" path)))))

(define (check-pvec p)
  (let* ((cnt (pvec-cnt p)) (tail (pvec-tail p)) (root (pvec-root p))
         (tailoff (fx- cnt (vector-length tail))))
    (unless (fx<=? (vector-length tail) 32) (error 'rrb-check "tail too wide"))
    (when (rrbnode? root)
      (unless (fx=? (check-node root (pvec-shift p) '()) tailoff)
        (error 'rrb-check "relaxed root count != tailoff")))
    (when (and (vector? root) (fx>? (vector-length root) 0))
      ;; plain root: the full classic contract
      (unless (fx=? 0 (fxand tailoff 31)) (error 'rrb-check "classic tailoff unaligned"))
      (unless (fx=? (check-node root (pvec-shift p) '()) tailoff)
        (error 'rrb-check "classic root count != tailoff"))
      ;; every classic leaf is full: leftwise density + aligned total makes the
      ;; last leaf full too, so spot-check the rightmost spine
      (let spine ((n root) (l (pvec-shift p)))
        (cond ((fx=? l 0) (unless (fx=? (vector-length n) 32)
                            (error 'rrb-check "classic partial leaf")))
              ((rrbnode? n) (error 'rrb-check "rrbnode under classic root"))
              (else (spine (vector-ref n (fx- (vector-length n) 1)) (fx- l 5))))))
    #t))

;; --- model equivalence -------------------------------------------------------
(define (model->vec m) (list->vector m))
(define (pvec-equal-model? p m seed step)
  (let* ((mv (model->vec m)) (n (vector-length mv)))
    (cond
      ((not (fx=? (pvec-cnt p) n)) (fail! seed step "count mismatch") #f)
      (else
       (let ((pv (pvec-v p)))
         (let loop ((i 0) (ok #t))
           (cond
             ((fx=? i n)
              ;; spot-check random-access agreement too
              (let spot ((k 0) (ok ok))
                (if (or (fx=? n 0) (fx=? k 8)) ok
                    (let ((i (rnd n)))
                      (if (equal? (pvec-nth-d p i 'missing) (vector-ref mv i))
                          (spot (fx+ k 1) ok)
                          (begin (fail! seed step (format "nth mismatch at ~a" i)) #f))))))
             ((equal? (vector-ref pv i) (vector-ref mv i)) (loop (fx+ i 1) ok))
             (else (fail! seed step (format "element mismatch at ~a" i)) #f))))))))

(define (check! p m seed step)
  (set! total (+ total 1))
  (guard (e (#t (fail! seed step
                       (format "invariant: ~a"
                               (if (message-condition? e) (condition-message e) e)))))
    (check-pvec p))
  (pvec-equal-model? p m seed step))

;; --- op sequences ------------------------------------------------------------
(define (fresh-pair size)
  ;; a classic vector built by conj
  (let loop ((i 0) (m '()) (p empty-pvec))
    (if (fx=? i size)
        (cons (reverse m) p)
        (loop (fx+ i 1) (cons i m) (pvec-conj p i)))))

(define (list-slice m start end)
  (let loop ((m m) (i 0) (acc '()))
    (cond ((fx>=? i end) (reverse acc))
          ((null? m) (reverse acc))
          ((fx>=? i start) (loop (cdr m) (fx+ i 1) (cons (car m) acc)))
          (else (loop (cdr m) (fx+ i 1) acc)))))

(define (run-sequence seed steps)
  (rng-seed! seed)
  (let ((pool (make-vector 6)))
    ;; seed the pool with varied shapes (empty, tail-only, multi-level)
    (vector-set! pool 0 (fresh-pair 0))
    (vector-set! pool 1 (fresh-pair (rnd 33)))
    (vector-set! pool 2 (fresh-pair (fx+ 33 (rnd 200))))
    (vector-set! pool 3 (fresh-pair (fx+ 1000 (rnd 1500))))
    (vector-set! pool 4 (fresh-pair (fx+ 40 (rnd 100))))
    (vector-set! pool 5 (fresh-pair (fx+ 2050 (rnd 100))))
    (let step-loop ((step 0))
      (when (fx<? step steps)
        (let* ((slot (rnd 6)) (pair (vector-ref pool slot))
               (m (car pair)) (p (cdr pair)) (n (pvec-cnt p))
               (op (rnd 10)))
          (when (getenv "RRB_TRACE")
            (printf "seed ~a step ~a op ~a slot ~a n ~a\n" seed step op slot n))
          (cond
            ;; conj
            ((fx<? op 2)
             (let* ((x (rnd 100000)) (p2 (pvec-conj p x)) (m2 (append m (list x))))
               (when (check! p2 m2 seed step) (vector-set! pool slot (cons m2 p2)))))
            ;; pop
            ((and (fx=? op 2) (fx>? n 0))
             (let ((p2 (pvec-pop p)) (m2 (list-slice m 0 (fx- n 1))))
               (when (check! p2 m2 seed step) (vector-set! pool slot (cons m2 p2)))))
            ;; assoc
            ((and (fx=? op 3) (fx>? n 0))
             (let* ((i (rnd n)) (x (rnd 100000))
                    (p2 (pvec-assoc p i x))
                    (m2 (append (list-slice m 0 i) (list x) (list-slice m (fx+ i 1) n))))
               (when (check! p2 m2 seed step) (vector-set! pool slot (cons m2 p2)))))
            ;; catvec with another pool entry
            ((fx<? op 7)
             (let* ((slot2 (rnd 6)) (pair2 (vector-ref pool slot2))
                    (p2 (pvec-catvec p (cdr pair2)))
                    (m2 (append m (car pair2))))
               (when (check! p2 m2 seed step)
                 ;; cap growth so sequences stay fast
                 (when (fx<? (pvec-cnt p2) 60000)
                   (vector-set! pool slot (cons m2 p2))))))
            ;; slice
            ((and (fx<? op 9) (fx>? n 0))
             (let* ((a (rnd n)) (b (fx+ a (rnd (fx+ 1 (fx- n a)))))
                    (p2 (pvec-slice p a b))
                    (m2 (list-slice m a b)))
               (when (check! p2 m2 seed step) (vector-set! pool slot (cons m2 p2)))))
            ;; rebuild a fresh classic vector into the slot
            (else (vector-set! pool slot (fresh-pair (rnd 300)))))
          (step-loop (fx+ step 1)))))))

;; --- reduce/seq agreement over an RRB'd shape --------------------------------
;; expose an RRB'd vector to jolt and walk it there: the chunked seq machinery
;; itself must handle relaxed leaves.
(define (sum-list m) (fold-left + 0 m))
(define (check-jolt-walk seed)
  (let* ((a (fresh-pair 1000)) (b (fresh-pair 700))
         (cat (pvec-catvec (cdr a) (cdr b)))
         (sl (pvec-slice cat 137 1391))
         (m (list-slice (append (car a) (car b)) 137 1391)))
    (def-var! "user" "__rrb-probe" sl)
    (set! total (+ total 1))
    (let ((got (jolt-final-str (jolt-compile-eval "(reduce + 0 __rrb-probe)" "user")))
          (want (number->string (sum-list m))))
      (unless (string=? got want)
        (fail! seed 'reduce (format "jolt reduce got ~a want ~a" got want))))
    (set! total (+ total 1))
    (let ((got (jolt-final-str (jolt-compile-eval "(count (filter odd? (map inc __rrb-probe)))" "user")))
          (want (number->string (length (filter odd? (map (lambda (x) (+ x 1)) m))))))
      (unless (string=? got want)
        (fail! seed 'chunk-walk (format "jolt chunked map/filter got ~a want ~a" got want))))
    (set! total (+ total 1))
    (let ((got (jolt-final-str (jolt-compile-eval "(= __rrb-probe (vec (seq __rrb-probe)))" "user"))))
      (unless (string=? got "true")
        (fail! seed 'seq-roundtrip "seq round-trip not equal")))))

;; --- run ---------------------------------------------------------------------
(let loop ((seed 1))
  (when (<= seed 300)
    (run-sequence seed 40)
    (loop (+ seed 1))))
(check-jolt-walk 9001)
(check-jolt-walk 9002)

;; equality/hash between a classic vector and its RRB'd equal
(let* ((a (fresh-pair 2000))
       (halves (pvec-catvec (pvec-slice (cdr a) 0 977) (pvec-slice (cdr a) 977 2000))))
  (set! total (+ total 1))
  (unless (jolt-truthy? (jolt=2 (cdr a) halves)) (fail! 9003 'eq "classic != rrb rebuild"))
  (set! total (+ total 1))
  (unless (= (jolt-hasheq (cdr a)) (jolt-hasheq halves)) (fail! 9003 'hash "hasheq differs")))

(printf "rrb-property: ~a checks, ~a failures\n" total fails)
(unless (= fails 0) (exit 1))
(printf "RRB-PROPERTY OK\n")
