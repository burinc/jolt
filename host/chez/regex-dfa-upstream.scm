;; PINNED COPY — do not edit by hand.
;; Code from irregex, Copyright (c) 2005-2024 Alex Shinn, BSD-style license
;; (licenses/BSD-irregex.txt).
;;
;; irregex's own nfa->dfa, irregex-search/matches and
;; dfa-match/shortest, as of the currently checked-out
;; vendor/irregex. host/chez/regex-dfa.ss holds jolt's replacements,
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
(define (irregex-search/matches irx cnk init src i matches)
  (cond
    [(irregex-dfa irx)
     (cond
       [(flag-set? (irregex-flags irx) ~searcher?)
        (cond
          [(dfa-match/longest (irregex-dfa irx) cnk src i #f #f
             matches 0)
           (irregex-match-start-chunk-set! matches 0 src)
           (irregex-match-start-index-set! matches 0 i)
           matches]
          [else #f])]
       [(dfa-match/shortest (irregex-dfa/search irx) cnk src i
          matches 0)
        (let ([dfa (irregex-dfa irx)]
              [get-start (chunker-get-start cnk)]
              [get-end (chunker-get-end cnk)]
              [get-next (chunker-get-next cnk)])
          (let lp1 ([src src] [i i])
            (let ([end (get-end src)])
              (let lp2 ([i i])
                (cond
                  [(dfa-match/longest dfa cnk src i #f #f matches 0)
                   (irregex-match-start-chunk-set! matches 0 src)
                   (irregex-match-start-index-set! matches 0 i)
                   matches]
                  [(>= i end)
                   (let ([next (get-next src)])
                     (and next (lp1 next (get-start next))))]
                  [else (lp2 (+ i 1))])))))]
       [else #f])]
    [else
     (let ([res (irregex-search/backtrack irx cnk init src i
                  matches)])
       (if res (%irregex-match-fail-set! res #f))
       res)]))
(define (dfa-match/shortest dfa cnk src start matches index)
  (let ([get-str (chunker-get-str cnk)]
        [get-start (chunker-get-start cnk)]
        [get-end (chunker-get-end cnk)]
        [get-next (chunker-get-next cnk)]
        [start-state (dfa-next-state
                       dfa
                       (cadr (dfa-init-state dfa)))])
    (let lp1 ([src src] [start start] [state start-state])
      (and src
           (let ([str (get-str src)] [end (get-end src)])
             (let lp2 ([i start] [state state])
               (cond
                 [(dfa-finalizer dfa state)
                  (cond
                    [index
                     (irregex-match-end-chunk-set! matches index src)
                     (irregex-match-end-index-set! matches index i)])
                  #t]
                 [(< i end)
                  (let* ([ch (string-ref str i)]
                         [next (find
                                 (lambda (x)
                                   (or (eqv? ch (car x))
                                       (and (not (char? (car x)))
                                            (cset-contains? (car x) ch))))
                                 (cdr state))])
                    (and next (lp2 (+ i 1) (dfa-next-state dfa next))))]
                 [else
                  (let ([next (get-next src)])
                    (and next (lp1 next (get-start next) state)))])))))))
