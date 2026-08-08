;; host/chez/java/sm.ss — the cheap park. Loaded by rt.ss AFTER fibers-async.ss.
;;
;; A fiber parks by capturing a continuation, and Chez represents that as a stack
;; segment which stays live for as long as the process is parked (~3.5 KB, whatever
;; the depth). A park that clojure.core.async.sm could rewrite does not need one:
;; the rest of the body is already a closure, so the op stores the closure and
;; switches to the scheduler with no capture at all.
;;
;; The two mechanisms coexist inside one fiber and are chosen per park site, by
;; whether a continuation was threaded to the op. So a body that parks lexically
;; AND through a helper gets the cheap park for the first and today's capture for
;; the second, with no static analysis deciding anything.
;;
;; The channel protocol is unchanged: the same R3 waiter handler, the same
;; commit-under-wmu, the same "release the channel mutex before parking". Only the
;; park itself differs, and it is the last thing either path does.
;;
;; Not covered: alts! (threading a continuation through the waiter registration in
;; __do-alts is its own round) and a park inside a try (the rewrite would have to
;; carry the exception frame explicitly). Both fall back to the capture.

;; The cheap-park counter, the mirror of fibers-async.ss's jolt-fiber-chan-parks
;; (continuation captures in channel ops). The gates read both: a body whose parks
;; were all rewritten moves this one and leaves that one alone.
(define jolt-sm-parks 0)

;; --- the park ---------------------------------------------------------------
;; Store the rest of the computation and hand the carrier back. The differences
;; from jolt-fiber-to-scheduler! are the whole point: no call/1cc, and k is left
;; CLEAR so the scheduler re-enters through the thunk (jolt-sm-drive below), which
;; is what re-establishes the body's guard on every resume. Everything else —
;; clearing the current-fiber vreg, saving the slice, flagging the escape as a park
;; so try/finally after-thunks skip — is identical, and has to be.
(define (jolt-sm-park! f resume)
  (set! jolt-sm-parks (+ jolt-sm-parks 1))
  (jolt-fiber-sm-set! f resume)
  (jolt-fiber-k-set! f #f)
  (set-virtual-register! jolt-vreg-current-fiber 0)
  (jolt-fiber-slice-save! f)
  (jolt-park-unwinding-set! #t)
  ((jolt-carrier-sched-k (jolt-fiber-carrier f))))

;; Commit to a cheap park on an already-registered handler whose channel mutex is
;; RELEASED. The commit is atomic with alt-deliver!'s mailbox write under h's wmu,
;; exactly as jolt-fiber-waiter-wait! does it: a deliver that beat the commit is
;; seen here and the resume runs inline instead of parking.
(define (jolt-sm-commit! h resume)
  (let* ((f (jolt-current-fiber))
         (park? (with-mutex (alt-handler-wmu h)
                  (if (vector-ref (alt-handler-mailbox h) 0)
                      #f
                      (begin (jolt-fiber-state-set! f 'parked) #t)))))
    (if park?
        (jolt-sm-park! f resume)
        (resume))))

;; --- the driver -------------------------------------------------------------
;; The fiber thunk of a CPS'd body, run on the first entry and on every resume
;; (jolt-fiber-resume* enters through the thunk whenever k is clear, and a cheap
;; park clears it). The guard therefore wraps the body again on each resume, which
;; an ordinary closure stored in k would not do — a captured continuation carries
;; resume*'s guard frame inside itself, a closure has no frames at all.
;;
;; The go channel closes on a throw, the way async-go-spawn-thread and
;; jolt-fiber-go-spawn both do it.
(define (jolt-sm-drive w body-fn)
  (let ((f (jolt-current-fiber)))
    (guard (e (#t (async-report-uncaught! "go/fiber body (channel closed)" e)
                  (jolt-async-close! w)
                  (jolt-fiber-dead! f e)))
      (let ((step (jolt-fiber-sm f)))
        (jolt-fiber-sm-set! f #f)
        (if step
            (step)
            (jolt-invoke body-fn (lambda (v) (jolt-sm-finish! w f v))))))))

;; The terminal continuation on a fiber. The value cannot simply be returned: after
;; a cheap park nothing is left on the stack to return through, so the delivery and
;; the completion both happen here. A nil result just closes the channel (nil is
;; not a channel value).
(define (jolt-sm-finish! w f v)
  (when (not (jolt-nil? v)) (jolt-async-give w v))
  (jolt-async-close! w)
  (jolt-fiber-done! f v))

;; The terminal continuation on a thread: every CPS call is a tail call, so
;; returning the value hands it to the thunk's caller and today's wrapper does the
;; delivery unchanged.
(define (jolt-sm-thread-finish v) v)

;; --- the spawn --------------------------------------------------------------
;; (__sm-spawn body-fn) -> channel, where body-fn is (fn [k] ...). Honors
;; *go-backend* at spawn time, like async-go-spawn.
(define (jolt-sm-spawn body-fn)
  (if (eq? (go-backend-current) jolt-go-backend-fiber)
      (jolt-sm-fiber-spawn body-fn)
      (async-go-spawn-thread (lambda () (jolt-invoke body-fn jolt-sm-thread-finish)))))

(define (jolt-sm-fiber-spawn body-fn)
  (let ((w (ac-make 1 'fixed #f)))
    (sa-fiber-spawn
     (lambda ()
       (*txn* #f)                        ; a go body never inherits the spawner's txn
       (jolt-sm-drive w body-fn)))
    (jolt-fiber-ensure-carrier!)
    w))

;; --- the ops ----------------------------------------------------------------
;; Each op is (op args... k). Off a fiber it is today's blocking op with k applied
;; to the result in tail position — so a CPS'd body costs a thread backend nothing
;; and grows no stack per park. On a fiber a ready channel completes inline and an
;; empty/full one parks cheaply.

(define (jolt-sm-take ch k)
  (if (jolt-current-fiber)
      (jolt-sm-fiber-take ch k)
      (jolt-invoke k (jolt-async-take ch))))

(define (jolt-sm-fiber-take ch k)
  (mutex-acquire (async-chan-mu ch))
  (let ((r (ac-poll!/locked ch)))
    (if (eq? r ac-poll-empty)
        (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
          (async-chan-alt-takers-set! ch (append (async-chan-alt-takers ch) (list h)))
          (ac-notify! ch)
          (if (vector-ref (alt-handler-mailbox h) 0)
              (let ((v (vector-ref (alt-handler-mailbox h) 1)))
                (mutex-release (async-chan-mu ch))
                (jolt-invoke k v))
              (begin
                (mutex-release (async-chan-mu ch))
                (jolt-sm-commit!
                 h (lambda () (jolt-invoke k (vector-ref (alt-handler-mailbox h) 1)))))))
        (begin
          (mutex-release (async-chan-mu ch))
          (jolt-invoke k r)))))

(define (jolt-sm-put ch v k)
  (if (jolt-current-fiber)
      (jolt-sm-fiber-put ch v k)
      (jolt-invoke k (jolt-async-give ch v))))

(define (jolt-sm-fiber-put ch v k)
  ;; the nil check BEFORE the mutex: it throws, and this path releases by hand
  (async-check-put! v)
  (mutex-acquire (async-chan-mu ch))
  (let ((r (jolt-chan-locked-give! ch v)))
    (cond
      ((eq? r 'ok) (mutex-release (async-chan-mu ch)) (jolt-invoke k #t))
      ((eq? r 'closed) (mutex-release (async-chan-mu ch)) (jolt-invoke k #f))
      (else
       (let ((h (jolt-fiber-waiter (jolt-current-fiber))))
         (async-chan-alt-putters-set! ch
           (append (async-chan-alt-putters ch) (list (cons h v))))
         (ac-notify! ch)
         (if (vector-ref (alt-handler-mailbox h) 0)
             (let ((ok (vector-ref (alt-handler-mailbox h) 1)))
               (mutex-release (async-chan-mu ch))
               (jolt-invoke k ok))
             (begin
               (mutex-release (async-chan-mu ch))
               (jolt-sm-commit!
                h (lambda () (jolt-invoke k (vector-ref (alt-handler-mailbox h) 1)))))))))))

(cca-def! "__sm-spawn" jolt-sm-spawn)
(cca-def! "__sm-take" jolt-sm-take)
(cca-def! "__sm-put" jolt-sm-put)
