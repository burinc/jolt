;; regex-dfa.ss — jolt's nfa->dfa, replacing the vendored irregex one.
;;
;; Adapted from irregex's nfa->dfa, Copyright (c) 2005-2024 Alex Shinn,
;; BSD-style license (licenses/BSD-irregex.txt).
;;
;; irregex compiles a group-free pattern to a DFA (regex.ss says why capturing
;; patterns keep the backtracker instead). The conversion is Laurikari's tagged
;; NFA->DFA: each DFA state is a MULTI-STATE, a vector with one slot per NFA
;; state. The vendored version makes a large pattern pathological, and one real
;; pattern did — a 50-alternative union with two unbounded `.*` branches, 873
;; characters, from a retry classifier (#945). It took ~5s to match the first
;; time on x86_64 and did not terminate at all on aarch64:
;;
;;   1. Nothing bounded the WORK. The state count is capped (10x the NFA's), but
;;      a union of unbounded branches explodes multiplicatively: that pattern's
;;      DFA has 4113 states over 2208 NFA states and COMPLETES, after ~5.6s of
;;      closure and reach computations, and a pattern one step larger reaches
;;      the cap — only to give up and fall back to the backtracker — with the
;;      whole cost already paid. Ten `a.*b` branches spent 78ms to fail that
;;      way; twenty spent 750ms. This is the fix.
;;
;;   2. The "have I already built this state?" test was (assoc st marked-states)
;;      — a linear scan of every state built so far, each comparison an equal?
;;      over a vector with one slot per NFA state. A multi-state already carries
;;      a hash of its contents (slot 2, maintained by every mutator), and equal?
;;      multi-states necessarily have equal hashes, so bucketing by it is exact:
;;      the scan within a bucket is the same assoc as before. Measured on the
;;      #945 pattern with the budget lifted it is worth about a tenth (5.6s to
;;      5.1s) — the closures dominate, not the seen-set — so this is a tidy-up
;;      that rides along, not the reason the pattern is fast.
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
;; bumping the irregex submodule cannot leave this silently stale. The same goes
;; for the search procedures at the end of the file (#1327), whose anchored match
;; is now the backtracker regex.ss attaches rather than dfa-match/longest
;; (jolt-6gkc, see jolt-dfa-anchored-match), and whose searcher path records
;; where its match starts.

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

;; ---------------------------------------------------------------------------
;; Searching with the DFA (#1327).
;;
;; irregex searches a DFA-compiled pattern in two passes. The SEARCH DFA (the
;; pattern behind an implicit .*) runs once to prove a match exists and find its
;; earliest possible end; then the anchored DFA re-runs with dfa-match/longest at
;; every start position from the search origin until one matches. That retry is
;; where a late match went: dfa-match/longest allocates its tag memory and closes
;; over the chunker on every call, ~60ns a position before it looks at a single
;; character, so #"\e\[[0-9;]*[a-zA-Z]" found an escape 400 characters in at
;; 22us where the backtracker took 1.7us.
;;
;; The retry now asks a cheaper question first: can a match START here at all?
;; jolt-dfa-viable? steps the anchored DFA without tags or allocation and answers
;; as soon as it reaches an accepting state or dies. Only a position that passes
;; pays for the anchored match, and a position that passes always matches, so the
;; anchored match runs at most twice per search: once at the origin, which is
;; tried directly so an early match costs what it did, and once where the match
;; is. Most rejected positions never get as far as the probe: their first
;; character has no transition out of the start state, which the retry loop
;; checks inline.
;;
;; dfa-match/shortest (the search pass) is the vendored procedure with its
;; per-character `find` over a fresh closure replaced by jolt-dfa-cell, the same
;; lookup as a loop. Both copies are pinned by `make regexdfacheck`.

;; The transition out of `state` on `ch`, or #f — the vendored lookup, which
;; tests a char key with eqv? and a cset key with cset-contains?.
(define (jolt-dfa-cell state ch)
  (let lp ((cells (cdr state)))
    (and (pair? cells)
         (let ((key (caar cells)))
           (if (if (char? key) (eqv? key ch) (cset-contains? key ch))
               (car cells)
               (lp (cdr cells)))))))

;; Does the anchored DFA, run from `state` at position i of src, reach an
;; accepting state? The same walk as dfa-match/shortest, recording nothing.
(define (jolt-dfa-viable? dfa state cnk src i)
  (let ((get-str (chunker-get-str cnk))
        (get-start (chunker-get-start cnk))
        (get-end (chunker-get-end cnk))
        (get-next (chunker-get-next cnk)))
    (let lp1 ((src src) (i i) (state state))
      (let ((str (get-str src)) (end (get-end src)))
        (let lp2 ((i i) (state state))
          (cond
           ((dfa-finalizer dfa state) #t)
           ((< i end)
            (let ((cell (jolt-dfa-cell state (string-ref str i))))
              (and cell (lp2 (+ i 1) (dfa-next-state dfa cell)))))
           (else
            (let ((next (get-next src)))
              (and next (lp1 next (get-start next) state))))))))))

;; jolt-6gkc: the match that STARTS at i, once the DFA has said one does.
;; irregex's DFA is POSIX leftmost-longest, and java.util.regex is leftmost-first:
;; the two agree on where the first match starts — that is just the earliest
;; position from which the pattern matches at all — but not on where it ends.
;; (re-find #"[ab]|c*.+" "bb") is "b" on the JVM, the first alternative that
;; works, and dfa-match/longest made it "bb". So the DFA keeps the part it is
;; good at, rejecting positions in linear time (the #".*z" scan regex.ss keeps
;; it for), and the backtracking matcher regex.ss attaches as the irregex's nfa
;; decides the end, exactly as the JVM would, from the one start that matters.
;; An irregex without one (built outside regex.ss) keeps the longest match.
(define (jolt-dfa-anchored-match irx cnk init src i matches)
  (let ((matcher (irregex-nfa irx)))
    (if matcher
        (let ((m (matcher cnk init src ((chunker-get-str cnk) src) i
                          ((chunker-get-end cnk) src) matches (lambda () #f))))
          (and m (begin (%irregex-match-fail-set! m #f) #t)))
        (dfa-match/longest (irregex-dfa irx) cnk src i #f #f matches 0))))

(define (irregex-search/matches irx cnk init src i matches)
  (cond
   ((irregex-dfa irx)
    (cond
     ((flag-set? (irregex-flags irx) ~searcher?)
      (cond
       ((jolt-dfa-anchored-match irx cnk init src i matches)
        (irregex-match-start-chunk-set! matches 0 src)
        (irregex-match-start-index-set! matches 0 i)
        matches)
       (else
        #f)))
     ((dfa-match/shortest
       (irregex-dfa/search irx) cnk src i matches 0)
      (let* ((dfa (irregex-dfa irx))
             ;; jolt: the state after the tag-setting initializer, as
             ;; dfa-match/shortest starts from, and whether it already accepts
             ;; (an empty match is possible at every position).
             (start-state (dfa-next-state dfa (cadr (dfa-init-state dfa))))
             (start-final? (dfa-finalizer dfa start-state))
             (origin-src src)
             (origin i)
             (get-str (chunker-get-str cnk))
             (get-start (chunker-get-start cnk))
             (get-end (chunker-get-end cnk))
             (get-next (chunker-get-next cnk)))
        (let lp1 ((src src) (i i))
          (let ((str (get-str src))
                (end (get-end src)))
            (let lp2 ((i i))
              (cond
               ;; jolt: only a position a match can start at runs the anchored
               ;; match; the first step is taken here, without a call. The
               ;; search origin skips the deeper probe: a match there is the
               ;; common case, and probing it first would walk it twice.
               ((and (or start-final?
                         (if (< i end)
                             (let ((cell (jolt-dfa-cell start-state (string-ref str i))))
                               (and cell
                                    (or (and (eq? src origin-src) (= i origin))
                                        (jolt-dfa-viable? dfa (dfa-next-state dfa cell)
                                                          cnk src (+ i 1)))))
                             (jolt-dfa-viable? dfa start-state cnk src i)))
                     (jolt-dfa-anchored-match irx cnk init src i matches))
                (irregex-match-start-chunk-set! matches 0 src)
                (irregex-match-start-index-set! matches 0 i)
                matches)
               ((>= i end)
                (let ((next (get-next src)))
                  (and next (lp1 next (get-start next)))))
               (else
                (lp2 (+ i 1)))))))))
     (else
      #f)))
   (else
    (let ((res (irregex-search/backtrack irx cnk init src i matches)))
      (if res (%irregex-match-fail-set! res #f))
      ;; jolt: a searcher (a pattern led by `.*`) is tried at i alone, and the
      ;; backtracker records the match as starting at (cdr init), the search
      ;; ORIGIN. A matcher's second find over #"(?s).*" therefore reported the
      ;; first match's start again; the match starts at i.
      (when (and res (flag-set? (irregex-flags irx) ~searcher?))
        (irregex-match-start-chunk-set! res 0 src)
        (irregex-match-start-index-set! res 0 i))
      res))))

(define (dfa-match/shortest dfa cnk src start matches index)
  (let ((get-str (chunker-get-str cnk))
        (get-start (chunker-get-start cnk))
        (get-end (chunker-get-end cnk))
        (get-next (chunker-get-next cnk))
        ;; Skip the "set-up" state, we don't need to set tags.
        (start-state (dfa-next-state dfa (cadr (dfa-init-state dfa)))))
    (let lp1 ((src src) (start start) (state start-state))
      (and
       src
       (let ((str (get-str src))
             (end (get-end src)))
         (let lp2 ((i start) (state state))
           (cond
            ((dfa-finalizer dfa state)
             (cond
              (index
               (irregex-match-end-chunk-set! matches index src)
               (irregex-match-end-index-set! matches index i)))
             #t)
            ((< i end)
             ;; jolt: jolt-dfa-cell, not `find` over a closure per character.
             (let ((next (jolt-dfa-cell state (string-ref str i))))
               (and next (lp2 (+ i 1) (dfa-next-state dfa next)))))
            (else
             (let ((next (get-next src)))
               (and next (lp1 next (get-start next) state)))))))))))
