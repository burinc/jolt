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

;; The wrapper procedures handed to jolt, keyed by the procedure itself, so
;; jolt-escape-fn? can answer for a value that is otherwise an ordinary jolt
;; callable. An eq?-keyed weak table: an escape that is collected takes its
;; entry with it, and the table never keeps a spent capture (or its stack
;; segment) alive. Per-process and not per-thread — escapes are compared by
;; identity, and a wrapper may legitimately be ASKED about from another thread
;; even though invoking it there is refused.
;;
;; UNDER THE MUTEX, BOTH DIRECTIONS. This is the same shape as hasheq.ss's
;; proc-hasheq-tbl and takes the same lock for the same reason: a global weak
;; table written by two threads at once faults in the collector, and a read
;; racing a write is no safer than two writes. Captures happen on any thread,
;; so neither side can be left unguarded.
;;
;; WHAT IT COSTS, measured (2M captures, this machine): the bare capture —
;; call/1cc plus the case-lambda — is 8.5 ns. The weak-table write takes it to
;; 61 ns, and the mutex to 86 ns. So escape-fn? is not free: it makes a capture
;; about 10x its floor. It is still far below the exception-based early exit it
;; replaces, and it is paid per CAPTURE, not per iteration of whatever loop the
;; capture wraps — but "costs nothing" would be a lie, and the number is
;; recorded here so the trade can be revisited rather than rediscovered.
(define jolt-cc-escapes (make-weak-eq-hashtable))
(define jolt-cc-escapes-mu (make-mutex))

(define (jolt-cc-register! escape e)
  (jolt-with-mutex jolt-cc-escapes-mu (hashtable-set! jolt-cc-escapes escape e)))

(define (jolt-escape-fn? x)
  (and (procedure? x)
       (jolt-with-mutex jolt-cc-escapes-mu
         (and (hashtable-ref jolt-cc-escapes x #f) #t))))

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
       (let ((escape
              (case-lambda
                (() (jolt-cc-check! e)
                    (jolt-escape-spent-set! e #t)
                    ((jolt-escape-k e) jolt-nil))
                ((v) (jolt-cc-check! e)
                     (jolt-escape-spent-set! e #t)
                     ((jolt-escape-k e) v)))))
         (jolt-cc-register! escape e)
         ;; The normal return. An escape never reaches here (k transferred
         ;; control out of this lambda), so clearing live here is exactly the
         ;; "call-cc returned without you" case rule 2 reports.
         (let ((v (jolt-invoke1 f escape)))
           (jolt-escape-live-set! e #f)
           v))))))

(def-var! "jolt.host" "call-cc" jolt-call-cc)
(def-var! "jolt.host" "escape-fn?" jolt-escape-fn?)
