#!/bin/sh
# zlib-register smoke: every kind of binary jolt produces registers the zlib it
# links under the private jolt_z_* names, none exports zlib's own names, and
# none loads a zlib or lz4 shared library at run time (the copy is static).
#
# The runtime's java.util.zip binds jolt_z_* (host/chez/java/zlib.ss). A binary
# kind that skips the registration would fall back to whatever zlib the machine
# has, and a binary is meant to run with nothing installed. Script mode has no
# jolt launcher, so it must answer false; that is the check that the probe can
# see a missing registration at all.
#
# Each build runs when its tools are there: the prebuilt stub needs none, the
# relinked stub needs a C compiler, and the C-compiler path and the library also
# need Chez's kernel dev files. A skip is an environment limit, not a pass, so
# JOLT_REQUIRE_BUILDLIB (set in CI) turns every skip into a failure, as
# build-lib-smoke.sh does. The last line names the checks that ran.
#
#   JOLT_BIN=target/release/jolt sh host/chez/zlib-register-smoke.sh
root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1

jolt="${JOLT_BIN:-bin/jolt}"
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac

probe='(some? ((requiring-resolve (quote jolt.ffi/find-symbol)) "jolt_z_inflate"))'
zlib_names='^(zlibVersion|inflateInit2_|inflate|inflateEnd|inflateReset|inflateSetDictionary|deflateInit2_|deflate|deflateEnd|deflateReset|deflateParams|deflateSetDictionary|crc32|adler32)$'

ran=""
fail() { echo "  FAIL: $*"; exit 1; }
passed() { ran="${ran:+$ran + }$1"; }
finish() { echo "zlib-register smoke: passed ($ran)"; exit 0; }

# A check the environment cannot run: fail when JOLT_REQUIRE_BUILDLIB is set.
skip_or_fail() {
  [ -n "${JOLT_REQUIRE_BUILDLIB:-}" ] && fail "$1 (JOLT_REQUIRE_BUILDLIB is set, so this environment was expected to run it)"
  echo "zlib-register smoke: skipped $1"
  passed "$2 skipped"
}

# Linux only: the dynamic symbol table must not name a zlib function. An
# exported copy answers for the zlib an FFI-loaded libpng or libssl was built
# against (CHANGELOG, "A built binary no longer exports the compression symbols
# it baked in (Linux)").
no_zlib_exports() {
  [ "$(uname -s)" = Linux ] || return 0
  command -v nm >/dev/null 2>&1 || fail "nm is not on PATH, so $2's dynamic symbols cannot be read"
  syms="$(nm -D --defined-only "$1")" || fail "nm could not read $2's dynamic symbols"
  hits="$(printf '%s\n' "$syms" | awk '{sub(/@.*/, "", $NF); print $NF}' | grep -E "$zlib_names" || true)"
  [ -z "$hits" ] || fail "$2 exports zlib symbols: $(echo "$hits" | tr '\n' ' ')"
}

# Every platform: the binary must not load a zlib or lz4 library at run time.
# The registration binds whatever `inflate` the link resolved, and a build.ss
# fallback from Chez's libz.a to -lz (macOS ships /usr/lib/libz.1.dylib) would
# register the OS's copy: java.util.zip would work on the build machine and
# depend on a library the design says every jolt binary bakes in.
no_zlib_dynamic_dep() {
  case "$(uname -s)" in
    Darwin)
      command -v otool >/dev/null 2>&1 || fail "otool is not on PATH, so $2's load commands cannot be read"
      hits="$(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -Ei 'lz4|libz\.' || true)" ;;
    Linux)
      command -v readelf >/dev/null 2>&1 || fail "readelf is not on PATH, so $2's NEEDED entries cannot be read"
      hits="$(readelf -d "$1" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | grep -Ei 'lz4|libz\.' || true)" ;;
    *) return 0 ;;
  esac
  [ -z "$hits" ] || fail "$2 loads a compression library at run time instead of its own static copy: $(echo "$hits" | tr '\n' ' ')"
}

echo "zlib-register smoke: script mode has no registration"
got="$(bin/jolt -e "$probe" 2>&1 | tail -1)"
[ "$got" = "false" ] || fail "bin/jolt -e probe — want false, got \`$got\`"
passed script-mode-false

if [ "$jolt" != "bin/jolt" ]; then
  echo "zlib-register smoke: the jolt binary"
  got="$("$jolt" -e "$probe" 2>&1 | tail -1)"
  [ "$got" = "true" ] || fail "$jolt -e probe — want true, got \`$got\`"
  no_zlib_exports "$joltabs" "the jolt binary"
  no_zlib_dynamic_dep "$joltabs" "the jolt binary"
  passed jolt-binary
else
  skip_or_fail "the jolt binary and both stubs (JOLT_BIN is bin/jolt)" "jolt-binary and stubs"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

app="$work/app"
mkdir -p "$app/src/zr"
printf '{:paths ["src"]}\n' > "$app/deps.edn"
cat > "$app/src/zr/main.clj" <<'EOF'
(ns zr.main (:require [jolt.ffi :as ffi]))
(defn -main [& _]
  (println "ZLIB-REGISTERED" (some? (ffi/find-symbol "jolt_z_inflate"))))
EOF

check_app() {  # $1 binary, $2 label
  got="$(cd / && "$1" 2>&1 | tail -1)"
  [ "$got" = "ZLIB-REGISTERED true" ] || fail "$2 — want 'ZLIB-REGISTERED true', got \`$got\`"
}

# 1. the prebuilt launcher stub (host/chez/stub/launcher.c): no C compiler, no
#    Chez install. build.ss logs "mode, self-contained)" on both stub paths and
#    "relinking launcher stub" on the relink path only.
if [ "$jolt" != "bin/jolt" ]; then
  echo "zlib-register smoke: app from the prebuilt stub"
  if ! JOLT_PWD="$app" "$jolt" build -m zr.main -o "$work/stub-app" >"$work/stub.log" 2>&1; then
    cat "$work/stub.log"; fail "jolt build (prebuilt stub) exited non-zero"
  fi
  if ! grep -q 'mode, self-contained)' "$work/stub.log" || grep -q 'relinking launcher stub' "$work/stub.log"; then
    cat "$work/stub.log"; fail "the build did not take the prebuilt stub"
  fi
  check_app "$work/stub-app" "prebuilt-stub app"
  no_zlib_exports "$work/stub-app" "the prebuilt-stub app"
  no_zlib_dynamic_dep "$work/stub-app" "the prebuilt-stub app"
  passed prebuilt-stub
fi

# 2. the relinked stub (bld-relink-stub): a :static native forces it; it needs a
#    C compiler for the archive and the link, not Chez's kernel dev files.
if [ "$jolt" != "bin/jolt" ]; then
  if ! command -v cc >/dev/null 2>&1 || ! command -v ar >/dev/null 2>&1; then
    skip_or_fail "the relinked stub (no C compiler or ar)" relinked-stub
  else
    echo "zlib-register smoke: app from the relinked stub"
    printf 'int jolt_zr_answer(void) { return 42; }\n' > "$work/zr.c"
    cc -c "$work/zr.c" -o "$work/zr.o" || fail "cc could not compile the static native"
    ar rcs "$work/libzr.a" "$work/zr.o" || fail "ar could not archive the static native"
    relink="$work/relink"
    mkdir -p "$relink/src/zr"
    cat > "$relink/deps.edn" <<EOF
{:paths ["src"]
 :jolt/native [{:name "zr" :static {:archive "$work/libzr.a"}}]}
EOF
    cat > "$relink/src/zr/main.clj" <<'EOF'
(ns zr.main (:require [jolt.ffi :as ffi]))
(ffi/defcfn answer "jolt_zr_answer" [] :int)
(defn -main [& _]
  (println "ZLIB-REGISTERED" (and (= 42 (answer)) (some? (ffi/find-symbol "jolt_z_inflate")))))
EOF
    if ! JOLT_PWD="$relink" "$jolt" build -m zr.main -o "$work/relink-app" >"$work/relink.log" 2>&1; then
      cat "$work/relink.log"; fail "jolt build (relinked stub) exited non-zero"
    fi
    grep -q 'relinking launcher stub' "$work/relink.log" || { cat "$work/relink.log"; fail "the :static build did not relink the stub"; }
    check_app "$work/relink-app" "relinked-stub app"
    no_zlib_exports "$work/relink-app" "the relinked-stub app"
    no_zlib_dynamic_dep "$work/relink-app" "the relinked-stub app"
    passed relinked-stub
  fi
fi

# Preflight for the C-compiler path and the library, as build-smoke.sh does.
csv="$JOLT_CHEZ_CSV"
if [ -z "$csv" ]; then
  chez_bin="${JOLT_CHEZ:-$(command -v chez || command -v chezscheme || command -v scheme || command -v petite || true)}"
  if [ -n "$chez_bin" ]; then
    base="$(cd "$(dirname "$chez_bin")/.." 2>/dev/null && pwd)"
    for d in "$base"/lib/csv*/*/; do
      [ -f "${d}libkernel.a" ] && csv="${d%/}" && break
    done
  fi
fi
if ! command -v cc >/dev/null 2>&1 || [ -z "$csv" ] || [ ! -f "$csv/scheme.h" ] || [ ! -f "$csv/libkernel.a" ]; then
  skip_or_fail "the C-compiler path and the library (Chez kernel dev files or C compiler not available)" "cc-path and library"
  finish
fi
export JOLT_CHEZ_CSV="$csv"

# 3. the generated main.c of build-with-cc (the checkout driver takes this path)
echo "zlib-register smoke: app from the C-compiler path"
if ! JOLT_NO_DEVCACHE=1 JOLT_PWD="$app" bin/jolt build -m zr.main -o "$work/cc-app" >"$work/cc.log" 2>&1; then
  cat "$work/cc.log"; fail "bin/jolt build (C-compiler path) exited non-zero"
fi
check_app "$work/cc-app" "C-compiler-path app"
no_zlib_exports "$work/cc-app" "the C-compiler-path app"
no_zlib_dynamic_dep "$work/cc-app" "the C-compiler-path app"
passed cc-path

# 4. the library stub (bld-library-stub)
echo "zlib-register smoke: shared library"
lib_app="$work/lib"
mkdir -p "$lib_app/src/zrlib"
printf '{:paths ["src"]}\n' > "$lib_app/deps.edn"
cat > "$lib_app/src/zrlib/core.clj" <<'EOF'
(ns zrlib.core (:require [jolt.ffi :as ffi]))
(defn registered [] (if (some? (ffi/find-symbol "jolt_z_inflate")) 1 0))
(ffi/export! "zlib_registered" registered [] :int)
EOF
case "$(uname -s)" in
  Darwin) lib="$work/libzr.dylib" ;;
  *)      lib="$work/libzr.so" ;;
esac
if ! JOLT_PWD="$lib_app" "$jolt" build --library -m zrlib.core -o "$lib" >"$work/lib.log" 2>&1; then
  if grep -qiE 'recompile with .*-fPIC|can not be used when making a shared object|relocation R_' "$work/lib.log"; then
    [ -n "${JOLT_REQUIRE_BUILDLIB:-}" ] && cat "$work/lib.log"
    skip_or_fail "the library (Chez libkernel.a is not position-independent)" library
    finish
  fi
  cat "$work/lib.log"; fail "jolt build --library exited non-zero"
fi
cat > "$work/driver.c" <<'EOF'
#include <stdio.h>
#include <dlfcn.h>
int main(int argc, char** argv) {
  void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
  int (*init)(int, char**) = (int (*)(int, char**))dlsym(h, "jolt_library_init");
  void* (*lookup)(const char*) = (void* (*)(const char*))dlsym(h, "jolt_lookup");
  if (!init || !lookup || init(0, NULL) != 0) { fprintf(stderr, "init failed\n"); return 1; }
  int (*registered)(void) = (int (*)(void))lookup("zlib_registered");
  if (!registered) { fprintf(stderr, "jolt_lookup returned NULL\n"); return 1; }
  printf("%d\n", registered());
  return 0;
}
EOF
cc -O2 "$work/driver.c" -ldl -o "$work/driver" 2>"$work/driver.err" || { cat "$work/driver.err"; fail "driver compile failed"; }
got="$("$work/driver" "$lib" 2>&1)"
[ "$got" = "1" ] || fail "library zlib_registered — want 1, got \`$got\`"
no_zlib_exports "$lib" "the shared library"
no_zlib_dynamic_dep "$lib" "the shared library"
passed library

finish
