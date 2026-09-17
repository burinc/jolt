;; Transient regression: mutable backing + snapshot-on-persist. Run:
;;   chez --script test/chez/transient-test.ss
;; Semantics are covered broadly by the corpus; this pins the invariants the
;; mutable implementation must keep AND that large builds stay linear (a
;; copy-on-write regression would make the 200k builds quadratic and time the
;; gate out).

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (ev s) (jolt-final-str (jolt-compile-eval (string-append "(do " s ")") "user")))
(define (is name s expect) (ok (string-append name " => " expect) (string=? (ev s) expect)))

;; --- mutation is in place; persistent! snapshots back -----------------------
(is "vector build" "(persistent! (reduce conj! (transient []) (range 5)))" "[0 1 2 3 4]")
(is "map build"    "(= {0 0 1 1 2 2} (persistent! (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 3))))" "true")
(is "set build"    "(count (persistent! (reduce conj! (transient #{}) [1 2 2 3])))" "3")
(is "pop!"         "(persistent! (pop! (conj! (transient [1 2]) 3)))" "[1 2]")
(is "dissoc!"      "(persistent! (dissoc! (assoc! (transient {}) :a 1 :b 2) :a))" "{:b 2}")
(is "disj!"        "(persistent! (disj! (conj! (transient #{}) :x :y) :x))" "#{:y}")

;; --- a transient never mutates its source -----------------------------------
(is "source map unchanged"    "(let [m {:a 1} _ (persistent! (assoc! (transient m) :b 2))] (= m {:a 1}))" "true")
(is "source vector unchanged" "(let [v [1 2] _ (persistent! (conj! (transient v) 3))] (= v [1 2]))" "true")

;; --- edges the implementation must keep -------------------------------------
(is "nil key"            "(get (persistent! (assoc! (transient {}) nil :v)) nil)" ":v")
(is "collection key"     "(get (persistent! (assoc! (transient {}) [1 2] :v)) [1 2])" ":v")
(is "dangling key pads"  "(= {:a 1 :b nil} (persistent! (assoc! (transient {}) :a 1 :b)))" "true")
(is "vector? is false"   "(vector? (transient []))" "false")
(is "transient sorted (cow)" "(persistent! (assoc! (transient (sorted-map :b 2)) :a 1))" "{:a 1, :b 2}")
(ok "lone key throws"        (guard (e (#t #t)) (ev "(persistent! (assoc! (transient {}) :a))") #f))
(ok "use after persistent!"  (guard (e (#t #t)) (ev "(let [t (transient [])] (persistent! t) (conj! t 1))") #f))

;; --- one-way promotion: a transient that grew past the array limit and shrank
;; back comes down a HASH map (JVM TransientArrayMap promotes on the way up and
;; never returns; jolt used to decide lazily from the final count).
(is "promoted stays hash (type)"
    "(type (persistent! (reduce dissoc! (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 20)) (range 17))))"
    "clojure.lang.PersistentHashMap")
(is "promoted stays hash (contents)"
    "(= {17 17 18 18 19 19} (persistent! (reduce dissoc! (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 20)) (range 17))))"
    "true")
;; a transient promotes at CAPACITY regardless of key type (TransientArrayMap:
;; the keyword-to-64 extension is the persistent assoc path only), so 9 keyword
;; keys through (transient {}) come out a hash map on the JVM and here.
(is "9 kw keys promote to hash" "(type (persistent! (reduce (fn [t k] (assoc! t k k)) (transient {}) (map keyword (map (fn [i] (str \"k\" i)) (range 9))))))" "clojure.lang.PersistentHashMap")
(is "8 kw keys stay array" "(keys (persistent! (reduce (fn [t k] (assoc! t k k)) (transient {}) (map keyword (map (fn [i] (str \"k\" i)) (range 8))))))" "(:k0 :k1 :k2 :k3 :k4 :k5 :k6 :k7)")
(is "transient of a large kw array map keeps its capacity" "(let [m (apply array-map (mapcat (fn [i] [(keyword (str \"k\" i)) i]) (range 12)))] (= (keys m) (keys (persistent! (transient m)))))" "true")

;; --- the leaf-sharing trap at DEPTH: a source map big enough to be a real HAMT ---
;; A claimed node's arr is a shallow copy, so the (cons k v) leaves still belong
;; to the source; overwriting a value must cons a fresh pair, never mutate one.
(is "source HAMT unchanged (1000)"
    "(let [m (into {} (map (fn [i] [i i]) (range 1000))) t (transient m)] (assoc! t 500 :new) (persistent! t) (get m 500))"
    "500")
(is "overwritten key in source HAMT (1000)"
    "(let [m (into {} (map (fn [i] [i i]) (range 1000))) t (transient m)] (assoc! t 500 :new) (get (persistent! t) 500))"
    ":new")
(is "source HAMT still equal (1000)"
    "(let [m (into {} (map (fn [i] [i i]) (range 1000))) t (transient m)] (assoc! t 500 :new) (persistent! t) (= m (into {} (map (fn [i] [i i]) (range 1000)))))"
    "true")

;; --- hash collisions through the editable path -------------------------------
;; "Aa" and "BB" share a hasheq, so they land in one collision bucket. The map
;; must be in HASH mode for that bucket to exist at all — with only a handful of
;; entries it stays an array map and the row proves nothing — so pad past the
;; array limit first. Each row re-asserts the collision itself, so if the pair
;; ever stops colliding these fail loudly instead of quietly going vacuous.
(is "collision pair still collides" "(= (hash \"Aa\") (hash \"BB\"))" "true")
(is "collision keys all retrievable"
    "(let [m (persistent! (reduce (fn [t s] (assoc! t s s)) (transient {}) (concat (map (fn [i] (str \"k\" i)) (range 50)) [\"Aa\" \"BB\"])))] (and (= 52 (count m)) (= \"Aa\" (get m \"Aa\")) (= \"BB\" (get m \"BB\")) (= (hash \"Aa\") (hash \"BB\"))))"
    "true")
(is "persistent dissoc collapses bucket"
    "(let [m (dissoc (persistent! (reduce (fn [t s] (assoc! t s s)) (transient {}) (concat (map (fn [i] (str \"k\" i)) (range 50)) [\"Aa\" \"BB\"]))) \"Aa\")] (and (= 51 (count m)) (= \"BB\" (get m \"BB\")) (nil? (get m \"Aa\"))))"
    "true")
(is "dissoc! collapses bucket"
    "(let [t (reduce (fn [t s] (assoc! t s s)) (transient {}) (concat (map (fn [i] (str \"k\" i)) (range 50)) [\"Aa\" \"BB\"])) _ (dissoc! t \"Aa\") m (persistent! t)] (and (= 51 (count m)) (= \"BB\" (get m \"BB\")) (nil? (get m \"Aa\"))))"
    "true")

;; --- linear, not quadratic: 200k builds finish near-instantly ---------------
(is "big vector build"  "(count (persistent! (reduce conj! (transient []) (range 200000))))" "200000")
(is "big map build"     "(count (persistent! (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 200000))))" "200000")
(is "big set build"     "(count (persistent! (reduce conj! (transient #{}) (range 200000))))" "200000")
(is "big map see-through count" "(let [t (reduce (fn [t i] (assoc! t i i)) (transient {}) (range 200000))] [(count t) (get t 199999) (contains? t 0)])" "[200000 199999 true]")
(is "big zipmap"        "(count (zipmap (range 200000) (range 200000)))" "200000")
(is "big array-map source" "(count (persistent! (reduce (fn [t i] (assoc! t i i)) (transient (apply array-map (range 200))) (range 200000))))" "200000")

;; --- a vector built from a flat source is built as a trie, not by conj ------
;; persistent! hands its buffer to make-pvec, which for more than 32 elements
;; conj'd one element at a time — each conj a fresh tail copy, so a 26k-element
;; build allocated 5.5 MB for 210 KB of leaves and took 1 ms. The trie is now
;; assembled bottom-up: leaves of 32 straight from the source, branches over
;; them, the last 1..32 as the tail — the shape every conj would have produced,
;; so nth/conj/pop/subvec/seq read it as any other vector. Bytes are
;; deterministic: per element, the leaf slot (8) plus the branch and tail
;; share, well under 16. The same build serves vec, (apply vector …), mapv and
;; jolt-vector with many arguments.
(define (bytes-per-element n thunk)
  (thunk)
  (let ((b0 (sstats-bytes (statistics))))
    (do ((i 0 (fx+ i 1))) ((fx= i 20)) (thunk))
    (quotient (quotient (- (sstats-bytes (statistics)) b0) 20) n)))
(let* ((n 26000) (src (make-vector n 7))
       (per (bytes-per-element n (lambda () (make-pvec src)))))
  (printf "  make-pvec from a flat ~a-element vector: ~a bytes/element\n" n per)
  (ok "make-pvec builds the trie in bulk (<= 16 bytes per element, was ~210)" (<= per 16)))
(let* ((n 26000)
       ;; compiled once; the source is a vector (reduce walks it with no seq cells),
       ;; so what is measured is conj!'s buffer growth plus persistent!'s trie
       (build (jolt-compile-eval "(let [v (vec (range 26000))] (fn [] (persistent! (reduce conj! (transient []) v))))" "user"))
       (per (bytes-per-element n (lambda () (jolt-invoke0 build)))))
  (printf "  conj! x26k + persistent!: ~a bytes/element\n" per)
  (ok "a large transient vector build stays under 48 bytes per element (buffer growth + trie)" (<= per 48)))
;; the bulk-built trie is the conj-built trie: same reads at every boundary
(let* ((n 1057)   ; 33 full leaves + a 1-element tail: a two-level root
       (src (let ((v (make-vector n))) (do ((i 0 (fx+ i 1))) ((fx= i n)) (vector-set! v i i)) v))
       (bulk (make-pvec src))
       (conjd (let loop ((p empty-pvec) (i 0)) (if (fx= i n) p (loop (pvec-conj p i) (fx+ i 1))))))
  (ok "bulk build has the conj build's count, shift, tail and root shape"
      (and (= (pvec-cnt bulk) (pvec-cnt conjd)) (= (pvec-shift bulk) (pvec-shift conjd))
           (equal? (pvec-tail bulk) (pvec-tail conjd)) (equal? (pvec-root bulk) (pvec-root conjd))))
  (ok "every element reads back, and conj/pop/nth after the bulk build agree with the list"
      (and (let lp ((i 0)) (or (fx= i n) (and (= i (pvec-nth-d bulk i #f)) (lp (fx+ i 1)))))
           (= n (pvec-nth-d (pvec-conj bulk n) n #f))
           (= (fx- n 1) (pvec-cnt (pvec-pop bulk)))
           (= (fx- n 2) (pvec-nth-d (pvec-pop bulk) (fx- n 2) #f)))))
(let* ((n 26000)
       (mv (jolt-compile-eval "(let [v (vec (range 26000))] (fn [] (mapv inc v)))" "user"))
       (per (bytes-per-element n (lambda () (jolt-invoke0 mv)))))
  (printf "  mapv inc over 26k: ~a bytes/element\n" per)
  (ok "mapv over one collection is the transient fold (<= 48 bytes per element, was ~180)" (<= per 48)))
(let ((sizes '(33 64 65 1024 1025 1056 1057 33000)))
  (ok "bulk and conj builds agree at every tail/root boundary"
      (let loop ((ss sizes))
        (or (null? ss)
            (let* ((n (car ss))
                   (src (let ((v (make-vector n))) (do ((i 0 (fx+ i 1))) ((fx= i n)) (vector-set! v i i)) v))
                   (bulk (make-pvec src))
                   (conjd (let lp ((p empty-pvec) (i 0)) (if (fx= i n) p (lp (pvec-conj p i) (fx+ i 1))))))
              (and (= (pvec-shift bulk) (pvec-shift conjd))
                   (equal? (pvec-root bulk) (pvec-root conjd))
                   (equal? (pvec-tail bulk) (pvec-tail conjd))
                   (loop (cdr ss))))))))

(printf "~a/~a passed~n" (- total fails) total)
(exit (if (zero? fails) 0 1))
