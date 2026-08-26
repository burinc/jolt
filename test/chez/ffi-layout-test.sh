#!/bin/sh
# Build the struct-layout C witness outside the tree, run the compiler-level and
# public API checks, and retain the complete temporary directory on failure.
set -eu

CHEZ=${1-}
[ -n "$CHEZ" ] || { echo "usage: $0 <chez> [jolt]" >&2; exit 2; }
JOLT=${2-bin/jolt}
C=test/chez/ffi-layout-helper.c
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }
[ -x "$JOLT" ] || { echo "missing executable jolt: $JOLT" >&2; exit 2; }

OUT=$(mktemp -d) || exit 1
[ -n "$OUT" ] && [ -d "$OUT" ] || {
  echo "mktemp returned no usable ffi-layout artifact directory" >&2
  exit 1
}
case "$(uname -s)" in
  Darwin) EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *) EXT=so ;;
esac
SO=$OUT/jolt-ffi-layout-helper.$EXT
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$OUT"
  else
    echo "retained ffi-layout artifacts: $OUT" >&2
  fi
}
trap cleanup EXIT
CC_BIN=${CC:-cc}
case "$(uname -s)" in
  Darwin) "$CC_BIN" -std=c11 -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -std=c11 -shared -o "$SO" "$C" ;;
  *) "$CC_BIN" -std=c11 -shared -fPIC -o "$SO" "$C" ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }
JOLT_FFI_LAYOUT_HELPER=$SO "$CHEZ" --script test/chez/ffi-layout-test.ss
JOLT_NO_USER_DEPS=1 JOLT_FFI_LAYOUT_HELPER=$SO \
  "$JOLT" run test/chez/jolt-ffi-layout-test.clj
