;; Large long, int and double arrays stay where they are across full collections
;; (#1227), the fxvector/flvector half of what large-bytes-gc-test.ss pins for
;; byte arrays (#1225).
;;   chez --script test/chez/large-fx-gc-test.ss
;; Chez pins a huge allocation itself (over 128 segments, 2MB) only when it takes
;; FRESH segments, and copies a multi-segment object in a chunk under a quarter
;; used at every full collection. A byte array escapes that by being an immobile
;; bytevector; Chez has no immobile fxvector or flvector, so jolt pins a backing
;; of 64KB and up to its array instead (natives-array.ss na-pin-large!,
;; scheme-adapter-runtime.ss sa-pin-for-owner!) and releases it when the array is
;; dropped.
;;
;; As in the byte gate, the ADDRESS is what pins it: a mobile object is always
;; copied out of generation 0 by its first full collection, so one that has not
;; moved after several is one the collector marks in place. The control rows say
;; the probe does see a copy. (Run alone, without this boot's heap, a plain 64KB
;; fxvector is copied at every full collection: the hazard itself, at small scale.)

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred) (set! total (+ total 1)) (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (evv s) (jolt-compile-eval (string-append "(do " s ")") "user"))
(define (ev s) (jolt-final-str (evv s)))
(define (is name s expect) (ok (string-append name " => " expect) (string=? (ev s) expect)))

(define (full!) (collect (collect-maximum-generation)))
(define (addr v) (#%$fxaddress v))
;; how many of N full collections moved V?
(define (moves v n)
  (let loop ((i 0) (a (addr v)) (c 0))
    (if (= i n)
        c
        (begin (full!) (loop (+ i 1) (addr v) (if (= a (addr v)) c (+ c 1)))))))
(define (stays? v n) (= 0 (moves v n)))
(define (backing x) (jolt-array-vec x))
(define (fx-or-fl? v) (or (fxvector? v) (flvector? v)))
(define (stays-put name src)
  (let ((a (evv src)))
    (ok (string-append name " is not copied by a full collection")
        (and (fx-or-fl? (backing a)) (stays? (backing a) 3)))))
(define (mobile name src)
  (let ((a (evv src)))
    (ok (string-append name " is still an ordinary, mobile backing")
        (and (fx-or-fl? (backing a)) (not (stays? (backing a) 1))))))
;; the pin, read straight off the adapter: #f when ARR holds none
(define (pinned? arr)
  (let ((b (hashtable-ref sa-pin-boxes arr #f))) (and b (unbox b) #t)))

;; --- the probe sees a copy ---------------------------------------------------
(ok "control: a plain 64KB fxvector is copied out of generation 0"
    (not (stays? (make-fxvector 8192 7) 1)))
(ok "control: a plain 64KB flvector is copied out of generation 0"
    (not (stays? (make-flvector 8192 7.0) 1)))
(mobile "a small long array" "(long-array 1024)")
(mobile "one element under the threshold" "(long-array 8191)")
(mobile "a small double array" "(double-array 8191)")

;; --- every door to a large long/int/double array -----------------------------
(stays-put "(long-array n)"          "(long-array (* 1024 1024))")
(stays-put "(long-array n init)"     "(long-array (* 1024 1024) 7)")
(stays-put "(long-array coll)"       "(long-array (range 70000))")
(stays-put "the 64KB threshold"      "(long-array 8192)")
(stays-put "(int-array n)"           "(int-array 70000)")
(stays-put "(short-array n)"         "(short-array 70000)")
(stays-put "(double-array n)"        "(double-array 70000)")
(stays-put "(double-array n init)"   "(double-array 70000 1.5)")
(stays-put "(double-array coll)"     "(double-array (repeat 70000 1.5))")
(stays-put "(float-array n)"         "(float-array 70000)")
(stays-put "8MB, past Chez's own pin" "(long-array (* 1024 1024))")
(stays-put "make-array long"         "(make-array Long/TYPE 70000)")
(stays-put "make-array double"       "(make-array Double/TYPE 70000)")
(stays-put "aclone"                  "(aclone (long-array 70000))")
(stays-put "aclone double"           "(aclone (double-array 70000))")
(stays-put "Arrays/copyOf"           "(java.util.Arrays/copyOf (long-array 10) 70000)")

;; --- the bench's shape: a big freed array first, then the live one ------------
(evv "(def junk (doall (map (fn [i] (str i)) (range 1000))))")
(evv "(let [a (long-array (* 8 1024 1024) 7)] (System/gc) (System/gc) (aget a 0))")
(ok "after a freed 64MB long array: an 8MB long array never copied across 50 full collections"
    (stays? (backing (evv "(long-array (* 1024 1024) 7)")) 50))
(evv "(let [a (long-array (* 8 1024 1024) 7)] (System/gc) (System/gc) (aget a 0))")
(ok "after a freed 64MB long array: a 1MB double array never copied across 50 full collections"
    (stays? (backing (evv "(double-array (* 128 1024) 7.0)")) 50))

;; --- the values are the ones asked for ---------------------------------------
(is "zero fill"     "(let [a (long-array 70000)] [(aget a 0) (aget a 69999) (reduce + a)])" "[0 0 0]")
(is "long fill"     "(let [a (long-array 70000 -3)] (System/gc) [(aget a 0) (aget a 69999) (alength a)])" "[-3 -3 70000]")
(is "double fill"   "(let [a (double-array 70000 2.5)] (System/gc) [(aget a 0) (aget a 69999)])" "[2.5 2.5]")
(is "written, collected, read back"
    "(let [a (long-array 70000)] (aset a 69999 5) (System/gc) [(aget a 69999) (vec (take 2 (aclone a)))])"
    "[5 [0 0]]")
(is "a clone is a copy"
    "(let [a (double-array 70000 3.0) b (aclone a)] (aset b 0 9.0) [(aget a 0) (aget b 0)])"
    "[3.0 9.0]")

;; --- pins come off ------------------------------------------------------------
(let ((a (evv "(long-array 70000)")))
  (ok "a large array holds a pin" (pinned? a))
  (let ((old (backing a)))
    ;; past the fixnum range the backing widens to a boxed vector (ja-promote!)
    (ja-set! a 0 (expt 2 62))
    (ok "widened: the backing is a vector and the old fxvector's pin is released"
        (and (vector? (backing a)) (not (pinned? a))))
    (ok "widened: the value survived" (= (ja-ref a 0) (expt 2 62)))
    (ok "widened: the old fxvector is mobile again" (not (stays? old 1)))))
(ok "a small array holds no pin" (not (pinned? (evv "(long-array 16)"))))
;; dropped ones are reclaimed: a pin lasts the array's life, not the process's.
;; Each new pin drains the arrays dropped before it...
(ok "dropped large long arrays are reclaimed (drained by the next pin)"
    (begin
      (full!)
      (let ((before (bytes-allocated)))
        (do ((i 0 (+ i 1))) ((= i 20)) (evv "(long-array (* 1024 1024))"))
        (evv "(long-array 8192)")
        (full!)
        (< (- (bytes-allocated) before) (* 16 1024 1024)))))
;; ...and so does a collection the program asks for (System/gc), which runs no
;; collect-request-handler: without it a dropped 64MB long array stayed locked,
;; and live, through every System/gc until the next pin (the gc-arrays bench's
;; bytes phase, 2.3x).
(ok "a dropped large array is unpinned by System/gc with no later pin"
    ;; keep the pin's box, not the array: the box is #f once the lock is undone
    (let ((b (hashtable-ref sa-pin-boxes (evv "(long-array (* 4 1024 1024))") #f)))
      (evv "(System/gc)")
      (and b (not (unbox b)))))
;; ...and so does every collection jolt schedules, so one big array dropped with
;; no other pin after it does not stay locked for the rest of the run. The gate
;; boot leaves Chez's own collect-request-handler in place; a binary and the CLI
;; install jolt's (jolt-install-gc-policy!), which is the one that drains.
(jolt-install-gc-policy!)
(ok "a dropped large array is reclaimed with no later pin (drained after a collection)"
    (begin
      (full!)
      (let ((before (bytes-allocated)))
        (evv "(long-array (* 4 1024 1024))")
        (full!)
        ((collect-request-handler))
        (full!)
        (< (- (bytes-allocated) before) (* 4 1024 1024)))))

(printf "large-fx-gc-test: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
