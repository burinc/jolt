#!/bin/sh
# ffi-native-error-test.sh — compiles the native-error C helper and runs the
# jolt.ffi atomic native-error capture gate. Invoke from the repo root, like
# every other gate:
#   sh test/chez/ffi-native-error-test.sh "$(CHEZ)"
# The helper shared object is built in a temp dir (no tree pollution) and
# passed to the .ss runner via JOLT_FFI_NATIVE_ERROR_HELPER.
#
# Mirrors test/chez/ffi-widths-test.sh one-for-one (same platform dispatch,
# temp dir, trap, CC override) so the two FFI helper gates stay uniform.
set -u

CHEZ=${1-}
[ -n "$CHEZ" ] || { echo "usage: $0 <chez>" >&2; exit 2; }
C=test/chez/ffi-native-error-test.c
[ -f "$C" ] || { echo "missing $C (run from repo root)" >&2; exit 2; }

SO_DIR=$(mktemp -d) || {
  echo "failed to create ffi-native-error artifact directory" >&2
  exit 1
}
[ -n "$SO_DIR" ] && [ -d "$SO_DIR" ] || {
  echo "mktemp returned no usable ffi-native-error artifact directory" >&2
  exit 1
}
case "$(uname -s)" in
  Darwin)              EXT=dylib ;;
  MINGW*|MSYS*|CYGWIN*) EXT=dll ;;
  *)                   EXT=so ;;
esac
SO="$SO_DIR/jolt-ffi-native-error-helper.$EXT"
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -f "$SO"
    rmdir "$SO_DIR"
  else
    echo "retained ffi-native-error artifacts: $SO_DIR" >&2
  fi
}
trap cleanup EXIT
CC_BIN="${CC:-cc}"

case "$(uname -s)" in
  Darwin)               "$CC_BIN" -dynamiclib -o "$SO" "$C" ;;
  MINGW*|MSYS*|CYGWIN*) "$CC_BIN" -shared -o "$SO" "$C" ;;
  *)                    "$CC_BIN" -shared -fPIC -o "$SO" "$C" ;;
esac || { echo "cc failed to build $C" >&2; exit 1; }

JOLT_FFI_NATIVE_ERROR_HELPER="$SO" \
  "$CHEZ" --script test/chez/ffi-native-error-test.ss
