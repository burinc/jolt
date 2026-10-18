;; test/chez/io-errno-message-test.ss — a read or write the OS refuses is an
;; IOException whose message is the OS's own text, as on the JVM.
;; Run: chez --script test/chez/io-errno-message-test.ss
;;
;; The JDK throws the errno's strerror text ("Invalid argument", "Is a
;; directory", JNU_ThrowIOExceptionWithLastError). Chez raises "failed on ~s:
;; ~(~a~)" with the port and that same text as irritants, and the rendered
;; condition ("get-u8: failed on #<binary input port …>: invalid argument") used
;; to be the message. A FileInputStream read past an offset the file system took
;; on lseek (Long/MAX_VALUE on tmpfs or xfs) fails with EINVAL, so the skip
;; corpus row read the Chez text on those file systems.

(import (chezscheme))
(load "host/chez/gate-boot.ss")

(define total 0)
(define fails 0)
(define (ok name got want)
  (set! total (+ total 1))
  (unless (equal? got want)
    (set! fails (+ fails 1))
    (printf "  FAIL: ~a\n    got:  ~s\n    want: ~s\n" name got want)))

(define (caught thunk)
  (guard (e (#t (jolt-unwrap-throw e))) (thunk) #f))
(define (class+message t)
  (and t (list (jolt-ex-info-record-class-name t) (jolt-ex-info-record-message t))))

(printf "== io-errno-message: an OS read failure is IOException with the errno text ==\n")

;; A real one: a directory opened read-only reads as EISDIR on Linux and macOS.
(sa-load-shared-object #f)
(define c-open (foreign-procedure "open" (string int) int))
(define fd (c-open "." 0))
(define p (open-fd-input-port fd))
(ok "get-u8 on a directory fd"
    (class+message (caught (lambda () (get-u8 p))))
    '("java.io.IOException" "Is a directory"))
(ok "get-bytevector-n on a directory fd"
    (class+message (caught (lambda () (get-bytevector-n p 4))))
    '("java.io.IOException" "Is a directory"))

;; The shape the skip row hit, as Chez builds it: EINVAL from a read.
(ok "a read EINVAL"
    (class+message
      (caught (lambda ()
                (raise (condition (make-i/o-read-error) (make-who-condition 'get-u8)
                                  (make-message-condition "failed on ~s: ~(~a~)")
                                  (make-irritants-condition (list p "Invalid argument")))))))
    '("java.io.IOException" "Invalid argument"))

;; Anything else keeps its rendered message.
(ok "a non-port i/o error keeps the rendered text"
    (class+message
      (caught (lambda ()
                (raise (condition (make-i/o-error) (make-who-condition 'thing)
                                  (make-message-condition "went wrong ~s")
                                  (make-irritants-condition (list 1)))))))
    '("java.io.IOException" "thing: went wrong 1"))

(printf "io-errno-message: ~a checks, ~a failures\n" total fails)
(exit (if (= fails 0) 0 1))
