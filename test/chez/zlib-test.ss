;; zlib bindings (host/chez/java/zlib.ss).
;;   chez --script test/chez/zlib-test.ss
;; Pins the z_stream layout, entry-point resolution from one source, the
;; checksum check values in one call and in pieces, round trips in zlib and raw
;; framing (one call and in small pieces), empty streams, the error codes the
;; java.util.zip classes map, dictionaries, parameter changes, reset, close,
;; calls on a closed stream, buffer release, and the guardian drain under the
;; owner's lock.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))

(define (bv-concat bvs)
  (let* ((n (apply + (map bytevector-length bvs)))
         (out (make-bytevector n)))
    (let loop ((bvs bvs) (off 0))
      (if (null? bvs)
          out
          (begin (bytevector-copy! (car bvs) 0 out off (bytevector-length (car bvs)))
                 (loop (cdr bvs) (+ off (bytevector-length (car bvs)))))))))
(define (bv-slice bv start n)
  (let ((c (make-bytevector n))) (bytevector-copy! bv start c 0 n) c))

;; 'throwable for a jolt throw (rt.ss jolt-throw), 'condition for any other
;; raise, such as Chez's invalid memory reference, 'none for no raise.
(define (raised thunk)
  (guard (e ((jolt-throw-condition? e) 'throwable) (#t 'condition))
    (thunk)
    'none))

(define text
  (string->utf8 (apply string-append (make-list 200 "the quick brown fox jumps over the lazy dog. "))))
(define text-len (bytevector-length text))

;; --- layout ---------------------------------------------------------------
(let ((p (sa-foreign-sizeof 'void*)) (l (sa-foreign-sizeof 'unsigned-long)))
  (ok "z_stream layout, LP64"
      (or (not (and (= p 8) (= l 8)))
          (and (= zs-size 112)
               (equal? (vector->list zs-offsets) '(0 8 16 24 32 40 48 56 64 72 80 88 96 104)))))
  (ok "z_stream layout, LLP64 (Windows)"
      (or (not (and (= p 8) (= l 4)))
          (and (= zs-size 88)
               (equal? (vector->list zs-offsets) '(0 8 12 16 24 28 32 40 48 56 64 72 76 80))))))
(let-values (((offsets size) (zs-layout 8 4 4 4)))
  (ok "z_stream layout from LLP64 sizes, on any host"
      (and (= size 88)
           (equal? (vector->list offsets) '(0 8 12 16 24 28 32 40 48 56 64 72 76 80)))))

;; --- resolution and version -----------------------------------------------
(ok "every zlib entry point resolves" (zlib-available?))
(ok "zlibVersion is a 1.x string"
    (let ((v (zlib-version)))
      (and (string? v) (> (string-length v) 2) (string=? "1." (substring v 0 2)))))
(ok "a source that misses one name is not used"
    (not (zlib-tier (lambda (name) (and (not (string=? name "inflate")) name)))))
(ok "every name comes from the first library that defines all of them"
    (let ((es (zlib-common-definer
               (vector-map (lambda (name)
                             (if (member name '("zlibVersion" "crc32"))
                                 (list (cons "fake" 1) (cons "real" 2))
                                 (list (cons "real" 2))))
                           zlib-names))))
      (and es (equal? (vector->list es) (make-list (vector-length zlib-names) 2)))))
(ok "no library that defines all names gives #f"
    (not (zlib-common-definer
          (vector-map (lambda (name)
                        (cond ((string=? name "inflate") (list (cons "b" 2)))
                              ((string=? name "crc32") (list (cons "a" 1)))
                              (else (list (cons "a" 1) (cons "b" 2)))))
                      zlib-names))))

;; --- checksums ------------------------------------------------------------
(ok "crc32 check value" (= (zlib-crc32 0 (string->utf8 "123456789") 0 9) #xcbf43926))
(ok "crc32 over a slice" (= (zlib-crc32 0 (string->utf8 "xx123456789yy") 2 9) #xcbf43926))
(ok "crc32 of nothing keeps the value" (= (zlib-crc32 #x1234 (make-bytevector 3) 1 0) #x1234))
(ok "crc32 of an empty bytevector keeps the value" (= (zlib-crc32 7 (make-bytevector 0) 0 0) 7))
(ok "adler32 check value" (= (zlib-adler32 1 (string->utf8 "Wikipedia") 0 9) #x11e60398))
(let ((n (- text-len 3)))
  (ok "crc32 in 4-byte pieces equals one call"
      (= (zlib-checksum* zf-crc32 0 text 3 n 4) (zlib-crc32 0 (bv-slice text 3 n) 0 n)))
  (ok "adler32 in 7-byte pieces equals one call"
      (= (zlib-checksum* zf-adler32 1 text 3 n 7) (zlib-adler32 1 (bv-slice text 3 n) 0 n))))

;; --- round trips ----------------------------------------------------------
(define (open! kind wbits level strategy)
  (let-values (((zs code msg) (zstream-open kind wbits level strategy)))
    (unless zs (printf "open ~a ~a failed: ~a ~a\n" kind wbits code msg))
    zs))

(define (deflate-all wbits level)
  (let ((zs (open! 'deflate wbits level 0)))
    (let-values (((code consumed produced out) (zstream-step! zs z-finish text (+ 64 text-len))))
      (zstream-close! zs)
      (and (= code z-stream-end) (= consumed text-len) out))))

;; Feed IN STEP bytes at a time with OUT-LEN bytes of room; carry what zlib did
;; not consume. Returns the output, or #f if zlib stalls or fails.
(define (inflate-pieces zs in step out-len)
  (let loop ((pos 0) (acc '()))
    (let* ((n (min step (- (bytevector-length in) pos)))
           (chunk (bv-slice in pos n)))
      (let-values (((code consumed produced out) (zstream-step! zs z-partial-flush chunk out-len)))
        (let ((acc (cons out acc)) (pos (+ pos consumed)))
          (cond
            ((= code z-stream-end) (bv-concat (reverse acc)))
            ((not (memv code (list z-ok z-buf-error))) #f)
            ((and (= produced 0) (= consumed 0) (= pos (bytevector-length in))) #f)
            (else (loop pos acc))))))))

(let ((z (deflate-all 15 -1)))
  (ok "deflate, zlib framing, starts with the zlib header byte" (and z (= (bytevector-u8-ref z 0) #x78)))
  (let ((zs (open! 'inflate 15 0 0)))
    (let-values (((code consumed produced out) (zstream-step! zs z-partial-flush z text-len)))
      (ok "inflate, zlib framing, one call" (and (= code z-stream-end) (equal? out text)))
      (ok "inflate adler matches adler32 of the output"
          (= (zstream-adler zs) (zlib-adler32 1 text 0 text-len))))
    (ok "reset answers Z_OK" (= (zstream-reset! zs) z-ok))
    (ok "inflate, zlib framing, 7 bytes in and 16 out at a time"
        (equal? (inflate-pieces zs z 7 16) text))
    (ok "close answers Z_OK" (= (zstream-close! zs) z-ok))
    (ok "a closed stream is not open" (not (zstream-open? zs)))
    (ok "a second close is harmless" (= (zstream-close! zs) z-ok))
    (ok "a step on a closed stream throws" (eq? (raised (lambda () (zstream-step! zs z-finish text 64))) 'throwable))
    (ok "a failed step on a closed stream allocates nothing"
        (and (eqv? 0 (zstream-in-buf zs)) (eqv? 0 (zstream-out-buf zs))))
    (ok "adler of a closed stream throws" (eq? (raised (lambda () (zstream-adler zs))) 'throwable))
    (ok "message of a closed stream throws" (eq? (raised (lambda () (zstream-message zs))) 'throwable))
    (ok "reset of a closed stream throws" (eq? (raised (lambda () (zstream-reset! zs))) 'throwable))
    (ok "a dictionary on a closed stream throws"
        (eq? (raised (lambda () (zstream-set-dictionary! zs (make-bytevector 4)))) 'throwable))))

(let ((raw (deflate-all -15 9)))
  (let ((zs (open! 'inflate -15 0 0)))
    (ok "inflate, raw framing, in pieces" (equal? (inflate-pieces zs raw 5 11) text))
    (zstream-close! zs))
  (let ((zs (open! 'inflate 15 0 0)))
    (let-values (((code consumed produced out) (zstream-step! zs z-partial-flush raw 64)))
      (ok "zlib framing over raw data is Z_DATA_ERROR" (= code z-data-error))
      (ok "a data error carries zlib's message" (string? (zstream-message zs))))
    (zstream-close! zs)))

;; --- empty streams, no progress, buffers ------------------------------------
(let ((d (open! 'deflate 15 -1 0)))
  (let-values (((code consumed produced z) (zstream-step! d z-finish (make-bytevector 0) 64)))
    (zstream-close! d)
    (ok "deflate of nothing with Z_FINISH ends the stream" (and (= code z-stream-end) (> produced 0)))
    (let ((i (open! 'inflate 15 0 0)))
      (let-values (((code consumed produced out) (zstream-step! i z-partial-flush z 64)))
        (ok "inflate of an empty stream ends with no output" (and (= code z-stream-end) (= produced 0))))
      (zstream-close! i))))
(let ((i (open! 'inflate 15 0 0)))
  (let-values (((code consumed produced out) (zstream-step! i z-partial-flush (make-bytevector 0) 16)))
    (ok "inflate with no input and no progress is Z_BUF_ERROR" (= code z-buf-error)))
  (zstream-step! i z-partial-flush (make-bytevector 0) 16)
  (ok "a buffer up to the keep size stays" (= (zstream-out-cap i) 16))
  (zstream-step! i z-partial-flush (make-bytevector 0) (* 1024 1024))
  (ok "a buffer above the keep size is freed after the call"
      (and (= (zstream-out-cap i) 0) (eqv? 0 (zstream-out-buf i))))
  (zstream-close! i))
(let ((d (open! 'deflate 15 -1 0))
      (big (make-bytevector (* 1024 1024) 97)))
  (let-values (((code consumed produced out) (zstream-step! d z-no-flush big 64)))
    (ok "an input buffer above the keep size is freed after the call"
        (and (= consumed (bytevector-length big)) (= (zstream-in-cap d) 0) (eqv? 0 (zstream-in-buf d)))))
  (zstream-close! d))

;; --- dictionaries ---------------------------------------------------------
(let* ((dict (string->utf8 "the quick brown fox jumps over the lazy dog"))
       (d (open! 'deflate 15 -1 0)))
  (ok "deflate accepts a dictionary" (= (zstream-set-dictionary! d dict) z-ok))
  (let-values (((code consumed produced z) (zstream-step! d z-finish text (+ 64 text-len))))
    (zstream-close! d)
    (let ((i (open! 'inflate 15 0 0)))
      (let-values (((code consumed produced out) (zstream-step! i z-partial-flush z text-len)))
        (ok "inflate stops with Z_NEED_DICT" (= code z-need-dict))
        (ok "the needed dictionary's adler is set" (= (zstream-adler i) (zlib-adler32 1 dict 0 (bytevector-length dict))))
        (ok "inflate accepts the dictionary" (= (zstream-set-dictionary! i dict) z-ok))
        (let-values (((code2 consumed2 produced2 out2)
                      (zstream-step! i z-partial-flush (bv-slice z consumed (- (bytevector-length z) consumed)) text-len)))
          (ok "inflate finishes after the dictionary" (and (= code2 z-stream-end) (equal? (bv-concat (list out out2)) text)))))
      (zstream-close! i))
    (let ((i (open! 'inflate 15 0 0)))
      (zstream-step! i z-partial-flush z text-len)
      (ok "inflate refuses the wrong dictionary with Z_DATA_ERROR"
          (= (zstream-set-dictionary! i (string->utf8 "a different dictionary")) z-data-error))
      (zstream-close! i))))

;; --- parameters -----------------------------------------------------------
(let* ((half (quotient text-len 2))
       (d (open! 'deflate 15 1 0)))
  (let-values (((c1 n1 p1 o1) (zstream-step! d z-no-flush (bv-slice text 0 half) (+ 64 text-len))))
    (let-values (((c2 n2 p2 o2) (zstream-params! d 9 1 (make-bytevector 0) (+ 64 text-len))))
      (ok "deflateParams with room for the pending block answers Z_OK" (= c2 z-ok))
      (let-values (((c3 n3 p3 o3) (zstream-step! d z-finish (bv-slice text half (- text-len half)) (+ 64 text-len))))
        (zstream-close! d)
        (let ((i (open! 'inflate 15 0 0)))
          (let-values (((code consumed produced out) (zstream-step! i z-partial-flush (bv-concat (list o1 o2 o3)) text-len)))
            (ok "output across a parameter change inflates to the input"
                (and (= c3 z-stream-end) (= code z-stream-end) (equal? out text))))
          (zstream-close! i))))))

;; --- refusals -------------------------------------------------------------
(let-values (((zs code msg) (zstream-open 'inflate 99 0 0)))
  (ok "bad window bits: no stream, Z_STREAM_ERROR" (and (not zs) (= code z-stream-error))))
(let-values (((zs code msg) (zstream-open 'deflate 15 42 0)))
  (ok "bad level: no stream, Z_STREAM_ERROR" (and (not zs) (= code z-stream-error))))

;; --- guardian -------------------------------------------------------------
(let ((zs (open! 'inflate 15 0 0)))
  (zstream-guard! (list 'owner) zs)          ; the owner is unreachable at once
  (collect (collect-maximum-generation))
  (ok "drain closes a stream whose owner was reclaimed"
      (and (>= (zstream-drain!) 1) (not (zstream-open? zs)))))
(let ((zs (open! 'deflate 15 -1 0)))
  (zstream-guard! (list 'owner) zs)
  (collect (collect-maximum-generation))
  (let ((other (open! 'inflate 15 0 0)))      ; zstream-open drains first
    (ok "opening a stream drains reclaimed ones" (not (zstream-open? zs)))
    (zstream-close! other)))

;; A drain closes a stream under its owner's lock, so a call that still holds
;; the lock finishes first.
(let ((zs (open! 'inflate 15 0 0))
      (mu (make-mutex))
      (done #f))
  (zstream-guard! (list 'owner) zs mu)
  (collect (collect-maximum-generation))
  (mutex-acquire mu)
  (fork-thread (lambda () (zstream-drain!) (set! done #t)))
  (sleep (make-time 'time-duration 100000000 0))
  (ok "a drain waits while the owner's lock is held" (and (not done) (zstream-open? zs)))
  (mutex-release mu)
  (let wait ((n 0))
    (unless (or done (> n 500))
      (sleep (make-time 'time-duration 10000000 0))
      (wait (+ n 1))))
  (ok "the drain closes the stream once the lock is free" (and done (not (zstream-open? zs)))))

(printf "zlib: ~a/~a passed\n" (- total fails) total)
(exit (if (= fails 0) 0 1))
