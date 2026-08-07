;; profile-test.ss — the gate for build profiles (make gambitprofile).
;;
;; Runs against the generated `repl` profile: clojure.core and the compiler in,
;; regex out. Two things have to hold for the mechanism to be worth having —
;; the language still works without the excluded group, and asking for the
;; excluded feature says so rather than dying on an unbound name.
;;
;; gen-boot.ss writes boot-repl.ss; make regenerates it before running this.

(##include "boot-repl.ss")

(define failures 0)

(define (report ok label detail)
  (if ok
      (printf "  ok     ~a\n" label)
      (begin (printf "  FAIL   ~a: ~a\n" label detail)
             (set! failures (+ failures 1)))))

(define (evals-to label src expected)
  (let ((actual (guard (e (#t (string-append "THREW " (profile-error-text e))))
                  (jolt-pr-readable (jolt-compile-eval src "user")))))
    (report (and (string? actual) (string=? actual expected)) label
            (string-append "got " actual " expected " expected))))

(define (profile-error-text e)
  (or (guard (ee (#t #f))
        (let ((v (jolt-unwrap-throw e)))
          (and (jolt-ex-info-record? v) (jolt-ex-info-record-message v))))
      (guard (ee (#t #f)) (condition-message e))
      "?"))

;; The message must name the group, so a user reads "regex was excluded" rather
;; than being left to infer it from a missing name.
(define (excluded-with-group label src group)
  (let ((msg (guard (e (#t (profile-error-text e)))
               (jolt-compile-eval src "user")
               "NO-RAISE")))
    (report (and (string? msg)
                 (let loop ((i 0))
                   (cond ((> (+ i (string-length group)) (string-length msg)) #f)
                         ((string=? (substring msg i (+ i (string-length group))) group) #t)
                         (else (loop (+ i 1))))))
            label
            (string-append "message did not name the group: " msg))))

(printf "== profile repl: the language without the regex group ==\n")

(evals-to "arithmetic" "(+ 1 2)" "3")
(evals-to "collections" "(assoc {:a 1} :b 2)" "{:a 1, :b 2}")
(evals-to "lazy seqs" "(->> (range 100) (filter odd?) (map inc) (reduce +))" "2550")
(evals-to "defn and recursion"
          "(do (defn f [n] (if (< n 2) n (+ (f (- n 1)) (f (- n 2))))) (f 15))" "610")
(evals-to "records" "(do (defrecord Pt [x y]) (pr-str (->Pt 1 2)))"
          "\"#user.Pt{:x 1, :y 2}\"")
(evals-to "multimethods"
          "(do (defmulti area :shape) (defmethod area :circle [c] (* 2 (:r c))) (area {:shape :circle :r 21}))"
          "42")
(evals-to "host clock still real" "(> (current-time-ms) 1700000000000)" "true")

(printf "== the excluded group reports itself ==\n")

(excluded-with-group "re-seq" "(re-seq #\"[a-z]+\" \"ab cd\")" "regex")
(excluded-with-group "re-find" "(re-find #\"x\" \"x\")" "regex")
(excluded-with-group "re-pattern" "(re-pattern \"x\")" "regex")
;; clojure.string reaches regex internally, so the report has to survive the
;; indirection rather than only covering the names a user typed
(excluded-with-group "clojure.string/split"
                     "(clojure.string/split \"a,b\" #\",\")" "regex")

;; A predicate over a type this build cannot hold answers instead of raising —
;; a value simply is not a regex here.
(evals-to "regex? answers false" "(regex? 1)" "false")

(printf "profile-test: ~a failure(s)\n" failures)
(if (= failures 0)
    (begin (display "profile-test: PASS — reduced profile runs, excluded group named\n")
           (exit 0))
    (exit 1))
