;; eval-test.ss — the G3 gate for the Gambit compiler path (jolt-mj95.4).
;;
;; Run via `make gambiteval` (detection-gated, from the repo root). Boots the
;; full manifest + the cross-minted :gambit seed, then drives real jolt SOURCE
;; through jolt-compile-eval and compares the jolt-pr-readable rendering
;; against values captured from the Chez build (bin/jolt -e "(pr-str EXPR)").
;; The same rows run compiled-to-js under node (manual; see the demo recipe in
;; the site docs) — this gate pins the gsi half.

(##include "boot.ss")

(define failures 0)

(define (check src expected)
  (let ((actual (guard (e (#t "THREW"))
                  (jolt-pr-readable (jolt-compile-eval src "user")))))
    (if (string=? actual expected)
        (printf "  ok     ~a => ~a\n" src actual)
        (begin (printf "  FAIL   ~a: got ~s expected ~s\n" src actual expected)
               (set! failures (+ failures 1))))))

(printf "== jolt source through jolt-compile-eval on gsi ==\n")

;; arithmetic + tower
(check "(+ 1 2)" "3")
(check "(* 2/3 6)" "4")
(check "(+ 9007199254740993 1)" "9007199254740994")
;; collections + rendering
(check "{:a 1 :b 2}" "{:a 1, :b 2}")
(check "(conj [1 2] 3)" "[1 2 3]")
(check "(assoc {:a 1} :b 2)" "{:a 1, :b 2}")
;; lazy seqs + HOFs through the prelude
(check "(map inc [1 2 3])" "(2 3 4)")
(check "(->> (range 100) (filter odd?) (map #(* % %)) (reduce +))" "166650")
(check "(->> (range 20) (filter even?) (map inc) (take 5) vec)" "[1 3 5 7 9]")
;; def + cross-row invocation + recursion
(check "(defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))" "#'user/fib")
(check "(fib 20)" "6765")
;; let/loop
(check "(let [x 10] (* x x))" "100")
(check "(loop [i 0 acc 0] (if (< i 5) (recur (inc i) (+ acc i)) acc))" "10")
;; strings + regex
(check "(str \"jolt on \" \"gambit\")" "\"jolt on gambit\"")
(check "(re-seq #\"[a-z]+\" \"jolt on gambit js\")" "(\"jolt\" \"on\" \"gambit\" \"js\")")
;; defmacro then use in a later row
(check "(defmacro unless2 [c a b] (list 'if c b a))" "nil")
(check "(unless2 false :yes :no)" ":yes")
;; try/catch
(check "(try (/ 1 0) (catch Exception e :caught))" ":caught")
;; sort with comparator
(check "(sort > [3 1 4 1 5 9 2 6])" "(9 6 5 4 3 2 1 1)")
;; records + protocols
(check "(defrecord Pt [x y])" "#'user/map->Pt")
(check "(:x (->Pt 3 4))" "3")
(check "(pr-str (->Pt 1 2))" "\"#user.Pt{:x 1, :y 2}\"")
(check "(defprotocol Shape (perim [s]))" "#'user/perim")
(check "(defrecord Sq [w] Shape (perim [s] (* 4 (:w s))))" "nil")
(check "(perim (->Sq 5))" "20")
;; multimethods
(check "(defmulti area :shape)" "#'user/area")
(check "(area {:shape :circle :r 21})" "THREW")   ; no method yet -> throws
(check "(defmethod area :circle [c] (* 2 (:r c)))" "#object[clojure.lang.MultiFn 0x0 \"area\"]")
(check "(area {:shape :circle :r 21})" "42")
;; anonymous fns + map results
(check "((fn [a b] {:sum (+ a b) :prod (* a b)}) 3 4)" "{:sum 7, :prod 12}")
;; the runtime target must never emit chez unsafe spellings
(check "(count \"gambit\")" "6")

;; a ^double-hinted fn compiles WITHOUT #3% in the emitted text (the R9
;; target-prims table at :gambit maps the unsafe prefix to "")
(let ((scm (jolt-analyze-emit-form
             (jolt-ce-read "(defn dd [^double x] (* x x))") "user")))
  (if (let loop ((i 0))
        (cond ((> (+ i 3) (string-length scm)) #f)
              ((string=? (substring scm i (+ i 3)) "#3%") #t)
              (else (loop (+ i 1)))))
      (begin (printf "  FAIL   ^double emission contains #3%\n")
             (set! failures (+ failures 1)))
      (printf "  ok     ^double emission carries no #3% (target-prims :gambit)\n")))

(printf "eval-test: ~a failure(s)\n" failures)
(if (= failures 0)
    (begin (display "eval-test: PASS — jolt compiles and evaluates on native gsi\n") (exit 0))
    (exit 1))
