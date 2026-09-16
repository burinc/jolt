;; The lexical half of java.io.File/getCanonicalPath, per platform
;; (jolt-lang/jolt#991). Run:
;;   chez --script test/chez/win-path-test.ss
;;
;; realpath(3) is not bound on a Windows build, so THIS is the whole of
;; getCanonicalPath there — and its POSIX-only spelling rejoined every segment
;; as "/" + segment, so `(babashka.fs/canonicalize "C:/Users/x/a.txt")` answered
;; "/C:/Users/x/a.txt": a path rooted on the current drive, which every later
;; read or write resolved as "C:/C:/Users/x/…" and failed. Backslashes were
;; worse — no separator was recognized, so the whole path was one segment.
;;
;; The Windows rows are the reason the platform is a parameter: they are
;; unreachable from the host that runs CI, and the walk that re-attaches a
;; missing tail to its longest existing ancestor takes realpath as a parameter
;; too, so it is driven here from a table rather than from a filesystem.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/io.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (row label windows? given want)
  (let ((got (jfile-fold-dots-for windows? given)))
    (set! total (+ total 1))
    (unless (string=? got want)
      (set! fails (+ fails 1))
      (printf "FAIL: ~a (windows? ~s): ~s -> ~s, want ~s\n" label windows? given got want))))

;; --- POSIX is unchanged ------------------------------------------------------
;; "\" is an ordinary filename character here and stays one; a doubled separator
;; collapses; "." and ".." fold; the root is its own answer.
(row "posix absolute"      #f "/a/b"            "/a/b")
(row "posix dot"           #f "/a/./b"          "/a/b")
(row "posix dotdot"        #f "/a/c/../b"       "/a/b")
(row "posix dotdot at root" #f "/a/../.."       "/")
(row "posix doubled sep"   #f "/a//b"           "/a/b")
(row "posix leading pair"  #f "//a/b"           "/a/b")
(row "posix root"          #f "/"               "/")
(row "posix backslash is a name" #f "/a/b\\c"   "/a/b\\c")
;; a relative path stays relative rather than growing a root it never had
(row "posix relative"      #f "a/b"             "a/b")
(row "posix relative dot"  #f "a/./b"           "a/b")

;; --- Windows: the root is reproduced, never invented -------------------------
;; Rendered with "/", which is what getAbsolutePath, babashka.fs/absolutize and
;; babashka.fs/normalize already answer with on Windows — so canonicalize agrees
;; with its neighbours, and one file has ONE canonical string however the caller
;; spelled its separators. That identity is what getCanonicalPath exists for.
(row "drive slash"         #t "C:/Users/x/a.txt"  "C:/Users/x/a.txt")
(row "drive backslash"     #t "C:\\Users\\x\\a.txt" "C:/Users/x/a.txt")
(row "drive mixed"         #t "C:\\Users\\x/a.txt"  "C:/Users/x/a.txt")
(row "drive lowercase"     #t "d:/x"               "d:/x")
(row "drive root only"     #t "C:/"                "C:/")
(row "drive dot"           #t "C:/a/./b"           "C:/a/b")
(row "drive dotdot"        #t "C:\\a\\c\\..\\b"    "C:/a/b")
(row "drive dotdot past root" #t "C:/a/../.."      "C:/")
(row "drive doubled sep"   #t "C:/a//b"            "C:/a/b")
;; UNC: \\server\share is the root, so neither half may be folded away by a ".."
(row "unc"                 #t "\\\\srv\\sh\\a\\b"  "//srv/sh/a/b")
(row "unc forward"         #t "//srv/sh/a"         "//srv/sh/a")
(row "unc root only"       #t "//srv/sh"           "//srv/sh/")
(row "unc dotdot past root" #t "//srv/sh/a/../.."  "//srv/sh/")
;; device paths (\\?\C:\x) have the same two-segment root shape
(row "device path"         #t "\\\\?\\C:\\a"       "//?/C:/a")
;; rooted on the current drive: still not a drive, so it keeps the one "/" it
;; was given and gains nothing
(row "current-drive rooted" #t "/a/b"              "/a/b")
;; C:a names the per-drive current directory, which this process cannot see.
;; Keep the caller's meaning rather than invent a root for it — "/C:a" named a
;; different file, and "C:/a" would silently name the drive's root.
(row "drive-relative kept" #t "C:a\\b"             "C:a/b")
(row "relative"            #t "a\\b"               "a/b")

;; --- the missing-tail walk ---------------------------------------------------
;; The JVM canonicalizes a path whose tail does not exist by resolving the
;; longest ancestor that DOES and re-attaching the rest. Driven from a table:
;; "C:/Users/real" is the deepest thing that exists, and it answers under a
;; different spelling (a junction), which is exactly what must survive.
(define (fake-realpath p)
  (cond ((string=? p "C:/Users/real") "C:/Users/target")
        ((string=? p "/u/real") "/u/target")
        (else #f)))
(define (canon label windows? given want)
  (let ((got (jfile-canonical-for windows? fake-realpath given)))
    (set! total (+ total 1))
    (unless (string=? got want)
      (set! fails (+ fails 1))
      (printf "FAIL: ~a: ~s -> ~s, want ~s\n" label given got want))))

(canon "existing path answers realpath" #t "C:/Users/real" "C:/Users/target")
(canon "missing leaf re-attaches"       #t "C:/Users/real/nope.txt" "C:/Users/target/nope.txt")
(canon "missing tree re-attaches"       #t "C:/Users/real/no/such/f" "C:/Users/target/no/such/f")
(canon "backslash input walks too"      #t "C:\\Users\\real\\nope.txt" "C:/Users/target/nope.txt")
(canon "dotdot folds in the missing tail" #t "C:/Users/real/no/../d/f" "C:/Users/target/d/f")
;; nothing on the path exists: the whole thing folds lexically, root intact
(canon "no ancestor resolves"           #t "C:/gone/./a/../b" "C:/gone/b")
(canon "posix walk unchanged"           #f "/u/real/nope.txt" "/u/target/nope.txt")
(canon "posix no ancestor resolves"     #f "/gone/./a/../b" "/gone/b")

(if (> fails 0)
    (begin (printf "WIN-PATH FAILURES: ~a of ~a\n" fails total) (exit 1))
    (printf "WIN-PATH OK (~a checks)\n" total))
