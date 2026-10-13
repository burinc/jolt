#!/bin/sh
# Standard error is its own descriptor: output to System/err, *err* and the
# runtime's own reports lands on fd 2 even when fd 1 and fd 2 are both files.
#
# Chez decides at startup whether stderr can share stdout's port, by asking
# same_devicep(1, 2). Its Windows branch compared the file behind fd 1 with
# itself (GetFileInformationByHandle(h1, &info2)), so any two disk files were
# "the same", and every stderr write went to stdout: a redirected 2> file stayed
# empty, and a TUI drew the GC stall report into its own frame (#1331). jolt's
# Chez patch 0005 fixes the comparison; this runs the CLI with the two streams
# in two files and checks each holds only its own lines. POSIX answered
# correctly already, so the row exists for the windows-deps job.
#
#   sh test/chez/stderr-split-smoke.sh [chez]
set -u

chez="${1:-chez}"
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

"$chez" --script host/chez/cli.ss -e '(.println System/err "err-stream")
(binding [*out* *err*] (println "err-binding"))
(.start (Thread. (fn [] (.println System/err "err-thread"))))
(Thread/sleep 200)
(println "out-line")' 1>"$dir/out.txt" 2>"$dir/err.txt"

fails=0
expect() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"; echo "  got:  $(printf '%s' "$2" | tr '\n' '|')"; echo "  want: $(printf '%s' "$3" | tr '\n' '|')"
    fails=$((fails+1))
  fi
}
# CRLF on Windows: compare lines, not bytes
out="$(tr -d '\r' < "$dir/out.txt")"
err="$(tr -d '\r' < "$dir/err.txt" | sort)"
expect "stdout holds only stdout" "$out" "out-line"
expect "stderr holds System/err, *err* and a thread's System/err" "$err" "$(printf 'err-binding\nerr-stream\nerr-thread')"

[ "$fails" -eq 0 ] && echo "stderr-split smoke: ok"
[ "$fails" -eq 0 ]
