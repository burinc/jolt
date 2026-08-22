#!/bin/sh
# Build the exact-width C witness outside the tree, run it, and retain the
# complete temporary directory on failure for diagnosis.
set -u

CHEZ=${1-}
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }
C=test/chez/ffi-widths-helper.c
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

OUT=$(mktemp -d) || {
  echo "failed to create ffi-widths artifact directory" >&2
  exit 1
}
[ -n "$OUT" ] && [ -d "$OUT" ] || {
  echo "mktemp returned no usable ffi-widths artifact directory" >&2
  exit 1
}
case "$(uname -s)" in
  Darwin) EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *) EXT=so ;;
esac
SO=$OUT/jolt-ffi-widths-helper.$EXT
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$OUT"
  else
    echo "retained ffi-widths artifacts: $OUT" >&2
  fi
}
trap cleanup EXIT
CC_BIN=${CC:-cc}

case "$(uname -s)" in
  Darwin) "$CC_BIN" -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -shared -o "$SO" "$C" ;;
  *) "$CC_BIN" -shared -fPIC -o "$SO" "$C" ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

JOLT_FFI_WIDTHS_HELPER=$SO "$CHEZ" --script test/chez/ffi-widths-test.ss
