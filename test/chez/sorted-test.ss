;; Sorted collections: the tree walk behind seq/rseq/keys/vals/subseq, and the
;; hash and = of a sorted map/set. Run:
;;   chez --script test/chez/sorted-test.ss
;; Values are pinned to JVM Clojure (each was checked against it). Scaling is
;; pinned as ALLOCATION, which is deterministic where wall time is not: reaching
;; the head of a seq over a sorted coll used to run the whole tree into a vector
;; (O(n) bytes), a subseq walk re-descended from the root for every node without a
;; right child, and hash / = rebuilt a full hash map on every call.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-final-str (jolt-compile-eval (string-append "(do " s ")") "user")))
(define (is s expect)
  (let ((got (guard (e (#t "<threw>")) (ev s))))
    (ok (string-append s " => " expect " (got " got ")") (string=? got expect))))

(ev "(def sm (into (sorted-map) (map (fn [i] [i (* 10 i)]) (range 0 100 3))))")
(ev "(def ss (into (sorted-set) (range 0 100 3)))")
(ev "(def rs (sorted-set-by > 1 5 3 9 7))")

;; --- the walk: order, both directions, every view ---------------------------
(is "(take 3 sm)" "([0 0] [3 30] [6 60])")
(is "(take 3 (rseq sm))" "([99 990] [96 960] [93 930])")
(is "(= (reverse (seq ss)) (rseq ss))" "true")
(is "(= (range 0 100 3) (seq ss) (keys sm))" "true")
(is "(= (map #(* 10 %) (range 0 100 3)) (vals sm))" "true")
(is "(seq rs)" "(9 7 5 3 1)")
(is "(rseq rs)" "(1 3 5 7 9)")
(is "(nth (seq ss) 33)" "99")
(is "(count (seq ss))" "34")
(is "(reduce + (rseq ss))" "1683")
(is "(into [] (map inc) (take 5 (drop 30 ss)))" "[91 94 97 100]")
(is "[(seq (sorted-map)) (rseq (sorted-set)) (keys (sorted-map)) (vals (sorted-map))]" "[nil nil nil nil]")
;; the walk crosses chunk boundaries (32 nodes) at every size around them
(is "(every? (fn [n] (let [s (into (sorted-set) (range n))] (and (= (range n) (seq s)) (= (reverse (range n)) (rseq s))))) [31 32 33 63 64 65 1000])" "true")
;; the JVM's classes: a map's seq is PersistentTreeMap$Seq both ways, keys/vals
;; and a set's seq are KeySeq/ValSeq, and none of them is chunked
(is "(map class [(seq sm) (rseq sm) (next (seq sm))])"
    "(clojure.lang.PersistentTreeMap$Seq clojure.lang.PersistentTreeMap$Seq clojure.lang.PersistentTreeMap$Seq)")
(is "(map class [(seq ss) (rseq ss) (keys sm) (vals sm)])"
    "(clojure.lang.APersistentMap$KeySeq clojure.lang.APersistentMap$KeySeq clojure.lang.APersistentMap$KeySeq clojure.lang.APersistentMap$ValSeq)")
(is "(chunked-seq? (seq sm))" "false")

;; --- subseq / rsubseq: clojure.core's definitions over seqFrom --------------
(is "(subseq ss > 10)" "(12 15 18 21 24 27 30 33 36 39 42 45 48 51 54 57 60 63 66 69 72 75 78 81 84 87 90 93 96 99)")
(is "(take 2 (subseq ss >= 9))" "(9 12)")
(is "(subseq ss < 10)" "(0 3 6 9)")
(is "[(subseq ss > 1000) (subseq ss < -1) (subseq (sorted-set) > 1)]" "[nil () nil]")
(is "(subseq ss > 10 < 30)" "(12 15 18 21 24 27)")
(is "(subseq ss >= 9 <= 30)" "(9 12 15 18 21 24 27 30)")
(is "(subseq ss > 50 < 30)" "()")
(is "(subseq ss < 50 > 90)" "()")
(is "(rsubseq ss < 10)" "(9 6 3 0)")
(is "(rsubseq ss <= 9)" "(9 6 3 0)")
(is "(take 2 (rsubseq ss > 10))" "(99 96)")
(is "(rsubseq ss >= 9 <= 30)" "(30 27 24 21 18 15 12 9)")
(is "(subseq sm > 10 <= 30)" "([12 120] [15 150] [18 180] [21 210] [24 240] [27 270] [30 300])")
(is "(rsubseq sm >= 10 < 30)" "([27 270] [24 240] [21 210] [18 180] [15 150] [12 120])")
(is "[(subseq rs > 5) (subseq rs < 5) (rsubseq rs > 5) (rsubseq rs <= 5)]" "[(3 1) (9 7) (1 3) (5 7 9)]")
(is "[(subseq rs >= 7 <= 3) (rsubseq rs >= 7 <= 3)]" "[(7 5 3) (3 5 7)]")
(is "(map class [(subseq ss > 10) (subseq ss < 10)])" "(clojure.lang.APersistentMap$KeySeq clojure.lang.LazySeq)")

;; clojure.lang.Sorted's own methods: seqFrom is the same seeked walk (it used
;; to filter the whole seq, and read a set's elements as entries)
(is "[(take 3 (.seqFrom ss 10 true)) (take 3 (.seqFrom sm 10 false)) (.seqFrom ss 100 true) (take 2 (.seq ss false))]"
    "[(12 15 18) ([9 90] [6 60] [3 30]) nil (99 96)]")

;; --- hash: the hash of the equivalent hash map/set, cached ------------------
(is "[(= (hash sm) (hash (into {} sm))) (= (hash ss) (hash (into #{} ss)))]" "[true true]")
(is "[(= (hash (sorted-map)) (hash {})) (= (hash (sorted-set)) (hash #{}))]" "[true true]")
(is "(hash (sorted-set-by compare [1 2] [3]))" "-949793658")
(is "(let [m (with-meta sm {:x 1})] [(= m sm) (= (hash m) (hash sm))])" "[true true]")
(is "[(get {sm 1} (into {} sm)) (get {(into {} sm) 1} sm) (contains? #{ss} (into #{} ss))]" "[1 1 true]")

;; --- = across the map/set types; the comparator is not part of equality ----
(is "[(= sm (into {} sm)) (= (into {} sm) sm) (= ss (into #{} ss)) (= (into #{} ss) ss)]" "[true true true true]")
(is "[(= sm (dissoc (into {} sm) 0)) (= sm (assoc (into {} sm) 0 1)) (= ss (conj (into #{} ss) 1000))]" "[false false false]")
(is "[(= sm (into (sorted-map) sm)) (= ss (into (sorted-set-by >) ss)) (= rs #{1 5 3 9 7})]" "[true true true]")
(is "[(= (sorted-map 1 2) (sorted-map 1 3)) (= (sorted-map 1 2) (sorted-set 1)) (= (sorted-set 1) [1])]" "[false false false]")
(is "[(= (sorted-map :a 1) (sorted-map :b 1)) (= (sorted-set :a) (sorted-set :b)) (= (sorted-set) #{}) (= (sorted-map) {})]" "[false false true true]")
(is "[(= (sorted-map 1 nil) {2 nil}) (= (sorted-map 1 nil) {1 nil}) (= (sorted-map nil 1) {nil 1})]" "[false true true]")

;; --- scaling, as bytes allocated --------------------------------------------
(define (bytes-of thunk reps)
  (thunk)
  (let ((b0 (sstats-bytes (statistics))))
    (do ((i 0 (fx+ i 1))) ((fx= i reps)) (thunk))
    (quotient (- (sstats-bytes (statistics)) b0) reps)))
;; the same op over n and 4n entries; f is compiled once per size
(define (at-sizes src)
  (map (lambda (n)
         (let ((f (jolt-compile-eval
                    (format "(let [sm (into (sorted-map) (map (fn [i] [i i]) (range ~a))) ss (into (sorted-set) (range ~a)) ss2 (into (sorted-set) (range (inc ~a)))] (fn [] ~a))" n n n src)
                    "user")))
           (bytes-of (lambda () (jolt-invoke0 f)) 10)))
       '(10000 40000)))
(define (flat name src limit)
  (let* ((bs (at-sizes src)) (a (car bs)) (b (cadr bs)))
    (printf "  ~a: ~a bytes at 10k, ~a at 40k\n" name a b)
    (ok (format "~a does not grow with the coll (~a -> ~a bytes, limit ~a)" name a b limit)
        (and (<= a limit) (<= b limit)))))
;; each was O(n): the whole tree into a vector, then a cell per element
(flat "(first (seq sm))" "(first (seq sm))" 8000)
(flat "(doall (take 3 sm))" "(doall (take 3 sm))" 8000)
(flat "(first (rseq sm))" "(first (rseq sm))" 8000)
(flat "(first (keys sm))" "(first (keys sm))" 8000)
(flat "(second (vals sm))" "(second (vals sm))" 8000)
(flat "(first (subseq ss >= 5000))" "(first (subseq ss >= 5000))" 8000)
(flat "(first (rsubseq ss < 5000))" "(first (rsubseq ss < 5000))" 8000)
;; the hash is computed once per value; = of different counts is a count compare
(flat "a repeated (hash sm)" "(hash sm)" 256)
(flat "(= ss ss2) with different counts" "(= ss ss2)" 1024)
;; and = of equal colls walks the trees without building a hash coll, where the
;; conversion allocated a HAMT per side
(let* ((n 40000)
       (f (jolt-compile-eval (format "(let [a (into (sorted-set) (range ~a)) b (into (sorted-set) (range ~a))] (fn [] (= a b)))" n n) "user"))
       (per (quotient (bytes-of (lambda () (jolt-invoke0 f)) 10) n)))
  (printf "  = of two equal 40k sorted sets: ~a bytes/entry\n" per)
  (ok "= of two equal sorted sets walks both trees (<= 48 bytes per entry, was ~2600)" (<= per 48)))
;; a full walk stays linear and allocates no more than the eager vector did
(let* ((n 40000)
       (f (jolt-compile-eval (format "(let [sm (into (sorted-map) (map (fn [i] [i i]) (range ~a)))] (fn [] (loop [s (seq sm) a 0] (if s (recur (next s) (+ a (val (first s)))) a))))" n) "user"))
       (per (quotient (bytes-of (lambda () (jolt-invoke0 f)) 5) n)))
  (printf "  full next-walk of a 40k sorted map: ~a bytes/entry\n" per)
  (ok "a full walk allocates no more than the eager vector walk did (<= 200 bytes per entry, was ~376)" (<= per 200)))
;; a bounded subseq walks on from the node it found: one comparator call per
;; entry for the bound, plus the seek. Re-descending from the root for every node
;; without a right child made it O(n log n) calls (~24k here).
(is "(let [c (atom 0) s (into (sorted-set-by (fn [a b] (swap! c inc) (compare a b))) (range 4096))] (reset! c 0) (dorun (subseq s > -1 < 5000)) (<= @c 4200))" "true")
(is "(let [c (atom 0) s (into (sorted-set-by (fn [a b] (swap! c inc) (compare a b))) (range 4096))] (reset! c 0) (dorun (rsubseq s > -1 < 5000)) (<= @c 4200))" "true")

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
