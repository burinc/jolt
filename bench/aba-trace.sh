#!/bin/sh
# A/B/A for DEV-MODE tracing overhead.
#
# bench/aba.sh cannot measure anything tracing-related: it compiles each benchmark
# with `jolt build`, and a built binary's prologues are baked with tracing OFF, so
# both columns run identical code. The tail-frame history only exists on the
# `jolt run` path, where tracing is on by default — so that is what this times.
#
# Takes two already-built jolt binaries rather than swapping source files, because
# a compiler change needs `make remint` to take effect and reminting between every
# phase would dominate the wall clock. Build them once each:
#
#   git stash && make remint && make testbin && cp target/release/jolt /tmp/jolt-A
#   git stash pop && make remint && make testbin && cp target/release/jolt /tmp/jolt-B
#   bench/aba-trace.sh /tmp/jolt-A /tmp/jolt-B
#
# Order A1 -> B -> A2 so drift between the A columns tells you how much of any
# A-vs-B gap is real. Reports both A columns; do not average them away.
set -e
cd "$(dirname "$0")/.."
benchdir="$PWD/bench"

A="${1:?usage: aba-trace.sh JOLT_A JOLT_B [runs]}"
B="${2:?usage: aba-trace.sh JOLT_A JOLT_B [runs]}"
RUNS="${3:-5}"
# Call-heavy by construction: tracing costs a ring push per fn entry, so the
# workloads that show it are the ones that are almost entirely user-level calls.
BENCHES="${BENCHES:-fib:25 tak:18 binary-trees:12}"

time_one () { # $1 = jolt binary, $2 = ns:arg
  spec="$2"; ns="${spec%%:*}"; arg="${spec##*:}"
  sum=0; n=0; i=0
  while [ $i -lt "$RUNS" ]; do
    m=$( cd "$benchdir" && JOLT_PWD="$PWD" JOLT_NO_USER_DEPS=1 \
           "$1" run -m "$ns" "$arg" 2>/dev/null | awk '/^mean:/{print $2}' )
    [ -n "$m" ] && { sum=$(awk "BEGIN{print $sum+$m}"); n=$((n+1)); }
    i=$((i+1))
  done
  if [ "$n" -gt 0 ]; then awk "BEGIN{printf \"%.1f\", $sum/$n}"; else echo RUN_FAIL; fi
}

phase () { # $1 = label, $2 = binary
  echo; echo "=== $1 ($2) ==="
  for s in $BENCHES; do printf "%-16s %s ms\n" "${s%%:*}" "$(time_one "$2" "$s")"; done
}

echo "dev-mode (jolt run -m) A/B/A, $RUNS runs each"
echo "A = $A"
echo "B = $B"
phase A1 "$A"
phase B  "$B"
phase A2 "$A"
