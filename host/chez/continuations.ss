;; continuations.ss — the jolt.continuations seam (issue #736).
;;
;; Chez has first-class continuations and the host already leans on them:
;; call/1cc drives the fiber park/resume switch (fibers.ss), call/cc captures
;; the throw site for a backtrace (rt.ss), and the state-image machinery walks
;; them. None of that was reachable from a jolt program. This file exposes ONE
;; thing — the one-shot ESCAPE continuation — as jolt.host/call-cc, which
;; stdlib/jolt/continuations.clj presents as call-cc / letcc.
;;
;; WHY ONLY ESCAPE. The primitive underneath is the adapter's
;; sa-call-with-escape-continuation, contracted to call/1cc's semantics: the
;; captured procedure is valid at most once, and only while its capturing call
;; is still on the stack. That is the shape the host itself uses, it is the
;; shape a target can implement without a full multi-shot stack model, and it
;; is the shape with a defensible story for fibers (below). Re-entrant
;; continuations are deliberately NOT exposed.
;;
;; WHY THE GUARD IS NOT OPTIONAL. Handing the raw primitive to jolt gets two
;; bad outcomes, both measured before this file existed:
;;
;;   * Re-invoking a spent continuation raises a Chez condition that reaches
;;     jolt as class :object: with an EMPTY message — catchable in principle,
;;     useless in practice, and nothing tells the caller which rule broke.
;;
;;   * Invoking a continuation captured on ANOTHER fiber HANGS the process.
;;     Not an error, not a timeout: control transfers into a stack segment
;;     belonging to a fiber this thread is not running, and never comes back.
;;     A continuation captured on a dead fiber and invoked from the main thread
;;     wedges the program with no diagnostic at all.
;;
;; So every escape this file hands out is a WRAPPER that answers three
;; questions before it transfers control, and raises IllegalStateException
;; naming the broken rule when the answer is no:
;;
;;   1. spent?  — has this escape already fired? ("already been invoked")
;;   2. mine?   — am I on the thread AND the fiber that captured it?
;;                ("captured on another")
;;   3. live?   — has its call-cc already returned normally? ("no longer live")
;;
;; Only (2) prevents a hang; (1) and (3) would eventually reach the adapter's
;; own raise, but they are checked here so the message names the rule instead
;; of surfacing a host condition. All three are O(1) reads on the escape path.
;; They are checked in that order because several can hold at once — see
;; jolt-cc-check! for why the ownership answer outranks the lifetime one.
;;
;; WHAT ABOUT PARKING. A park is NOT an ownership boundary. A fiber that parks
;; (yield, a channel op, a parked deref, jolt.socket IO) has its whole stack
;; segment captured and later restored by the scheduler, so an escape captured
;; before the park is still the same fiber's frame after it and the escape
;; works — verified by the gate, and the reason the identity checked here is
;; (thread, fiber) and not "the stack as it stood at capture". A fiber is bound
;; to its carrier for life, so neither half of that pair drifts under a park.
;;
;; The identity is captured as a PAIR of cheap reads: the thread id (the
;; contract's get-thread-id, a number distinct per live thread) and the current
;; fiber record (the vreg fibers.ss owns; 0 off a fiber). Comparing the fiber
;; by eq? is what separates two fibers on the SAME carrier thread, which a
;; thread id alone cannot do.

;; The fiber vreg, read the way fibers.ss reads it. Guarded because this file
;; is loaded from rt.ss after fibers.ss, but the standalone gates load pieces
;; of the runtime in other orders and a missing fiber layer must degrade to
;; "not on a fiber" rather than break the capture.
(define (jolt-cc-current-fiber)
  (guard (e (#t #f))
    (let ((r (virtual-register jolt-vreg-current-fiber)))
      (if (eq? r 0) #f r))))

(define (jolt-cc-thread-id)
  (guard (e (#t 0)) (get-thread-id)))

;; An escape's identity and state. Kept in a record rather than closed-over
;; mutable variables so jolt-escape-fn? can recognise one by its wrapper (see
;; jolt-cc-escapes below) and so the three checks read named fields.
(define-record-type jolt-escape
  (fields (immutable k jolt-escape-k)
          (immutable thread jolt-escape-thread)
          (immutable fiber jolt-escape-fiber)
          (mutable spent jolt-escape-spent? jolt-escape-spent-set!)
          (mutable live jolt-escape-live? jolt-escape-live-set!)))

;; The wrapper handed to jolt is an instance of the ONE case-lambda in
;; jolt-call-cc below, bound under a name no Clojure symbol can spell (`@` is
;; not a symbol constituent, so no fn a program defines is ever named this), and
;; a Chez closure's code object carries the name it was bound under. So
;; jolt-escape-fn? reads the name off the procedure: no registry, no lock, and
;; nothing per capture for the collector to trace.
;;
;; A weak eq table under a process-wide mutex used to hold every escape for this
;; predicate alone. That cost every capture the table write and the lock (86 ns
;; against 8.5 for the bare call/1cc), and it serialized every thread that
;; captures: standard-clojure-style's parser takes a letcc per Choice attempt,
;; and eight carriers formatting eight files spent more than half their samples
;; waiting on that one mutex — the formatter's whole-run wall was 2x what the
;; slowest file takes alone.
(define jolt-escape-code-name "jolt@escape")

(define (jolt-escape-fn? x)
  (and (procedure? x)
       (equal? (sa-procedure-code-name x) jolt-escape-code-name)))

;; The three rules. ORDER IS THE MESSAGE: more than one can be true at once,
;; and the caller is told the most actionable of them.
;;
;;   spent first — an escape that fired is also no longer live and may also be
;;   read from the wrong thread, but "you invoked it twice" is the whole bug.
;;
;;   owner before live — these two go together constantly: an escape saved out
;;   of a fiber and invoked later from the main thread is BOTH dead and
;;   foreign. "No longer live" is true there but reads as a lifetime problem,
;;   and the caller's actual mistake is structural: they moved an escape across
;;   a boundary it cannot cross. Reporting the boundary points at the fix.
;;   Reversed, the cross-fiber case — the one that used to hang — would report
;;   the least useful of its two true answers.
(define (jolt-cc-check! e)
  (cond
    ((jolt-escape-spent? e)
     (throw-jvm 'IllegalStateException
                "jolt.continuations: this escape has already been invoked — an escape continuation is one-shot"))
    ((not (and (eqv? (jolt-escape-thread e) (jolt-cc-thread-id))
               (eq? (jolt-escape-fiber e) (jolt-cc-current-fiber))))
     (throw-jvm 'IllegalStateException
                (string-append
                 "jolt.continuations: this escape was captured on another "
                 (if (jolt-escape-fiber e) "fiber" "thread")
                 " — an escape continuation may only be invoked from the thread and fiber that captured it")))
    ((not (jolt-escape-live? e))
     (throw-jvm 'IllegalStateException
                "jolt.continuations: this escape is no longer live — its call-cc already returned"))
    (else (void))))

;; jolt.host/call-cc. f is a jolt fn of one argument; it receives the escape.
;; The escape takes the value to return, or no argument for nil.
;;
;; live is cleared on the normal return, so a wrapper that outlives its frame
;; answers the lifetime rule here rather than reaching the adapter's raise. An
;; escape never reaches that clear — it transferred control out — which is why
;; the escape path sets spent BEFORE transferring: after the transfer this code
;; does not run again.
(define (jolt-call-cc f)
  (sa-call-with-escape-continuation
   (lambda (k)
     (let ((e (make-jolt-escape k (jolt-cc-thread-id) (jolt-cc-current-fiber) #f #t)))
       ;; The binding NAME is the escape's identity (jolt-escape-fn? above):
       ;; Chez names a closure after the variable a lambda is bound to, so
       ;; every wrapper's code object carries jolt-escape-code-name.
       (let ((jolt@escape
              (case-lambda
                (() (jolt-cc-check! e)
                    (jolt-escape-spent-set! e #t)
                    ((jolt-escape-k e) jolt-nil))
                ((v) (jolt-cc-check! e)
                     (jolt-escape-spent-set! e #t)
                     ((jolt-escape-k e) v)))))
         ;; The normal return. An escape never reaches here (k transferred
         ;; control out of this lambda), so clearing live here is exactly the
         ;; "call-cc returned without you" case rule 2 reports.
         (let ((v (jolt-invoke1 f jolt@escape)))
           (jolt-escape-live-set! e #f)
           v))))))

(def-var! "jolt.host" "call-cc" jolt-call-cc)
(def-var! "jolt.host" "escape-fn?" jolt-escape-fn?)
