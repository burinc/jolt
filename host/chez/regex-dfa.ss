;; regex-dfa.ss — jolt's nfa->dfa, replacing the vendored irregex one.
;;
;; irregex compiles a group-free pattern to a DFA (regex.ss says why capturing
;; patterns keep the backtracker instead). The conversion is Laurikari's tagged
;; NFA->DFA: each DFA state is a MULTI-STATE, a vector with one slot per NFA
;; state. Two things in the vendored version make a large pattern pathological,
;; and one real pattern hit both — a 50-alternative union with two unbounded
;; `.*` branches, 873 characters, from a retry classifier (#945). It took ~5s to
;; match the first time on x86_64 and did not terminate at all on aarch64:
;;
;;   1. The "have I already built this state?" test was (assoc st marked-states)
;;      — a linear scan of every state built so far, each comparison an equal?
;;      over a vector with one slot per NFA state. 2208 NFA states and 4113 DFA
;;      states made that ~8M whole-vector comparisons, and it is QUADRATIC, so it
;;      is the part that turns a large pattern into a hang. A multi-state already
;;      carries a hash of its contents (slot 2, maintained by every mutator), and
;;      equal? multi-states necessarily have equal hashes, so bucketing by it is
;;      exact: the scan within a bucket is the same assoc as before.
;;
;;   2. Nothing bounded the WORK. The state count is capped (10x the NFA's), but
;;      a union of unbounded branches explodes multiplicatively and reaching that
;;      cap — only to give up and fall back to the backtracker — is itself the
;;      cost. Ten `a.*b` branches spent 78ms to fail; twenty spent 750ms.
;;
;; So the conversion now carries a work budget, and going over it is the same
;; answer as going over the state cap: #f, which is irregex's signal to compile
;; the pattern with the backtracking matcher instead. That is not a lesser
;; engine — java.util.regex is a backtracker, so it is the semantics jolt is
;; matching anyway; the DFA is a match-time optimization, and the budget is the
;; line past which buying it costs more than it returns.
;;
;; The unit of work is "multi-state slots touched": each transition expanded
;; costs the number of NFA states in the multi-state it came from, which is what
;; the closure and reach computations walk. It is a deterministic count, not a
;; clock, so a pattern compiles to the same engine on every machine.
;;
;; EVERYTHING ELSE IS THE VENDORED ALGORITHM, COPIED. host/chez/regex-dfa-check.ss
;; (make regexdfacheck) pins the upstream definition this was derived from, so
;; bumping the irregex submodule cannot leave this silently stale.

;; ~74ms on the #945 pattern before it gives up, measured on the dev box against
;; a compile that then takes 0ms to build the backtracking matcher. Raising it
;; buys a DFA for patterns that are already at the edge of being worth one.
(define jolt-dfa-work-budget 500000)

(define (nfa->dfa nfa . o)
  (let* ((max-states (and (pair? o) (car o)))
         (start (nfa-state->mst nfa (nfa-start-state nfa) '()))
         (start-closure (nfa-epsilon-closure nfa start))
         ;; Set up a special "initializer" state from which we reach the
         ;; start-closure to ensure that leading tags are set properly.
         (init-set (tag-set-commands-for-closure nfa start start-closure '()))
         (dummy (make-mst nfa))
         (init-state (list dummy #f `((,start-closure #f () . ,init-set))))
         ;; jolt: mst-hash -> the marked states carrying that hash, so the
         ;; seen-set test below is a bucket lookup instead of a full scan.
         (seen (make-eqv-hashtable))
         (work 0))
    (define (remember! st entry)
      (let ((h (mst-hash st)))
        (hashtable-set! seen h (cons entry (hashtable-ref seen h '())))))
    (define (already? st)
      (assoc st (hashtable-ref seen (mst-hash st) '())))
    (remember! dummy init-state)
    ;; Unmarked states are just sets of NFA states with tag-maps, marked states
    ;; are sets of NFA states with transitions to sets of NFA states
    (let lp ((unmarked-states (list start-closure))
             (marked-states (list init-state))
             (dfa-size 0))
      (cond
       ((null? unmarked-states)
        ;; Abuse finalizer slot for storing the number of memory slots we need
        (set-car! (cdr init-state) (+ (nfa-highest-map-index nfa) 1))
        (dfa-renumber (reverse marked-states)))
       ((and max-states (> dfa-size max-states)) ; Too many DFA states
        #f)
       ((> work jolt-dfa-work-budget)            ; jolt: too much work spent
        #f)
       ((already? (car unmarked-states))         ; Seen set of NFA-states?
        (lp (cdr unmarked-states) marked-states dfa-size))
       (else
        (let ((dfa-state (car unmarked-states)))
          (let lp2 ((trans (get-distinct-transitions nfa dfa-state))
                    (unmarked-states (cdr unmarked-states))
                    (dfa-trans '()))
            (if (null? trans)
                (let ((finalizer (mst-state-mappings dfa-state 0)))
                  (let ((entry (list dfa-state finalizer dfa-trans)))
                    (remember! dfa-state entry)
                    (lp unmarked-states
                        (cons entry marked-states)
                        (+ dfa-size 1))))
                (let* ((_ (set! work (+ work (mst-num-states dfa-state))))
                       (closure (nfa-epsilon-closure nfa (cdar trans)))
                       (reordered
                        (find-reorder-commands nfa closure marked-states))
                       (copy-cmds (if reordered (cdr reordered) '()))
                       ;; Laurikari doesn't mention what "k" is, but it seems it
                       ;; must be the mappings of the state's reach
                       (set-cmds (tag-set-commands-for-closure
                                  nfa (cdar trans) closure copy-cmds))
                       (trans-closure (if reordered (car reordered) closure)))
                  (lp2 (cdr trans)
                       (if reordered
                           unmarked-states
                           (cons trans-closure unmarked-states))
                       (cons `(,trans-closure
                               ,(caar trans) ,copy-cmds . ,set-cmds)
                             dfa-trans)))))))))))
