;; Array-mode maps: the flat k/v slot representation (PersistentArrayMap).
;;   chez --script test/chez/arraymap-test.ss
;; Semantics are certified by the corpus; this pins the REPRESENTATION each mode
;; carries (a small map is one slot vector, never a trie; its transient is a
;; slot buffer; its seq view is vector-backed) and the promotion thresholds at
;; the representation level, so a regression back to a trie-backed small map
;; fails here even where every value test still passes.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (evv s) (jolt-compile-eval (string-append "(do " s ")") "user"))
(define (ev s) (jolt-final-str (evv s)))
(define (is name s expect) (ok (string-append name " => " expect) (string=? (ev s) expect)))
(define (kw n) (keyword #f n))

;; --- representation by mode --------------------------------------------------
(ok "literal map is a slot vector"
    (let ((m (evv "{:a 1 :b 2}")))
      (and (pmap? m) (pmap-array? m) (not (hnode? (pmap-root m)))
           (fx=? 4 (vector-length (pmap-root m))) (fx=? 2 (pmap-cnt m)))))
(ok "{} is the shared empty array map" (let ((m (evv "{}"))) (and (pmap-array? m) (eq? m (evv "{}")))))
(ok "hash-map is a trie at any size" (hnode? (pmap-root (evv "(hash-map :a 1)"))))
(ok "8 entries stay a slot vector" (pmap-array? (evv "(reduce (fn [m i] (assoc m i i)) {} (range 8))")))
(ok "the 9th non-keyword promotes to a trie" (hnode? (pmap-root (evv "(reduce (fn [m i] (assoc m i i)) {} (range 9))"))))
(ok "a 9th keyword rides array mode" (pmap-array? (evv "(assoc (reduce (fn [m i] (assoc m i i)) {} (range 8)) :k 1)")))
(ok "64 keywords stay a slot vector" (pmap-array? (evv "(reduce (fn [m i] (assoc m (keyword (str \"k\" i)) i)) {} (range 64))")))
(ok "the 65th keyword promotes" (hnode? (pmap-root (evv "(reduce (fn [m i] (assoc m (keyword (str \"k\" i)) i)) {} (range 65))"))))
(ok "array-map never promotes" (pmap-array? (evv "(apply array-map (range 40))")))
(ok "a literal past 8 with keyword tail is array mode" (pmap-array? (evv "{\"a\" 0 \"b\" 1 \"c\" 2 \"d\" 3 \"e\" 4 \"f\" 5 \"g\" 6 \"h\" 7 :i 8 :j 9}")))
(ok "a literal past 8 with a non-keyword tail is hash mode" (hnode? (pmap-root (evv "{:a 0 :b 1 :c 2 :d 3 :e 4 :f 5 :g 6 :h 7 \"i\" 8 :j 9}"))))
(ok "zipmap of 8 is array mode, of 9 hash mode"
    (and (pmap-array? (evv "(zipmap (range 8) (range 8))"))
         (hnode? (pmap-root (evv "(zipmap (range 9) (range 9))")))))
(ok "dissoc to empty is a fresh array map, not the {} singleton"
    (let ((m (evv "(dissoc {:a 1} :a)")))
      (and (pmap-array? m) (fx=? 0 (pmap-cnt m)) (not (eq? m (evv "{}"))))))
(ok "dissoc on a trie stays a trie" (hnode? (pmap-root (evv "(dissoc (hash-map :a 1 :b 2) :a)"))))

;; --- identity where the reference returns `this` ------------------------------
(ok "assoc of the held value is the same map (array)"
    (let ((m (evv "{:a 1 :b 2}"))) (eq? m (pmap-assoc m (kw "a") 1))))
(ok "assoc of the held value is the same map (hash)"
    (let ((m (evv "(hash-map :a 1 :b 2)"))) (eq? m (pmap-assoc m (kw "a") 1))))
(ok "assoc of a new value is a new map" (let ((m (evv "{:a 1}"))) (not (eq? m (pmap-assoc m (kw "a") 2)))))
(ok "dissoc of an absent key is the same map"
    (let ((m (evv "{:a 1}")) (h (evv "(hash-map :a 1)")))
      (and (eq? m (pmap-dissoc m (kw "z"))) (eq? h (pmap-dissoc h (kw "z"))))))

;; --- the seq view is vector-backed: O(1) count, no per-element cells ----------
(ok "seq of an array map carries its entries vector"
    (let ((s (jolt-seq (evv "{:a 1 :b 2 :c 3}"))))
      (and (cseq? s) (cseq-cvec s) (fx=? (cseq-kind s) sk-arraymap-seq)
           (fx=? 3 (pvec-count (cseq-cvec s))))))
(ok "seq of a hash map carries its entries vector"
    (let ((s (jolt-seq (evv "(hash-map :a 1 :b 2)"))))
      (and (cseq? s) (cseq-cvec s) (fx=? (cseq-kind s) sk-hashmap-seq))))
(ok "keys and vals are vector-backed"
    (let ((k (jolt-keys (evv "{:a 1 :b 2}"))) (v (jolt-vals (evv "{:a 1 :b 2}"))))
      (and (cseq-cvec k) (fx=? (cseq-kind k) sk-key-seq)
           (cseq-cvec v) (fx=? (cseq-kind v) sk-val-seq))))
(ok "rest of the seq view is still vector-backed"
    (let ((s (jolt-seq (evv "{:a 1 :b 2 :c 3}"))))
      (cseq-cvec (jolt-seq (seq-more s)))))

;; --- transients: a slot buffer with the reference's capacity rule -------------
(ok "transient of an array map is a 16-slot buffer"
    (let ((t (evv "(transient {:a 1})")))
      (and (jolt-transient? t) (tmap-array? t)
           (fx=? 16 (vector-length (jolt-transient-buf t))) (fx=? 1 (jolt-transient-n t)))))
(ok "transient of a 30-keyword array map keeps its 60 slots"
    (let ((t (evv "(transient (apply array-map (mapcat (fn [i] [(keyword (str \"k\" i)) i]) (range 30))))")))
      (fx=? 60 (vector-length (jolt-transient-buf t)))))
(ok "transient of a hash map is an editable trie" (not (tmap-array? (evv "(transient (hash-map :a 1))"))))
(ok "persistent! hands back a slot vector" (pmap-array? (evv "(persistent! (assoc! (transient {:a 1}) :b 2))")))
(ok "a promoted transient persists as a trie" (hnode? (pmap-root (evv "(persistent! (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 9)))"))))
(ok "the source map is untouched by the transient"
    (let ((m (evv "{:a 1}")))
      (let ((t (jolt-transient-new m)))
        (tmap-put! t (kw "a") 2)
        (tmap-put! t (kw "b") 3)
        (and (fx=? 1 (pmap-cnt m)) (eqv? 1 (pmap-get m (kw "a") #f))))))

;; --- value-level spot checks the representation must keep --------------------
(is "lookup by kind" "[(get {:a 1} 'a) (get {'a 1} :a) (get {\"a\" 1} 'a) (get {1 :i} 1.0) (get {1 :i} 1) (get {nil :n} nil)]" "[nil nil nil nil :i :n]")
(is "replace keeps position, append goes last" "(keys (assoc (assoc {:a 1 :b 2} :a 9) :c 3))" "(:a :b :c)")
(is "transient dissoc! swaps the last entry in" "(keys (persistent! (dissoc! (transient {:a 1 :b 2 :c 3}) :a)))" "(:c :b)")
(is "equal across modes" "[(= {:a 1 :b 2} (hash-map :b 2 :a 1)) (= (hash {:a 1 :b 2}) (hash (hash-map :b 2 :a 1)))]" "[true true]")
(is "reduce-kv folds in place" "(reduce-kv (fn [a k v] (if (= k :b) (reduced a) (+ a v))) 0 (array-map :a 1 :b 2 :c 3))" "1")
(is "count of the seq view" "[(count (seq {:a 1 :b 2 :c 3})) (count (rest (seq {:a 1 :b 2 :c 3}))) (count (keys (hash-map :a 1 :b 2)))]" "[3 2 2]")

(printf "arraymap-test: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
