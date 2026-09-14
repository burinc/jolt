#!/bin/sh
# ffi-foreign-thread-test.sh — the issue #973 gate: a :collect-safe callback
# arriving on a native library's own thread while the caller is parked in an
# outbound call to that library. Invoke from the repo root, like every other
# gate:
#   sh test/chez/ffi-foreign-thread-test.sh
#
# Two halves. The round-trip half runs test/chez/ffi-foreign-thread-test.clj
# against the C helper (built in a temp dir, no tree pollution, passed in
# JOLT_FFI_FOREIGN_THREAD_HELPER) and is what pins the runtime behaviour. The
# diagnosis half is two one-liners: the two signatures Chez refuses under the
# collect-safe convention, each of which jolt must reject in its own words —
# Chez's arrive from inside the macro, name neither option, and are what the
# next person reaches after taking the round trip's advice.
#
# POSIX only: the helper is pthreads + condvars. Skipped, loudly, elsewhere.
set -eu

C=test/chez/ffi-foreign-thread-helper.c
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "ffi-foreign-thread: skipped (POSIX threads helper)"
    exit 0 ;;
  Darwin) EXT=dylib ;;
  *)      EXT=so ;;
esac

SO_DIR=$(mktemp -d) || {
  echo "failed to create ffi-foreign-thread artifact directory" >&2
  exit 1
}
[ -n "$SO_DIR" ] && [ -d "$SO_DIR" ] || {
  echo "mktemp returned no usable ffi-foreign-thread artifact directory" >&2
  exit 1
}
SO="$SO_DIR/jolt-ffi-foreign-thread-helper.$EXT"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$SO_DIR"
  else
    echo "retained ffi-foreign-thread artifacts: $SO_DIR" >&2
  fi
}
trap cleanup EXIT
CC_BIN="${CC:-cc}"

case "$(uname -s)" in
  Darwin) "$CC_BIN" -dynamiclib -o "$SO" "$C" -lpthread ;;
  *)      "$CC_BIN" -shared -fPIC -o "$SO" "$C" -lpthread ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

JOLT_FFI_FOREIGN_THREAD_HELPER="$SO" \
  bin/jolt run test/chez/ffi-foreign-thread-test.clj

# The two signatures the collect-safe convention cannot carry. Chez refuses both
# by itself; what is gated here is that jolt refuses them FIRST, naming the
# option and the position, so "mark the call :blocking" does not dead-end in an
# expander trace.
expect_rejection() {
  label=$1
  needle=$2
  form=$3
  out=$(bin/jolt -e "$form" 2>&1 || true)
  case "$out" in
    *"$needle"*) ;;
    *) echo "FAIL: $label"
       echo "  wanted a message containing: $needle"
       echo "  got: $out"
       exit 1 ;;
  esac
}

expect_rejection ":blocking rejects a :string argument in jolt's own words" \
  ":blocking cannot combine with a :string argument" \
  '(require (quote [jolt.ffi :as ffi])) (ffi/defcfn f "strlen" [:string] :size_t :blocking)'

expect_rejection ":collect-safe rejects a :string return in jolt's own words" \
  "a :collect-safe callback cannot return :string" \
  '(require (quote [jolt.ffi :as ffi])) (ffi/foreign-callable (fn [] "x") [] :string :collect-safe)'

echo "ffi-foreign-thread: OK"
