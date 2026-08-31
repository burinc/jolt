;; The derived host properties (jolt-lang/jolt#796): what sa-os-family, sa-arch
;; and sa-endian answer for each Chez machine tag. Run:
;;   chez --script test/chez/host-derived-props-test.ss
;;
;; These three are the ONLY things host logic may ask about the platform — the
;; tag itself is naming-only — so a wrong row here is a wrong SIGCHLD, EAGAIN,
;; O_NONBLOCK, LC_TIME, struct-stat offset, chmod fallback and link library, on
;; every caller at once. #796 was exactly that: portable-bytecode tags carry no
;; OS, so the else-branch called every bytecode build Linux, including one
;; running on macOS, and a Darwin pb build could not open a socket because
;; jolt.nrepl handed Darwin's socket() the Linux SOCK_CLOEXEC.
;;
;; The table is pinned over the tags a run does NOT have, because the row that
;; broke can only be reached from a host we do not build on. The *-for-tag
;; entry points exist for that; the last check ties the table back to reality by
;; requiring the pb probe to agree with what this host's native tag says.

(import (chezscheme))
(load "host/chez/scheme-adapter-runtime.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (row tag fam arch endian)
  (ok (format "~a -> os ~a" tag fam)     (eq? (sa-os-family-for-tag tag) fam))
  (ok (format "~a -> arch ~a" tag arch)  (eq? (sa-arch-for-tag tag) arch))
  (ok (format "~a -> endian ~a" tag endian) (eq? (sa-endian-for-tag tag) endian)))

;; Native tags: the tag names the OS and every row is decided by the tag alone.
;; endian is #f for the osx/nt tags because their suffix is not le/be — the
;; stat-layout guard reads that as "unverified" and nio-file keys those hosts
;; off sa-os-family instead.
(row "tarm64osx" 'macos   'arm64  #f)
(row "a6osx"     'macos   'x86-64 #f)
(row "ta6nt"     'windows 'x86-64 #f)
(row "i3nt"      'windows 'i386   #f)
(row "ta6le"     'linux   'x86-64 'little)
(row "arm64le"   'linux   'arm64  'little)
(row "i3le"      'linux   'i386   'little)
(row "a6ob"      'linux   'x86-64 #f)   ; unrecognized OS still degrades to linux

;; Portable-bytecode tags: pb/pb64l/tpb64l name the threading, word size and
;; endianness and deliberately name no OS, so the OS is PROBED and must not be
;; hardcoded. arch stays 'other and endian stays #f: the tag's own 64/l fields
;; are not in the shape either derivation parses, and neither is probed yet, so
;; a pb build on x86-64 Linux still reads as "unverified struct stat layout".
;; That is a known gap, pinned here so closing it is a deliberate edit.
(for-each
  (lambda (tag)
    (ok (format "~a -> os is probed, not assumed" tag)
        (eq? (sa-os-family-for-tag tag) (sa-probed-os-family)))
    (ok (format "~a -> arch other (not derived from the tag)" tag)
        (eq? (sa-arch-for-tag tag) 'other))
    (ok (format "~a -> endian #f (not derived from the tag)" tag)
        (eq? (sa-endian-for-tag tag) #f)))
  '("pb" "pb64l" "pb64b" "pb32l" "tpb64l" "tpb64b"))

;; The probe is a cache, and the answer cannot change while the process runs.
(ok "probe is stable across calls" (eq? (sa-probed-os-family) (sa-probed-os-family)))

;; And it is RIGHT: this run is a native build, whose tag names the OS
;; independently. The probe has to reach the same verdict — that is the whole
;; claim a bytecode build then rests on, checked on every host the gate runs on.
(ok (format "probe agrees with the native tag ~s (~a)" (sa-host-tag) (sa-os-family))
    (or (eq? (sa-os-family-for-tag (sa-host-tag)) (sa-probed-os-family))
        ;; a pb gate run has no independent answer to compare against; the rows
        ;; above still hold, so do not fail the gate on it.
        (sa-tag-contains? (sa-host-tag) "pb")))

(printf "host-derived-props: ~a checks, ~a failures\n" total fails)
(when (> fails 0) (exit 1))
