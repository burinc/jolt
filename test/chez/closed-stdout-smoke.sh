#!/bin/sh
# Writing to a process stream whose reader has gone away (`jolt app | head -1`,
# a parent that closed the pipe) does not stop the program. On the JVM,
# System.out and System.err are PrintStreams, which never throw: a failed write
# sets the flag checkError() answers and the program carries on. jolt raised
# IOException("broken pipe") from the next print instead, so a backgrounded
# `jolt build` whose parent stopped reading died partway through (#1331).
#
# Runs the CLI through the given chez (default `chez`), so the windows-deps job
# runs it as well.
#
#   sh test/chez/closed-stdout-smoke.sh [chez]
set -u

chez="${1:-chez}"
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

jolt() { "$chez" --script host/chez/cli.ss -e "$1"; }

fails=0
expect() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"; echo "  got:  $(printf '%s' "$2" | tr '\n' '|')"; echo "  want: $(printf '%s' "$3" | tr '\n' '|')"
    fails=$((fails+1))
  fi
}

# the marker file says how far the program got, whatever happened to its output.
# jolt writes it, so under MSYS it needs the Windows spelling of the directory:
# a native program reads /tmp/x as \tmp\x on the current drive.
if command -v cygpath >/dev/null 2>&1; then jdir="$(cygpath -m "$dir")"; else jdir="$dir"; fi
marker="$dir/marker"
m() { printf '%s' "$jdir/marker"; }

# --- stdout: the reader leaves after the first line ---------------------------
rm -f "$marker"
first="$(jolt "(dotimes [i 6] (println (str \"line \" i (apply str (repeat 2000 \\x)))) (Thread/sleep 200))
(.println System/out \"after\")
(.write System/out (.getBytes \"raw\"))
(flush)
(spit \"$(m)\" (pr-str [:end (.checkError System/out)]))" | head -1 | cut -c1-6)"
expect "the reader got the first line" "$first" "line 0"
expect "the program ran to its end, and checkError says the stream failed" "$(cat "$marker" 2>/dev/null)" "[:end true]"

# --- stderr: the same, through *err* and System/err ---------------------------
rm -f "$marker"
first="$(jolt "(dotimes [i 6] (binding [*out* *err*] (println (str \"err \" i (apply str (repeat 2000 \\y))))) (Thread/sleep 200))
(.println System/err \"after\")
(spit \"$(m)\" (pr-str [:end (.checkError System/err)]))" 2>&1 >/dev/null | head -1 | cut -c1-5)"
expect "the stderr reader got the first line" "$first" "err 0"
expect "the program ran to its end after stderr closed" "$(cat "$marker" 2>/dev/null)" "[:end true]"

# --- a stream that never failed reports so -----------------------------------
expect "checkError is false on a healthy stream" \
  "$(jolt '(println "x") (println (.checkError System/out))' | tail -1 | tr -d '\r')" "false"

# --- a line reaches the reader when it is written, not at exit ----------------
# The program prints a line and then waits for the reader to say it has it: the
# reader makes a file once it reads the first line, and the program prints
# "late" when it sees that file, or "held" if 20 s pass without it. Held back
# until exit, the first line cannot reach the reader while the program waits, so
# the program gives up and says so. Nothing here reads a clock, so a slow start
# or a busy machine moves nothing that is asserted; the 20 s only bounds the
# failing case.
rm -f "$dir/ack"
jolt '(println "early")
(let [ack (java.io.File. "'"$jdir/ack"'") give-up (+ (System/nanoTime) 20000000000)]
  (loop [] (cond (.exists ack) (println "late")
                 (> (System/nanoTime) give-up) (println "held")
                 :else (do (Thread/sleep 10) (recur)))))' | {
  IFS= read -r line; : > "$dir/ack"; IFS= read -r second; cat >/dev/null
  printf '%s\n%s\n' "$line" "$second" > "$dir/took"; }
expect "the first line is the first println" "$(sed -n 1p "$dir/took" | tr -d '\r')" "early"
expect "the first line arrives while the program is still running" "$(sed -n 2p "$dir/took" | tr -d '\r')" "late"

# --- stdout and stderr into one file keep their order ------------------------
jolt '(println "o1") (binding [*out* *err*] (println "e1")) (println "o2") (.println System/err "e2") (println "o3")' >"$dir/both.txt" 2>&1
expect "2>&1 into one file keeps the order" "$(tr -d '\r' < "$dir/both.txt")" "$(printf 'o1\ne1\no2\ne2\no3')"

# --- print and flush with no newline still reach a file ----------------------
jolt '(print "no-newline") (flush) (Thread/sleep 100) (spit "'"$(m)"'" (slurp "'"$jdir/flush.txt"'"))' >"$dir/flush.txt"
expect "flush delivers a partial line" "$(cat "$marker")" "no-newline"

[ "$fails" -eq 0 ] && echo "closed-stdout smoke: ok"
[ "$fails" -eq 0 ]
