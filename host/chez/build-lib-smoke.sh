#!/bin/sh
# build-lib smoke: `jolt build --library` compiles an app into a shared object an
# embedder loads with dlopen and calls via jolt_library_init + jolt_lookup. This
# proves the managed-runtime library works as a C ABI target.
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

# JOLT_BIN overrides the jolt under test. The gate targets point it at the
# freshly built target/release/jolt: a `jolt build` costs ~2.5s through the
# prebuilt binary and ~12.5s through the source-mode driver, and this gate
# drives one. JOLT_BIN=bin/jolt forces script mode.
jolt="${JOLT_BIN:-bin/jolt}"
# Absolute form, for the cases that cd into a fixture directory first.
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac

app="$root/test/chez/build-lib"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --library composes with --target: the real cross build is the manual-dispatch
# cross-smoke workflow, so pin the wiring it rests on here, where no cross
# toolchain is needed. Both cases fail before any compile, so they also run on a
# machine the preflight below skips.
echo "build-lib smoke: --library composes with --target"
# 1. the CLI forwards --target through a library build (it used to reject the
#    combination outright), so the missing pack is what it complains about.
out="$( (unset JOLT_TARGET_PACK; JOLT_PWD="$app" "$jolt" build --library \
          -m libadd.core -o "$work/never" --target tarm64le) 2>&1 )"
case "$out" in
  *"needs a target pack"*) ;;
  *) echo "  FAIL: --library --target should ask for a target pack, got:"
     printf '%s\n' "$out"; exit 1 ;;
esac
# 2. target + pack reach build.ss's cross path inside a library build — the
#    "Provide a target pack" hint is emitted only when bld-cross? is true.
mkdir -p "$work/emptypack"
out="$(JOLT_PWD="$app" "$jolt" build --library -m libadd.core -o "$work/never" \
        --target tarm64le --target-pack "$work/emptypack" 2>&1 )"
case "$out" in
  *"Provide a target pack"*) ;;
  *) echo "  FAIL: --library --target-pack should reach the cross toolchain check, got:"
     printf '%s\n' "$out"; exit 1 ;;
esac

# Preflight: same as build-smoke — a library build needs Chez's kernel dev files
# (libkernel.a + scheme.h) and a C compiler. Skip cleanly where absent.
csv="$JOLT_CHEZ_CSV"
if [ -z "$csv" ]; then
  # JOLT_CHEZ wins (see host/chez/selfcheck.sh) — else this can pair a
  # PATH-resolved Chez's csv dir with a running interpreter built elsewhere.
  chez_bin="${JOLT_CHEZ:-$(command -v chez || command -v chezscheme || command -v scheme || command -v petite || true)}"
  if [ -n "$chez_bin" ]; then
    base="$(cd "$(dirname "$chez_bin")/.." 2>/dev/null && pwd)"
    for d in "$base"/lib/csv*/*/; do
      [ -f "${d}libkernel.a" ] && csv="${d%/}" && break
    done
  fi
fi
if ! command -v cc >/dev/null 2>&1 || [ -z "$csv" ] || [ ! -f "$csv/scheme.h" ] || [ ! -f "$csv/libkernel.a" ]; then
  echo "build-lib smoke: skipped (Chez kernel dev files or C compiler not available)"
  exit 0
fi
export JOLT_CHEZ_CSV="$csv"

case "$(uname -s)" in
  Darwin) lib="$work/libadd.dylib" ;;
  *)      lib="$work/libadd.so" ;;
esac

echo "build-lib smoke: compiling libadd.core -> $lib"
build_out="$(JOLT_PWD="$app" "$jolt" build --library -m libadd.core -o "$lib" 2>&1)"
if [ ! -f "$lib" ]; then
  # A shared object folds Chez's libkernel.a in, so that archive must be PIC. A
  # kernel built without -fPIC (the common default, incl. a stock source build)
  # fails the -shared link with a relocation error — an environment limitation,
  # not a jolt bug, so skip like the missing-toolchain case above.
  if printf '%s' "$build_out" | grep -qiE 'recompile with .*-fPIC|can not be used when making a shared object|relocation R_'; then
    echo "build-lib smoke: skipped (Chez libkernel.a is not position-independent; a shared library needs a PIC kernel)"
    exit 0
  fi
  echo "  FAIL: jolt build --library produced no shared library"
  printf '%s\n' "$build_out"
  exit 1
fi

echo "build-lib smoke: compiling driver + calling add(2,3) through dlopen"
if ! cc -O2 "$app/driver.c" -ldl -o "$work/driver" 2>"$work/driver.err"; then
  echo "  FAIL: driver compile failed"; cat "$work/driver.err"; exit 1
fi
got="$("$work/driver" "$lib" 2>&1)"; rc=$?
if [ "$got" != "5" ] || [ "$rc" != "0" ]; then
  echo "  FAIL: add(2,3) — want '5' rc 0, got '$got' rc $rc"; exit 1
fi

echo "build-lib smoke: passed (library built, add(2,3)=5 via dlopen+jolt_lookup)"
