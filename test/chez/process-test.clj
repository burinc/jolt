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

;; --- shutdown hooks -----------------------------------------------------------
;; Runtime.addShutdownHook is what babashka.process's `:shutdown` option registers,
;; so if the hooks never run, `:shutdown destroy-tree` cleans up nothing (#571).
;; A nested jolt, because a hook can only be observed by letting a process exit.
(let [out (:out (sh [jolt-bin "-e" (str "(.addShutdownHook (Runtime/getRuntime)"
                                        " (Thread. (fn [] (println \"HOOK\"))))"
                                        " (println \"MAIN\")")]))]
  (check-eq "shutdown hook runs when the process exits" (str/split-lines out) ["MAIN" "HOOK"]))

(let [out (:out (sh [jolt-bin "-e" (str "(.addShutdownHook (Runtime/getRuntime)"
                                        " (Thread. (fn [] (println \"HOOK\"))))"
                                        " (println \"MAIN\") (System/exit 0)")]))]
  (check-eq "shutdown hook runs on System/exit" (str/split-lines out) ["MAIN" "HOOK"]))

;; Chez's exit-handler is a THREAD parameter, so a hook registered from a worker
;; installs the wrapper on that worker and nowhere else. The main thread has to
;; carry one of its own or this hook would be dropped on the way out.
(let [out (:out (sh [jolt-bin "-e" (str "(let [t (Thread. (fn [] (.addShutdownHook (Runtime/getRuntime)"
                                        "                          (Thread. (fn [] (println \"HOOK\"))))))]"
                                        "  (.start t) (.join t) (println \"MAIN\"))")]))]
  (check-eq "a hook registered off the main thread still runs" (str/split-lines out) ["MAIN" "HOOK"]))

(let [out (:out (sh [jolt-bin "-e" (str "(let [rt (Runtime/getRuntime)"
                                        "      h (Thread. (fn [] (println \"HOOK\")))]"
                                        "  (.addShutdownHook rt h) (.removeShutdownHook rt h)"
                                        "  (println \"MAIN\"))")]))]
  (check-eq "a removed shutdown hook does not run" (str/split-lines out) ["MAIN"]))

;; Is a pid still alive? `kill -0` is the portable answer (exit 0 = alive). Run
;; through `sh` so it is the shell BUILTIN: a standalone kill(1) is not on every
;; Linux image, and ProcessBuilder.start rejects a program it cannot resolve.
(defn- pid-alive? [pid]
  (zero? (:exit (sh ["sh" "-c" (str "kill -0 " pid)] {:err :string}))))

;; SIGTERM to a jolt process must run its shutdown hooks BEFORE it exits — the
;; whole point of `:shutdown destroy-tree` is that a supervisor's `kill` does not
;; leave the child tree running (#571). Both spawn paths are covered: the default
;; (piped stdio, Chez's own fork) and fd-level INHERIT (posix_spawn).
;;
;; The nested jolt writes its child's pid out through a shell `$$` — the same
;; probe the bug report used — so this side can ask whether that exact process
;; outlived the parent.
(doseq [[label redirs] [["piped stdio" ""]
                        ["fd-level INHERIT" " :out :inherit :err :inherit"]]]
  (let [pidf (str (fs/create-temp-file {:prefix "jp-shutdown-" :suffix ".pid"}))
        nested (str "(require '[jolt.process :as p])"
                    " @(p/process [\"sh\" \"-c\" \"echo $$ > \\\"$CHILD_PID_FILE\\\"; sleep 30\"]"
                    " {:extra-env {\"CHILD_PID_FILE\" \"" pidf "\"}" redirs
                    "  :shutdown p/destroy-tree})")
        parent (process [jolt-bin "-e" nested])]
    ;; the grandchild publishes its pid before it sleeps
    (loop [n 0]
      (when (and (< n 200) (str/blank? (slurp pidf)))
        (Thread/sleep 50)
        (recur (inc n))))
    (let [gpid (str/trim (slurp pidf))]
      (p/destroy parent)
      ;; poll rather than deref: a regression here is "the parent ignores
      ;; SIGTERM", and @parent would then hang the gate instead of failing it
      (loop [n 0] (when (and (< n 60) (p/alive? parent)) (Thread/sleep 50) (recur (inc n))))
      (when (p/alive? parent) (.destroyForcibly (:proc parent)) (Thread/sleep 200))
      ;; the hook's kill and the child's death are not instantaneous
      (loop [n 0] (when (and (< n 40) (pid-alive? gpid)) (Thread/sleep 50) (recur (inc n))))
      (check-eq (str "SIGTERM runs :shutdown hooks (" label ")")
                (and (seq gpid) (pid-alive? gpid)) false)
      (when (pid-alive? gpid) (sh ["sh" "-c" (str "kill -9 " gpid)])))
    (fs/delete-if-exists pidf)))

;; A jolt sitting at a stdin prompt must still take SIGTERM, hooks and all. It
;; used to wait INSIDE Chez's blocking read, which holds the whole Scheme world:
;; nothing else runs, so the watcher could not have woken there (jolt-p9ua).
;; The nested jolt registers a hook, then blocks on read-line with a pipe stdin
;; nothing ever writes to.
;;
;; Nothing here blocks without a bound: a failure has to report itself, not hang
;; the gate.
(let [readyf (str (fs/create-temp-file {:prefix "jp-stdin-" :suffix ".txt"}))
      hookf (str (fs/create-temp-file {:prefix "jp-stdin-hook-" :suffix ".txt"}))
      nested (str "(.addShutdownHook (Runtime/getRuntime)"
                  "  (Thread. (fn [] (spit \"" hookf "\" \"RAN\"))))"
                  " (spit \"" readyf "\" \"ready\") (read-line)")
      proc (process [jolt-bin "-e" nested])]
  (loop [n 0]
    (when (and (< n 200) (str/blank? (slurp readyf)))
      (Thread/sleep 50)
      (recur (inc n))))
  (p/destroy proc)
  (loop [n 0] (when (and (< n 60) (p/alive? proc)) (Thread/sleep 50) (recur (inc n))))
  (check-eq "SIGTERM reaches a jolt parked at a stdin prompt" (p/alive? proc) false)
  ;; SIGKILL, since a process that survived SIGTERM will survive another one
  (when (p/alive? proc) (.destroyForcibly (:proc proc)) (Thread/sleep 200))
  (check-eq "and its shutdown hooks run there too" (slurp hookf) "RAN")
  (fs/delete-if-exists readyf)
  (fs/delete-if-exists hookf))

;; Same root cause from the other side: while the main thread waits on stdin the
;; rest of the program has to keep running. A future stopped ticking the moment a
;; prompt was reached, which is not what a JVM does with a thread in
;; System.in.read() (jolt-p9ua).
(let [tickf (str (fs/create-temp-file {:prefix "jp-ticks-" :suffix ".txt"}))
      nested (str "(future (dotimes [i 100] (Thread/sleep 50) (spit \"" tickf "\" (str i))))"
                  " (read-line)")
      proc (process [jolt-bin "-e" nested])
      tick (fn [] (let [s (str/trim (slurp tickf))] (when-not (str/blank? s) (parse-long s))))]
  (loop [n 0] (when (and (< n 200) (nil? (tick))) (Thread/sleep 50) (recur (inc n))))
  (check-eq "a future runs while the main thread waits on stdin" (some? (tick)) true)
  ;; and keeps running, rather than getting one tick in before the read parks
  (let [before (or (tick) 0)]
    (Thread/sleep 400)
    (check-eq "and keeps running" (> (or (tick) 0) before) true))
  (.destroyForcibly (:proc proc))
  (fs/delete-if-exists tickf))

;; A child must be interruptible by ^C, on every spawn path. Chez's fork leaves
;; SIGINT set to SIG_IGN in the child — the system(3) leak the convention exists
;; to avoid, not the convention — so a child spawned the default way could not be
;; interrupted at all where the JVM's dies (jolt-a4hs). posix_spawn drives both
;; paths now, and `sh` reports 128+SIGINT when the signal lands.
(check-eq "a child dies on SIGINT (piped stdio)"
          (:exit (sh ["sh" "-c" "kill -INT $$"])) 130)
(check-eq "a child dies on SIGINT (fd-level INHERIT)"
          (:exit @(process ["sh" "-c" "kill -INT $$"] {:out :string :err :inherit})) 130)

;; jolt blocks signals in its own threads — SIGINT so ^C reaches the thread parked
;; in park-until-interrupt rather than a worker in a foreign call, SIGTERM/SIGHUP
;; so the shutdown watcher can take them — and a spawn hands the calling thread's
;; mask straight to the child. Neither may travel: a child with SIGTERM blocked
;; survives the very destroy the hook exists to call, and one with SIGINT blocked
;; ignores ^C (jolt-e5sb).
(.addShutdownHook (Runtime/getRuntime) (Thread. (fn [] nil)))
(let [proc (process ["sleep" "10"])]
  (p/destroy proc)
  (check-eq "a child spawned after a shutdown hook is still killable" (:exit @proc) 143))
(check-eq "a child does not inherit jolt's blocked SIGTERM"
          (:exit @(process ["sh" "-c" "kill -TERM $$"] {:out :string :err :inherit})) 143)
(jolt.host/block-sigint)
(check-eq "a child does not inherit jolt's blocked SIGINT"
          (:exit @(process ["sh" "-c" "kill -INT $$"] {:out :string :err :inherit})) 130)

(if (empty? @failures)
  (println "PROCESS-TEST OK")
  (do (doseq [f @failures] (println "FAIL:" f))
      (println "PROCESS-TEST FAILED:" (count @failures))))
