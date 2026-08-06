;; jolt.process gate — exercises the public sub-process API against real programs.
;; Run: bin/jolt run test/chez/process-test.clj (smoke.sh greps for "PROCESS-TEST OK").
(ns process-test
  (:require [jolt.process :as p :refer [process sh check pipeline]]
            [jolt.fs :as fs]
            [clojure.string :as str]))

(def failures (atom []))

;; A MACRO, not a fn, so the label is announced BEFORE the expression under test runs
;; — as a fn, `got` is evaluated at the call site and a check that blocks never
;; reaches the announcement. Every check here spawns a real child process, so any one
;; of them can block forever on a pipe or a wait, and this file used to print nothing
;; until the final verdict: a hung check left an empty log with no way to tell which.
;; (It hung the CI gate for over three hours exactly this way; jolt-pgbh.)
;;
;; The flush is load-bearing, not decoration: smoke.sh redirects this to a file, where
;; output is block-buffered, so a killed process loses whatever it had not flushed —
;; which is how "it printed nothing at all" survived even a 120s cap.
(defmacro check-eq [label got want]
  `(do
     (print (str "  .. " ~label "\n"))
     (flush)
     (let [g# ~got w# ~want]
       (when-not (= g# w#)
         (swap! failures conj (str ~label ": want " (pr-str w#) " got " (pr-str g#)))))))

;; tokenize (pure)
(check-eq "tokenize" (p/tokenize "a  b 'c d'") ["a" "b" "c d"])
(check-eq "tokenize empty" (p/tokenize "") [])

;; capture stdout / exit codes
(check-eq "sh out" (:out (sh ["echo" "hello"])) "hello\n")
(check-eq "sh exit 0" (:exit (sh ["true"])) 0)
(check-eq "sh exit 1" (:exit (sh ["false"])) 1)
(check-eq "exit code passthrough" (:exit (sh ["sh" "-c" "exit 7"])) 7)

;; args are literal (no shell splitting/globbing of an argument)
(check-eq "literal arg" (:out (sh ["echo" "a b  c"])) "a b  c\n")

;; stderr: capture, and merge into stdout
(check-eq "err capture" (:err (sh ["sh" "-c" "echo boom 1>&2"] {:err :string})) "boom\n")
(check-eq "err->out" (:out (sh ["sh" "-c" "echo e 1>&2"] {:err :out})) "e\n")

;; stdin: feed a string
(check-eq "in string" (:out (sh ["cat"] {:in "line1\nline2\n"})) "line1\nline2\n")

;; :dir and :env / :extra-env
(check-eq "dir" (:out (sh ["pwd"] {:dir "/tmp"})) "/tmp\n")
(check-eq "env replace" (:out (sh ["sh" "-c" "echo $JP_VAR"] {:env {"JP_VAR" "set"}})) "set\n")
(check-eq "extra-env keeps PATH" (:out (sh ["sh" "-c" "echo $JP_X"] {:extra-env {"JP_X" "y"}})) "y\n")

;; check throws on non-zero, returns the derefed process on success
(check-eq "check ok exit" (:exit (check (process ["true"]))) 0)
(check-eq "check throws"
          (try (check (process ["false"])) :no-throw (catch Exception _ :threw)) :threw)

;; pipelines via threading and via pipeline
(check-eq "pipe ->" (-> (process ["printf" "a\nb\nc\n"]) (process ["grep" "b"]) :out slurp) "b\n")
(check-eq "pipeline count" (count (pipeline (-> (process ["echo" "x"]) (process ["cat"])))) 2)

;; process record deref carries :out/:exit
(let [res @(process ["echo" "derefed"] {:out :string})]
  (check-eq "deref out" (:out res) "derefed\n")
  (check-eq "deref exit" (:exit res) 0))

;; :out to a file
(let [tmp (str (fs/create-temp-file {:prefix "jp-" :suffix ".txt"}))]
  @(process ["echo" "to-file"] {:out tmp})
  (check-eq "out->file" (slurp tmp) "to-file\n")
  (fs/delete-if-exists tmp))

;; alive? / destroy / signal exit code
(let [proc (process ["sleep" "10"])]
  (check-eq "alive?" (p/alive? proc) true)
  (p/destroy proc)
  (check-eq "sigterm exit" (:exit @proc) 143)
  (check-eq "dead after destroy" (p/alive? proc) false))

;; a spawned child inherits the user's cwd (user.dir / JOLT_PWD), not jolt's OS cwd
;; (the launcher cd's to the repo root but preserves the user's cwd in JOLT_PWD)
(check-eq "child cwd = user.dir"
          (str (fs/canonicalize (str/trim (:out (sh ["pwd"])))))
          (str (fs/canonicalize (System/getProperty "user.dir"))))
;; an explicit :dir sets the child's cwd (pwd echoes the logical cd path)
(let [sub (fs/create-temp-dir {:prefix "jp-dir-"})]
  (check-eq "dir set" (str/trim (:out (sh ["pwd"] {:dir (str sub)}))) (str sub))
  (fs/delete-tree sub))

;; ProcessBuilder.start throws (like the JVM) when the program can't be resolved,
;; with a "No such file" message — not a shell "not found" after spawning
(check-eq "missing program throws"
          (try (sh ["definitely-no-such-program-xyz"]) :no-throw
               (catch Exception e (if (re-find #"No such file" (str (ex-message e))) :nosuch :other)))
          :nosuch)

;; A child that cannot be waited on must still produce an answer. With SIGCHLD set
;; to SIG_IGN the kernel reaps every child itself, so waitpid can only ever fail
;; with ECHILD — and the reap loop used to treat that as "ask again", spinning
;; forever while holding the process mutex. No output, no exit, for as long as the
;; caller waited: that is what sat on a CI gate for 3h42m (jolt-pgbh). The
;; disposition survives exec, so jolt can inherit it from a parent it never chose,
;; which is why it reproduced on one runner and nowhere else.
;;
;; Set it here deliberately, after a spawn has already run (so the spawn path's
;; SIG_DFL restore has happened and is not what is under test), to put the reap
;; loop in exactly that state. If this check hangs, the spin is back — smoke.sh's
;; per-case cap names it.
(jolt.ffi/load-library)
(def c-signal (jolt.ffi/__cfn "signal" [:int :pointer] :pointer))
(def SIGCHLD (if (str/includes? (System/getProperty "os.name") "Mac") 20 17))
;; Every blocking call stays INSIDE a check-eq, so the label is announced before it
;; runs: written as a `let` binding instead, the deref hangs before anything is
;; printed and the log ends on the PREVIOUS check's label — pointing at the wrong
;; one. (Verified by reintroducing the spin: that is exactly what it did.)
(let [prev (c-signal SIGCHLD 1)]                     ; 1 = SIG_IGN
  ;; 0 when the kernel auto-reaped it (the status is then unrecoverable — a
  ;; documented divergence from the JVM, which always reaps its own children), or
  ;; the true 5 on a platform that still let us reap. Never a hang.
  (check-eq "unwaitable child still yields an exit code"
            (contains? #{0 5} (:exit @(process ["sh" "-c" "exit 5"]))) true)
  ;; a signalled child's status IS recoverable without waitpid: 128+signal
  (let [proc (process ["sleep" "10"])]
    (p/destroy proc)
    (check-eq "unwaitable signalled child reports 128+SIGTERM" (:exit @proc) 143))
  (c-signal SIGCHLD prev))                           ; put the disposition back

;; class / instance? derive from the central registry
(check-eq "pb instance?" (instance? java.lang.ProcessBuilder (java.lang.ProcessBuilder. ["true"])) true)
(check-eq "proc class" (.getName (class (:proc @(process ["true"])))) "java.lang.Process")

;; --- fd-level INHERIT ---------------------------------------------------------
;; Redirect.INHERIT hands the child jolt's REAL fds (posix_spawn leaves 0/1/2
;; untouched), not a pump-fed pipe. Two things only real inheritance can do:
;; the child sees a tty when jolt runs on one, and successive INHERIT-stdin
;; children share the fd offset. Both run a nested jolt, because this test's
;; own stdio belongs to the smoke harness.
(def jolt-bin (or (System/getenv "JOLT_BIN") "bin/jolt"))
(def mac? (str/includes? (System/getProperty "os.name") "Mac"))

;; a child that writes through INHERIT lands on the nested jolt's stdout
(let [nested (str "(-> (java.lang.ProcessBuilder. [\"sh\" \"-c\" \"echo INHERITED-OUT\"])"
                  " (.redirectOutput java.lang.ProcessBuilder$Redirect/INHERIT)"
                  " (.start) (.waitFor))")
      out (:out (sh [jolt-bin "-e" nested]))]
  (check-eq "INHERIT stdout reaches the parent's stdout"
            (str/includes? out "INHERITED-OUT") true))

;; isatty: under a pty (script(1)), an INHERIT child's stdout IS the terminal.
;; A pump-fed pipe can never answer true here.
(when (fs/which "script")
  (let [nested (str "(-> (java.lang.ProcessBuilder. [\"sh\" \"-c\" \"test -t 1 && echo IS-A-TTY || echo NOT-A-TTY\"])"
                    " (.redirectOutput java.lang.ProcessBuilder$Redirect/INHERIT)"
                    " (.start) (.waitFor))")
        cmd (if mac?
              ["script" "-q" "/dev/null" jolt-bin "-e" nested]
              ["script" "-qec" (str jolt-bin " -e '" nested "'") "/dev/null"])
        out (:out (sh cmd))]
    (check-eq "INHERIT stdout is the real fd (isatty under a pty)"
              (str/includes? out "IS-A-TTY") true)))

;; INHERIT stdin shares the fd AND its read offset: a first child consuming
;; exactly two bytes leaves the rest for the second. The pumps slurped ahead
;; into the first child's pipe, starving the second.
(let [nested (str "(let [rd (fn [cmd] (let [p (-> (java.lang.ProcessBuilder. cmd)"
                  " (.redirectInput java.lang.ProcessBuilder$Redirect/INHERIT) (.start))]"
                  " (.waitFor p) (slurp (.getInputStream p))))]"
                  " (rd [\"sh\" \"-c\" \"dd bs=1 count=2 2>/dev/null >/dev/null\"])"
                  " (print (str \"SECOND=<\" (rd [\"cat\"]) \">\")))")
      out (:out (sh [jolt-bin "-e" nested] {:in "ABCD"}))]
  (check-eq "INHERIT stdin shares the fd offset between children"
            (str/includes? out "SECOND=<CD>") true))

(if (empty? @failures)
  (println "PROCESS-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "PROCESS-TEST FAILED:" (count @failures))))
