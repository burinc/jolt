#!/bin/sh
# aot-cache-path smoke (trace-r5): a frame from a CACHED namespace must report an
# EXISTING source path.
#
# compile-file bakes the name of the file it read into the frame source objects.
# The AOT cache used to compile a pid-unique temp (base.tmp<pid>.scm) and rename
# it away, so every frame from a cache hit pointed at a path that no longer
# exists. This check drives a throwing app twice under a fresh JOLT_CACHE_DIR —
# cold (miss) then warm (hit) — and on the WARM run asserts that the source path
# baked into the cached .so (the same string the frame source objects carry, and
# what the R3 trace will resolve offsets against) exists on disk and is the
# final .scm, not a temp.
#
# The path is observed in the fasl rather than by walking frames because nothing
# in the shipped runtime exposes it yet — jolt-frame-records reads only each
# frame's NAME today. The .so is the same bytes the frames were compiled from, so
# the paths it embeds ARE the ones the frame source objects carry.
#
# It is NOT that the continuation cannot supply it. A frame's (io 'source-object)
# and (io 'source-path) do carry the path, and with this fix in place the latter
# resolves all three values instead of two — file, line and column — precisely
# because the file now exists:
#   before:  (".../boom-74-E212836D-11.tmp12072.scm" 570)      <- missing
#   after:   (".../boom-74-E212836D-11.scm" 3 125)             <- exists
# (An inspector message returns an inspector OBJECT; reading it carelessly yields
# #f and makes it look as though Chez kept nothing.) R3 walks frames for real and
# should assert the frame-side property directly then.

set -e

pass=0
fails=0
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

jolt="bin/jolt"
cache="$(mktemp -d)"
tmp="$(mktemp -d)"
mkdir -p "$tmp/src/mylib"

cat > "$tmp/src/mylib/core.clj" <<'EOF'
(ns mylib.core)
;; throw in operand position: a tail-position throw TCO-erases boom's frame from
;; the live continuation, and this check drives the continuation path.
(defn boom [] (+ 1 (throw (ex-info "boom" {}))))
EOF

# Run the throwing app, capturing stderr (the JOLT_DEBUG_FRAMES dump and the
# trace both go to current-error-port). $1 = the cache dir.
# JOLT_TRACE=0: dev mode traces by default, and the tail-frame history ring then
# preempts jolt-frame-records (the continuation walk) — this check drives it.
run_app() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$1" JOLT_QUIET=1 JOLT_DEBUG_FRAMES=1 \
    JOLT_TRACE=0 \
    "$jolt" -e "
      (require 'jolt.deps)
      (jolt.deps/add-deps {:deps {'mylib/mylib {:local/root \"$tmp\"}}})
      (require 'mylib.core)
      (println (mylib.core/boom))" 2>&1 || true
}

# --- (a) cold run: the cache compiles, the app throws -------------------------
out_a="$(run_app "$cache")"
if printf '%s' "$out_a" | grep -q '\[frame\] mylib.core/boom \*MAPPED\*'; then
  echo "PASS: (a) cold run traces the cached frame (mapped)"; pass=$((pass+1))
else
  echo "FAIL: (a) no mapped boom frame in JOLT_DEBUG_FRAMES output"
  printf '%s\n' "$out_a" | head -20
  fails=$((fails+1))
fi

# --- (b) warm run: a cache hit ------------------------------------------------
out_b="$(run_app "$cache")"
if printf '%s' "$out_b" | grep -q '\[frame\] mylib.core/boom \*MAPPED\*'; then
  echo "PASS: (b) warm (cache-hit) run traces the cached frame (mapped)"; pass=$((pass+1))
else
  echo "FAIL: (b) no mapped boom frame on the warm run"
  printf '%s\n' "$out_b" | head -20
  fails=$((fails+1))
fi

# --- (c) every source path baked into the cached .so exists and is final -------
so="$(find "$cache" -name '*.so' 2>/dev/null | head -1)"
if [ -z "$so" ]; then
  echo "FAIL: (c) no .so under the cache dir — nothing was cached"
  fails=$((fails+1))
else
  echo "PASS: (c) cache holds a .so: $so"; pass=$((pass+1))
  # `strings` is binutils and is not everywhere; fall back to a binary-safe grep
  # so a host without it reports the real result instead of a spurious failure.
  if command -v strings >/dev/null 2>&1; then
    paths="$(strings "$so" 2>/dev/null | grep -o '[^[:space:]]*\.scm' | sort -u)"
  else
    paths="$(LC_ALL=C grep -a -o '[^[:space:]]*\.scm' "$so" 2>/dev/null | sort -u)"
  fi
  if [ -z "$paths" ]; then
    echo "FAIL: (c2) no .scm path embedded in the cached .so"
    fails=$((fails+1))
  else
    echo "PASS: (c2) cached .so embeds $(printf '%s\n' "$paths" | wc -l | tr -d ' ') source path(s)"
    pass=$((pass+1))
  fi
  for p in $paths; do
    if [ -f "$p" ]; then
      echo "PASS: (c3) recorded path exists: $p"; pass=$((pass+1))
    else
      echo "FAIL: (c3) recorded path does not exist: $p"; fails=$((fails+1))
    fi
    case "$p" in
      *".tmp"*) echo "FAIL: (c4) recorded path is a temp: $p"; fails=$((fails+1)) ;;
      *) echo "PASS: (c4) recorded path is the final .scm: $p"; pass=$((pass+1)) ;;
    esac
  done
fi

echo
echo "aot-cache-path smoke: $pass passed, $fails failed"
rm -rf "$cache" "$tmp"
[ "$fails" -eq 0 ]
