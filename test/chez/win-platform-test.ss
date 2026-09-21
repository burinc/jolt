;; The Windows-shaped answers a Linux runner can never observe
;; (jolt-lang/jolt#1074). Run:
;;   chez --script test/chez/win-platform-test.ss
;;
;; Every one of these shipped in v0.8.10 because nothing here was a parameter,
;; so each row was whichever one the CI host happened to be:
;;
;;   * path.separator answered ":" on Windows, where ":" is the drive suffix.
;;     (babashka.fs/split-paths "C:/a;C:/b") came back ["C" "/a;C" "/b"], so
;;     fs/exec-paths was garbage and fs/which never found anything.
;;   * ProcessBuilder split PATH on ":" too, treated only a leading "/" as
;;     absolute, and knew nothing of PATHEXT — so a bare "curl" and a
;;     drive-absolute "C:/Windows/System32/curl.exe" were both unresolvable and
;;     babashka.process threw before a spawn was attempted.
;;   * The java.nio.file Path shim had a POSIX-only root, so a drive path was a
;;     RELATIVE path whose first segment happened to be "C:": fs/absolute? said
;;     false, getRoot said nil, getParent walked off the drive letter and
;;     normalize could fold a path above its own root.
;;   * java.io.tmpdir read only TMPDIR, which Windows does not set, so every
;;     temp file went to "/tmp" on whichever drive the process was on.
;;   * File/listRoots answered "/" instead of enumerating the mounted drives.
;;   * spit staged into a temp file and renamed over the target, and Windows
;;     refuses a rename onto an existing destination — so the SECOND spit to any
;;     path failed. That one needs a real filesystem and is gated on the Windows
;;     runner (.github/workflows/tests.yml); what is pinned here is the POSIX
;;     half of the same helper, which must keep replacing without the delete.
;;
;; Like host-derived-props-test.ss and win-path-test.ss, the table is pinned over
;; the platform the run does NOT have: the *-for entry points exist for exactly
;; that, and the row that broke is only reachable from a host we do not gate on.

(import (chezscheme))
(load "host/chez/gate-boot.ss")
(load "host/chez/java/io.ss")
(load "host/chez/java/process.ss")

(define total 0) (define fails 0)
(define (ok name pred)
  (set! total (+ total 1))
  (unless pred (set! fails (+ fails 1)) (printf "FAIL: ~a\n" name)))
(define (same name got want)
  (set! total (+ total 1))
  (unless (equal? got want)
    (set! fails (+ fails 1))
    (printf "FAIL: ~a: got ~s, want ~s\n" name got want)))

;; --- the PATH-list separator -------------------------------------------------
;; Not the file separator: ";" on Windows because ":" is the drive suffix.
(same "posix path-list separator"   (path-list-separator-for #f) ":")
(same "windows path-list separator" (path-list-separator-for #t) ";")
;; and the running host still answers for itself, so this file cannot pass by
;; pinning a table that nothing consults
(same "this host's separator" (path-list-separator)
      (path-list-separator-for (eq? (sa-os-family) 'windows)))

;; --- PATH splitting ----------------------------------------------------------
;; The entry that motivated the whole issue: a drive-lettered directory survives
;; intact only when the split knows ";".
(same "windows PATH keeps drive letters"
      (proc-path-entries-for #t "C:\\Windows\\System32;C:\\Users\\x\\bin")
      '("C:\\Windows\\System32" "C:\\Users\\x\\bin"))
(same "posix PATH is unchanged"
      (proc-path-entries-for #f "/usr/bin:/usr/local/bin")
      '("/usr/bin" "/usr/local/bin"))
;; a ":" inside a Windows entry is data, and a ";" inside a POSIX one is too
(same "windows does not split on colon"
      (proc-path-entries-for #t "C:/a") '("C:/a"))
(same "posix does not split on semicolon"
      (proc-path-entries-for #f "/a;b") '("/a;b"))
;; cmd's quotes around an entry holding a space are the shell's, not the name's
(same "windows entry is unquoted"
      (proc-path-entries-for #t "\"C:\\Program Files\\x\";C:\\y")
      '("C:\\Program Files\\x" "C:\\y"))
(same "an empty PATH yields one empty entry, which the walk skips"
      (proc-path-entries-for #t "") '(""))

;; --- joining a directory to a program name -----------------------------------
;; A native Windows directory keeps its backslashes rather than gaining a mixed
;; spelling; a trailing separator of either kind is not doubled.
(same "windows native join"      (proc-path-join-for #t "C:\\Windows\\System32" "curl.exe")
      "C:\\Windows\\System32\\curl.exe")
(same "windows slash join"       (proc-path-join-for #t "C:/Windows/System32" "curl.exe")
      "C:/Windows/System32/curl.exe")
(same "windows trailing backslash" (proc-path-join-for #t "C:\\bin\\" "x.exe") "C:\\bin\\x.exe")
(same "windows trailing slash"   (proc-path-join-for #t "C:/bin/" "x.exe") "C:/bin/x.exe")
(same "windows mixed prefers slash" (proc-path-join-for #t "C:/a\\b" "x") "C:/a\\b/x")
(same "posix join"               (proc-path-join-for #f "/usr/bin" "curl") "/usr/bin/curl")
(same "posix trailing slash"     (proc-path-join-for #f "/usr/bin/" "curl") "/usr/bin/curl")
;; on POSIX a trailing backslash is part of the filename, so it is NOT a
;; separator and the join still adds one
(same "posix trailing backslash is a name" (proc-path-join-for #f "/usr/b\\" "curl")
      "/usr/b\\/curl")
(same "empty base"               (proc-path-join-for #t "" "curl.exe") "curl.exe")

;; --- what counts as a separator in a program name ----------------------------
(ok "windows sees a backslash"      (proc-has-separator-for? #t "bin\\x"))
(ok "windows sees a slash"          (proc-has-separator-for? #t "bin/x"))
(ok "posix sees a slash"            (proc-has-separator-for? #f "bin/x"))
;; a backslash is an ordinary filename character on POSIX, so "a\b" is a bare
;; name to look up on PATH, not a relative path
(ok "posix backslash is not a separator" (not (proc-has-separator-for? #f "a\\b")))
(ok "a bare name has none"          (not (proc-has-separator-for? #t "curl")))

;; --- PATHEXT candidates ------------------------------------------------------
;; The bare name is tried FIRST, so a program that already carries its extension
;; resolves as itself rather than as "curl.exe.COM".
(same "windows default PATHEXT" (proc-name-candidates-for #t #f "curl")
      '("curl" "curl.COM" "curl.EXE" "curl.BAT" "curl.CMD"))
(same "windows honors PATHEXT" (proc-name-candidates-for #t ".EXE;.PS1" "curl")
      '("curl" "curl.EXE" "curl.PS1"))
(same "an empty PATHEXT falls back to cmd's list"
      (proc-name-candidates-for #t "" "curl")
      '("curl" "curl.COM" "curl.EXE" "curl.BAT" "curl.CMD"))
(same "empty PATHEXT entries are dropped"
      (proc-name-candidates-for #t ".EXE;;" "curl") '("curl" "curl.EXE"))
(same "posix has no extension search" (proc-name-candidates-for #f ".EXE" "curl") '("curl"))

;; --- program resolution ------------------------------------------------------
;; Driven from a table rather than a filesystem, the way win-path-test.ss drives
;; realpath: these are the files each platform's run is asked to believe in.
(define win-files
  '("C:\\Windows\\System32\\curl.exe"
    "C:\\Users\\x\\bin\\tool.bat"
    "C:\\proj\\sub\\local.exe"
    "\\\\srv\\sh\\net.exe"
    "\\WinRooted\\only.exe"))
(define posix-files
  '("/usr/bin/curl" "/proj/sub/local" "/usr/bin/weird\\name"))
;; The Windows table is matched case-insensitively and with either separator
;; spelling, because that is what NTFS is: "C:/Windows/System32/CURL.EXE" and
;; "C:\Windows\System32\curl.exe" open the same file. A table that insisted on
;; one spelling would fail rows the real platform passes — and would make the
;; PATHEXT rows (which append ".EXE" to a file named curl.exe) meaningless.
(define (win-key p)
  (string-downcase
   (list->string (map (lambda (c) (if (char=? c #\\) #\/ c)) (string->list p)))))
(define win-keys (map win-key win-files))
(define (win-exists? p) (and (member (win-key p) win-keys) #t))
;; POSIX is neither: case and backslashes are part of the name.
(define (posix-exists? p) (and (member p posix-files) #t))

(define win-path "C:\\Windows\\System32;C:\\Users\\x\\bin")
(define (winres prog) (proc-program-resolvable-for? #t #f win-path "C:\\proj" prog win-exists?))
(define (posixres prog) (proc-program-resolvable-for? #f #f "/usr/bin" "/proj" prog posix-exists?))

;; the three shapes the issue reported as broken
(ok "windows bare name resolves through PATHEXT" (winres "curl"))
(ok "windows drive-absolute with slashes"        (winres "C:/Windows/System32/curl.exe"))
(ok "windows drive-absolute with backslashes"    (winres "C:\\Windows\\System32\\curl.exe"))
;; a .bat on PATH is found the same way
(ok "windows PATHEXT reaches .bat"               (winres "tool"))
;; UNC and current-drive-rooted programs are named as spelled, never joined to
;; the child cwd
(ok "windows UNC program"                        (winres "\\\\srv\\sh\\net.exe"))
(ok "windows current-drive-rooted program"       (winres "\\WinRooted\\only.exe"))
;; a separator-bearing relative program resolves against the child cwd
(ok "windows relative program joins the cwd"     (winres "sub\\local.exe"))
(ok "windows relative program, slash spelling"   (winres "sub/local.exe"))
;; and what is genuinely absent still says so
(ok "windows missing bare name"                  (not (winres "nosuch")))
(ok "windows missing absolute"                   (not (winres "C:\\nope.exe")))
(ok "windows missing relative"                   (not (winres "sub\\nope.exe")))
(ok "an empty program is unresolvable"           (not (winres "")))

;; POSIX keeps every answer it had
(ok "posix bare name on PATH"        (posixres "curl"))
(ok "posix absolute"                 (posixres "/usr/bin/curl"))
(ok "posix relative joins the cwd"   (posixres "sub/local"))
(ok "posix missing bare name"        (not (posixres "nosuch")))
(ok "posix missing absolute"         (not (posixres "/nope")))
(ok "an empty posix program is unresolvable" (not (posixres "")))
;; no extension is ever appended on POSIX: "curl" must not resolve because
;; "curl.EXE" happens to exist
(ok "posix appends no extension"
    (not (proc-program-resolvable-for? #f ".EXE" "/usr/bin" "/proj" "weird"
                                       (lambda (p) (string=? p "/usr/bin/weird.EXE")))))
;; a backslash-bearing name on POSIX is a bare name, looked up on PATH
(ok "posix backslash name goes to PATH" (posixres "weird\\name"))

;; --- absolute-path classification, as the resolver asks it -------------------
(ok "windows drive with slash is absolute"     (jfile-path-absolute-for? #t "C:/x"))
(ok "windows drive with backslash is absolute" (jfile-path-absolute-for? #t "C:\\x"))
(ok "windows UNC is absolute"                  (jfile-path-absolute-for? #t "\\\\srv\\sh"))
(ok "windows single slash is NOT absolute"     (not (jfile-path-absolute-for? #t "/x")))
(ok "windows drive-relative is NOT absolute"   (not (jfile-path-absolute-for? #t "C:x")))
(ok "posix slash is absolute"                  (jfile-path-absolute-for? #f "/x"))
(ok "posix drive letter is NOT absolute"       (not (jfile-path-absolute-for? #f "C:/x")))
(ok "windows single slash is root-relative"    (windows-root-relative-for? #t "\\x"))
(ok "windows UNC is not root-relative"         (not (windows-root-relative-for? #t "\\\\srv\\sh")))
(ok "posix has no root-relative shape"         (not (windows-root-relative-for? #f "/x")))

;; --- the java.nio.file Path shim's root ---------------------------------------
;; A Path's ROOT is the prefix that is not a segment. The shim assumed the POSIX
;; shape everywhere, so on Windows a drive path was a RELATIVE path whose first
;; segment happened to be "C:" — which is what made (fs/absolute? "C:/Windows")
;; answer false, getRoot answer nil, and getParent walk off the drive letter.
(define (root label windows? given want)
  (same label (npath-root-for windows? given) want))
(root "posix absolute root"      #f "/a/b"            "/")
(root "posix relative has none"  #f "a/b"             "")
(root "posix backslash is a name" #f "\\a\\b"           "")
(root "windows drive root"       #t "C:/a"            "C:/")
(root "windows drive root, backslash" #t "C:\\a"       "C:/")
(root "windows drive-relative"   #t "C:a"             "C:")
(root "windows current-drive rooted" #t "\\a"          "/")
(root "windows UNC root"         #t "\\\\srv\\sh\\a"    "//srv/sh/")
(root "windows relative has none" #t "a\\b"           "")

;; isAbsolute is not "has a root": "\x" and "C:x" are rooted but name nothing on
;; their own, so the JVM calls neither absolute.
(ok "windows drive path is absolute"      (npath-absolute-for? #t "C:/a"))
(ok "windows UNC path is absolute"        (npath-absolute-for? #t "\\\\srv\\sh\\a"))
(ok "windows current-drive rooted is not" (not (npath-absolute-for? #t "\\a")))
(ok "windows drive-relative is not"       (not (npath-absolute-for? #t "C:a")))
(ok "posix absolute is absolute"          (npath-absolute-for? #f "/a"))

;; segments never include the root
(same "windows drive segments"   (npath-segs-for #t "C:\\a\\b") '("a" "b"))
(same "windows UNC segments"     (npath-segs-for #t "\\\\srv\\sh\\a") '("a"))
(same "posix segments"           (npath-segs-for #f "/a/b") '("a" "b"))
(same "posix keeps a backslash in a name" (npath-segs-for #f "/a\\b") '("a\\b"))

;; getParent: the parent of the last segment under a root IS the root, and a
;; root has no parent. This used to answer "/" for every rooted path, so the
;; parent of "C:/a" was a directory on another drive.
(define (parent label windows? given want)
  (same label (npath-parent-for windows? given) want))
(parent "windows drive leaf"     #t "C:/a"      "C:/")
(parent "windows drive deeper"   #t "C:\\a\\b"   "C:/a")
(parent "windows drive root"     #t "C:/"       jolt-nil)
(parent "windows UNC leaf"       #t "\\\\srv\\sh\\a" "//srv/sh/")
(parent "windows relative leaf"  #t "a"         jolt-nil)
(parent "posix leaf"             #f "/a"        "/")
(parent "posix deeper"           #f "/a/b"      "/a")
(parent "posix root"             #f "/"         jolt-nil)
(parent "posix relative leaf"    #f "a"         jolt-nil)

;; normalize: ".." cannot climb above a root, but survives above a relative path
(define (norm label windows? given want)
  (same label (npath-normalize-for windows? given) want))
(norm "windows drive dotdot"     #t "C:/a/../b"   "C:/b")
(norm "windows drive dotdot past root" #t "C:/a/../.." "C:/")
(norm "windows backslash dot"    #t "C:\\a\\.\\b"   "C:/a/b")
(norm "windows UNC past root"    #t "\\\\srv\\sh\\a\\.." "//srv/sh/")
(norm "windows relative keeps dotdot" #t "a\\..\\..\\b" "../b")
(norm "posix dotdot"             #f "/a/../b"     "/b")
(norm "posix past root"          #f "/a/../.."    "/")
(norm "posix relative keeps dotdot" #f "a/../../b" "../b")
(norm "posix empty stays empty"  #f ""            "")

;; resolve: an absolute other replaces this; a Windows other that is rooted but
;; not absolute takes THIS path's root
(define (res label windows? a b want)
  (same label (npath-resolve-for windows? a b) want))
;; a native parent keeps its backslashes rather than gaining a mixed spelling
(res "windows relative child"    #t "C:\\Windows\\System32" "curl.exe" "C:\\Windows\\System32\\curl.exe")
(res "windows slash parent keeps slashes" #t "C:/Windows/System32" "curl.exe" "C:/Windows/System32/curl.exe")
(res "windows absolute other wins" #t "C:/a" "D:/b" "D:/b")
(res "windows rooted other takes this root" #t "C:/a" "\\b" "C:/b")
(res "windows rooted other, rootless this" #t "a" "\\b" "\\b")
(res "windows empty other"       #t "C:/a" "" "C:/a")
(res "posix relative child"      #f "/usr/bin" "curl" "/usr/bin/curl")
(res "posix absolute other wins" #f "/usr/bin" "/bin/sh" "/bin/sh")
(res "posix trailing separator not doubled" #f "/usr/bin/" "curl" "/usr/bin/curl")
;; on POSIX a leading backslash is an ordinary name, so it is a plain child
(res "posix backslash other is a child" #f "/usr" "\\b" "/usr/\\b")

;; startsWith compares ROOTS, not merely absoluteness — "C:/a" does not start
;; with "D:/" though both are rooted — and is spelling-independent, since the
;; root renders with "/" either way
(ok "windows same drive"          (npath-starts-with-for #t "C:/a/b" "C:\\a"))
(ok "windows different drive"     (not (npath-starts-with-for #t "C:/a" "D:/a")))
(ok "windows rooted vs relative"  (not (npath-starts-with-for #t "C:/a" "a")))
(ok "posix prefix"                (npath-starts-with-for #f "/a/b" "/a"))
(ok "posix absolute vs relative"  (not (npath-starts-with-for #f "/a/b" "a")))

;; --- the two-arg File constructor's resolve ----------------------------------
;; FileSystem.resolve(parent, child). Every POSIX row here is the JVM's own
;; answer, taken from a real JDK run, because this is the behaviour the rewrite
;; had to preserve exactly; the Windows rows are the ones a Linux runner cannot
;; reach. The old code asked (string=? p "/") — "is the parent the root", written
;; for the one platform that has a single root.
(define (join label windows? p c want)
  (same label (jolt-file-join-for windows? p c) want))
(join "posix child"                 #f "/a/b" "c"   "/a/b/c")
(join "posix rooted child"          #f "/a/b" "/c"  "/a/b/c")
(join "posix empty child"           #f "/a/b" ""    "/a/b")
(join "posix separator child"       #f "/a/b" "/"   "/a/b")
(join "posix root parent"           #f "/"    "c"   "/c")
(join "posix root parent, rooted child" #f "/" "/c" "/c")
(join "posix root parent, empty"    #f "/"    ""    "/")
(join "posix empty parent defaults to the root" #f "" "c" "/c")
(join "posix relative parent"       #f "a"    "b"   "a/b")
(join "posix relative parent, rooted child" #f "a" "/b" "a/b")
(join "posix nested child"          #f "/a"   "b/c" "/a/b/c")

;; Windows: a backslash is a separator too, and every root ends in one — so the
;; drive root joins without doubling, exactly as "/" does on POSIX.
(join "windows drive root parent"   #t "C:/"  "c"        "C:/c")
(join "windows drive root, rooted child" #t "C:/" "/c"   "C:/c")
(join "windows drive root, backslash child" #t "C:/" "\\c" "C:/c")
(join "windows drive parent"        #t "C:/a" "b"        "C:/a/b")
(join "windows drive parent, rooted child" #t "C:/a" "/b" "C:/a/b")
(join "windows native parent keeps backslashes" #t "C:\\a" "b" "C:\\a\\b")
(join "windows native parent, backslash child" #t "C:\\a" "\\b" "C:\\a\\b")
(join "windows UNC root parent"     #t "//srv/sh/" "c"   "//srv/sh/c")
(join "windows UNC parent"          #t "//srv/sh/a" "b"  "//srv/sh/a/b")
(join "windows separator child alone" #t "C:/a" "\\"   "C:/a")
(join "windows empty child"         #t "C:/a" ""         "C:/a")
;; on POSIX a backslash is an ordinary character, so it is a plain child name
;; and the join still adds a "/"
(join "posix backslash child is a name" #f "/a" "\\b"  "/a/\\b")

;; --- as-relative-path asks .isAbsolute ---------------------------------------
;; io/file puts every child through it, so a wrong answer either rejects a legal
;; call or silently joins an absolute path onto a parent.
(define (rel label windows? p absolute?)
  (ok label (eq? (jfile-path-absolute-for? windows? p) absolute?)))
(rel "posix rooted child is rejected"      #f "/c"  #t)
(rel "posix relative child is kept"        #f "c"   #f)
(rel "posix nested relative child is kept" #f "a/b" #f)
;; the two Windows rows the old leading-"/" test got backwards, both ways round
(rel "windows drive child IS absolute"     #t "C:/c" #t)
(rel "windows current-drive child is NOT"  #t "/c"   #f)
(rel "windows UNC child IS absolute"       #t "//srv/sh/c" #t)
(rel "windows relative child is kept"      #t "c"    #f)

;; --- java.io.tmpdir ----------------------------------------------------------
;; TMPDIR is the POSIX spelling; Windows sets TEMP and TMP and not TMPDIR, so
;; the old chain answered "/tmp" on a drive nobody chose.
(define (env-from alist) (lambda (k) (cond ((assoc k alist) => cdr) (else #f))))
(same "posix default" (host-temp-dir-for #f (env-from '())) "/tmp")
(same "posix honors TMPDIR" (host-temp-dir-for #f (env-from '(("TMPDIR" . "/scratch")))) "/scratch")
(same "posix ignores TEMP" (host-temp-dir-for #f (env-from '(("TEMP" . "C:/t")))) "/tmp")
(same "windows honors TMPDIR first"
      (host-temp-dir-for #t (env-from '(("TMPDIR" . "T:/x") ("TEMP" . "C:/t")))) "T:/x")
(same "windows takes TEMP" (host-temp-dir-for #t (env-from '(("TEMP" . "C:/Users/x/Temp")))) "C:/Users/x/Temp")
(same "windows falls back to TMP" (host-temp-dir-for #t (env-from '(("TMP" . "C:/t2")))) "C:/t2")
(same "windows derives one from SystemRoot"
      (host-temp-dir-for #t (env-from '(("SystemRoot" . "D:/Windows")))) "D:/Windows/Temp")
(same "windows last resort" (host-temp-dir-for #t (env-from '())) "C:/Windows/Temp")
;; an empty value is not a value
(same "an empty TMPDIR is ignored" (host-temp-dir-for #f (env-from '(("TMPDIR" . "")))) "/tmp")

;; --- File's trailing-separator normalization ---------------------------------
;; Every java.io.File is built through jolt-path-normalize, which drops a
;; trailing separator — except the one that IS the root. "/" was already
;; protected by a length test; the Windows drive root "C:/" was not, so it
;; normalized to "C:", the drive's CURRENT DIRECTORY, a different file. That is
;; how File/listRoots came back drive-relative on the Windows runner even after
;; it started enumerating drives (#1074). Driven through the File constructor
;; because the invariant belongs to every construction site, not to one helper.
(define (norm-path label windows? given want)
  (same label (jolt-path-normalize-for windows? given) want))
;; POSIX rows first: none of this may move, and the only POSIX path whose
;; trailing separator is its root is "/" itself.
(norm-path "posix root survives"            #f "/"        "/")
(norm-path "posix trailing separator goes"  #f "/a/"      "/a")
(norm-path "posix deeper trailing goes"     #f "/a/b/"    "/a/b")
(norm-path "posix doubled separator folds"  #f "/a//b"    "/a/b")
(norm-path "posix doubled and trailing"     #f "/a//b//"  "/a/b")
(norm-path "posix relative untouched"       #f "a/b"      "a/b")
(norm-path "posix bare name untouched"      #f "a"        "a")
;; a drive letter means nothing on POSIX, so "C:/" is an ordinary relative name
;; whose trailing separator goes
(norm-path "posix has no drive root"        #f "C:/"      "C:")

;; Windows: the drive root and the UNC root keep their separator; everything
;; below them loses it.
(norm-path "windows drive root survives"    #t "C:/"       "C:/")
(norm-path "windows drive child trims"      #t "C:/a/"     "C:/a")
(norm-path "windows deeper child trims"     #t "C:/a/b/"   "C:/a/b")
(norm-path "windows drive root, doubled"    #t "C://"      "C:/")
(norm-path "windows current-drive root"     #t "/"         "/")
;; The drive root and the UNC root are NOT symmetric here, and that is the JVM's
;; asymmetry rather than an accident: java.io.File keeps "C:\\" whole because the
;; separator is what makes it absolute rather than drive-relative, while
;; "\\\\srv\\sh\\" normalizes to "\\\\srv\\sh" — the share IS the root, and the
;; trailing separator adds nothing. path-root-end encodes exactly that: it counts
;; the separator into a drive root and leaves it out of a UNC one. (The
;; java.nio.file Path shim answers "//srv/sh/" for getRoot, WITH the separator,
;; because that is what Path.getRoot does — a different API with a different
;; convention, pinned separately above.)
(norm-path "windows UNC root drops its trailing sep" #t "//srv/sh/" "//srv/sh")
(norm-path "windows UNC root already bare"  #t "//srv/sh"  "//srv/sh")
(norm-path "windows UNC child trims"        #t "//srv/sh/a/" "//srv/sh/a")
(norm-path "windows UNC keeps its leading pair" #t "//srv/sh/a" "//srv/sh/a")
(norm-path "windows drive-relative kept"    #t "C:a/"      "C:a")
(norm-path "windows doubled separator folds" #t "C:/a//b"  "C:/a/b")
;; and the File constructor carries the same invariant, since that is where
;; every construction site goes through
(same "the File constructor keeps a drive root"
      (jolt-path-normalize-for #t "C:/") "C:/")
(same "a File on this host still normalizes"
      (jfile-path (make-jfile "/a/b/")) "/a/b")

;; --- File/listRoots ----------------------------------------------------------
;; One root on POSIX; one per mounted drive on Windows, where "/" named a
;; directory on whichever drive the process was on and enumerated nothing.
(same "posix has one root" (file-list-roots-for #f (lambda (_) #t)) '("/"))
(same "windows enumerates the mounted drives"
      (file-list-roots-for #t (lambda (p) (member p '("C:/" "D:/" "Z:/"))))
      '("C:/" "D:/" "Z:/"))
(same "windows never answers empty"
      (file-list-roots-for #t (lambda (_) #f)) '("C:/"))
(same "windows probes every letter"
      (length (file-list-roots-for #t (lambda (_) #t))) 26)

;; --- rename-replace! on this host --------------------------------------------
;; The Windows branch needs a real Windows filesystem and is gated on the
;; Windows runner. What is checked here is that adding it did not cost POSIX its
;; atomic replace: the destination is replaced in one step, with no window in
;; which it is missing, and a rename onto a directory still fails loudly.
(let* ((d (string-append "target/win-platform-test-" (number->string (sa-real-time-ms))))
       (src (string-append d "/src")) (dst (string-append d "/dst")))
  (mkdirs! d)
  (let ((out (open-output-file src 'replace))) (put-string out "new") (close-output-port out))
  (let ((out (open-output-file dst 'replace))) (put-string out "old") (close-output-port out))
  (rename-replace! src dst)
  (ok "the destination is replaced" (file-exists? dst))
  (ok "the source is gone" (not (file-exists? src)))
  (same "the destination holds the new content"
        (let* ((in (open-input-file dst)) (s (get-string-all in))) (close-input-port in) s)
        "new")
  ;; a rename onto a non-empty directory is an error on both platforms, and the
  ;; Windows pre-delete must not turn it into a silent success
  (let ((sub (string-append d "/sub")))
    (mkdirs! sub)
    (let ((out (open-output-file (string-append sub "/keep") 'replace)))
      (put-string out "k") (close-output-port out))
    (let ((out (open-output-file src 'replace))) (put-string out "n") (close-output-port out))
    (ok "renaming over a non-empty directory still fails"
        (guard (e (#t #t)) (rename-replace! src sub) #f))
    (ok "the directory's contents survive" (file-exists? (string-append sub "/keep")))
    (delete-file (string-append sub "/keep") #f)
    (delete-path! sub))
  (delete-file src #f)
  (delete-file dst #f)
  (delete-path! d))

(if (> fails 0)
    (begin (printf "WIN-PLATFORM FAILURES: ~a of ~a\n" fails total) (exit 1))
    (printf "WIN-PLATFORM OK (~a checks)\n" total))
