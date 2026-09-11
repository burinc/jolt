;; PINNED COPY — do not edit by hand.
;;
;; irregex's own nfa->dfa, as of the currently checked-out
;; vendor/irregex. host/chez/regex-dfa.ss is jolt's replacement for it,
;; and `make regexdfacheck` fails when the two stop agreeing — see
;; host/chez/regex-dfa-check.ss. Nothing loads this file.
;;
;; Re-pin with `make regexdfacheck-regen` AFTER porting the upstream
;; change into regex-dfa.ss.
(define (nfa->dfa nfa . o)
  (let* ([max-states (and (pair? o) (car o))]
         [start (nfa-state->mst nfa (nfa-start-state nfa) '())]
         [start-closure (nfa-epsilon-closure nfa start)]
         [init-set (tag-set-commands-for-closure
                     nfa
                     start
                     start-closure
                     '())]
         [dummy (make-mst nfa)]
         [init-state (list
                       dummy
                       #f
                       `((,start-closure #f () . ,init-set)))])
    (let lp ([unmarked-states (list start-closure)]
             [marked-states (list init-state)]
             [dfa-size 0])
      (cond
        [(null? unmarked-states)
         (set-car!
           (cdr init-state)
           (+ (nfa-highest-map-index nfa) 1))
         (dfa-renumber (reverse marked-states))]
        [(and max-states (> dfa-size max-states)) #f]
        [(assoc (car unmarked-states) marked-states)
         (lp (cdr unmarked-states) marked-states dfa-size)]
        [else
         (let ([dfa-state (car unmarked-states)])
           (let lp2 ([trans (get-distinct-transitions nfa dfa-state)]
                     [unmarked-states (cdr unmarked-states)]
                     [dfa-trans '()])
             (if (null? trans)
                 (let ([finalizer (mst-state-mappings dfa-state 0)])
                   (lp unmarked-states
                       (cons
                         (list dfa-state finalizer dfa-trans)
                         marked-states)
                       (+ dfa-size 1)))
                 (let* ([closure (nfa-epsilon-closure nfa (cdar trans))]
                        [reordered (find-reorder-commands
                                     nfa
                                     closure
                                     marked-states)]
                        [copy-cmds (if reordered (cdr reordered) '())]
                        [set-cmds (tag-set-commands-for-closure
                                    nfa
                                    (cdar trans)
                                    closure
                                    copy-cmds)]
                        [trans-closure (if reordered
                                           (car reordered)
                                           closure)])
                   (lp2 (cdr trans)
                        (if reordered
                            unmarked-states
                            (cons trans-closure unmarked-states))
                        (cons
                          `(,trans-closure
                             ,(caar trans)
                             ,copy-cmds
                             .
                             ,set-cmds)
                          dfa-trans))))))]))))
