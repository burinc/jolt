;; Regression for Jolt's narrow-fixnum Chez hash paths.
;; Run from the Jolt root with a generated tpb32l interpreter:
;;   /path/to/tpb32l/bin/tpb32l/scheme --script test/chez/tpb32l-hash-test.ss
(import (chezscheme))
(load "host/chez/scheme-adapter-runtime.ss")
(load "host/chez/locks.ss")
(load "host/chez/values.ss")
(load "host/chez/hasheq.ss")

(define (check name got want)
  (unless (= got want)
    (error 'tpb32l-hash-test name got want)))

(unless (eq? (machine-type) 'tpb32l)
  (error 'tpb32l-hash-test "this regression requires the 32-bit threaded PB target" (machine-type)))
(check "hash int" (murmur3-hash-long-flat 1) 1392991556)
(check "hash signed" (murmur3-hash-long-flat 100) -970256272)
(check "32-bit fold" (i32 #xFFFFFFFF) -1)
(check "32-bit multiply" (mul32 #x7FFFFFFF 31) 2147483617)
(check "hash string" (murmur3-hash-unencoded-chars "select") 203636772)
(display "TPB32L-HASH-OK\n")
