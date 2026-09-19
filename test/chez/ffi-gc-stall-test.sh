#!/bin/sh
# ffi-gc-stall-test.sh — the issue #1046 gate: a collection stalled by a thread
# parked in a foreign call that is not :blocking is reported on stderr after
# two seconds, once per stalled request, naming a :collect-safe callback when
# one is in progress. Invoke from the repo root, like every other gate:
#   sh test/chez/ffi-gc-stall-test.sh
#
# test/chez/ffi-gc-stall-test.clj runs four rows in one process (an unmarked
# sleep, the same sleep :blocking, the #973 round trip against the pthread
# helper with a deadline the report beats, and that round trip with the
# collect request already pending when the callback's thread starts); this
# script builds the helper in a temp dir, runs the rows, and reads the
# process's stderr: exactly three reports, the first without a callback, the
# other two naming one. The rows take ~14 s; the two-second threshold is the
# runtime's (rt.ss jolt-gc-stall-seconds).
#
# POSIX only: the helper is pthreads + condvars. Skipped, loudly, elsewhere.
set -eu

C=test/chez/ffi-foreign-thread-helper.c
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "ffi-gc-stall: skipped (POSIX threads helper)"
    exit 0 ;;
  Darwin) EXT=dylib ;;
  *)      EXT=so ;;
esac

WORK=$(mktemp -d) || { echo "failed to create ffi-gc-stall work directory" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || {
  echo "mktemp returned no usable ffi-gc-stall work directory" >&2
  exit 1
}
SO="$WORK/jolt-ffi-foreign-thread-helper.$EXT"
ERR="$WORK/stderr.txt"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO" "$ERR"
    rmdir "$WORK"
  else
    echo "retained ffi-gc-stall artifacts: $WORK" >&2
  fi
}
trap cleanup EXIT
CC_BIN="${CC:-cc}"

case "$(uname -s)" in
  Darwin) "$CC_BIN" -dynamiclib -o "$SO" "$C" -lpthread ;;
  *)      "$CC_BIN" -shared -fPIC -o "$SO" "$C" -lpthread ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

# The rows' own checks decide the exit status; the reports are read afterwards.
JOLT_FFI_FOREIGN_THREAD_HELPER="$SO" \
  bin/jolt run test/chez/ffi-gc-stall-test.clj 2>"$ERR"

PREFIX='jolt.ffi: a garbage collection has been waiting 2 s for 1 thread to reach a safe point'
CALLBACK='1 :collect-safe callback is in progress'
count=$(grep -c "$PREFIX" "$ERR" || true)
if [ "$count" != 3 ]; then
  echo "FAIL: expected exactly 3 stall reports (rows 1, 3 and 4), got $count" >&2
  echo "--- stderr ---" >&2; cat "$ERR" >&2
  exit 1
fi
first=$(grep -n "$PREFIX" "$ERR" | sed -n 1p | cut -d: -f1)
second=$(grep -n "$PREFIX" "$ERR" | sed -n 2p | cut -d: -f1)
third=$(grep -n "$PREFIX" "$ERR" | sed -n 3p | cut -d: -f1)
# Each report is one paragraph; the callback clause, when present, sits inside it.
if sed -n "${first},$((second - 1))p" "$ERR" | grep -q "$CALLBACK"; then
  echo "FAIL: row 1's report names a :collect-safe callback, and none was in progress" >&2
  echo "--- stderr ---" >&2; cat "$ERR" >&2
  exit 1
fi
if ! sed -n "${second},$((third - 1))p" "$ERR" | grep -q "$CALLBACK"; then
  echo "FAIL: row 3's report does not name the :collect-safe callback in progress" >&2
  echo "--- stderr ---" >&2; cat "$ERR" >&2
  exit 1
fi
if ! sed -n "${third},\$p" "$ERR" | grep -q "$CALLBACK"; then
  echo "FAIL: row 4's report does not name the callback whose thread trapped before counting itself in" >&2
  echo "--- stderr ---" >&2; cat "$ERR" >&2
  exit 1
fi
if grep -q 'is not marked :blocking' "$ERR" && grep -q 'foreign-callable' "$ERR"; then :; else
  echo "FAIL: the report does not point at :blocking and the :collect-safe notes" >&2
  echo "--- stderr ---" >&2; cat "$ERR" >&2
  exit 1
fi
echo "FFI-GC-STALL-TEST: 3 reports, callback named in rows 3 and 4 only"
