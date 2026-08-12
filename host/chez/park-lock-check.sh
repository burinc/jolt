#!/bin/sh
# park-lock-check.sh — wrapper for the park/lock discipline gate (POSIX sh).
#
# Runs host/chez/park-lock-check.ss under the build's Chez. The checker reads every
# handwritten host .ss file as data, closes "can park" over the call graph from the
# two switch points, and fails on a call to anything in that closure from inside a
# jolt-with-mutex region — the shape that wedged a process three times (jolt-3a87,
# jolt-dfuo, jolt-04ee). It also fails if a switch point stops calling
# jolt-locks-assert-none!, which is the runtime half of the same rule.
#
#   --regen   rewrite host/chez/park-lock-allowlist.txt from reality
#
# Chez resolution mirrors host/chez/portability-check.sh: JOLT_CHEZ wins (the
# Makefile hands down the interpreter it selected), then a PATH search.
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1

if [ -z "${JOLT_CHEZ:-}" ]; then
  for c in chez chezscheme; do
    if command -v "$c" >/dev/null 2>&1; then
      JOLT_CHEZ="$c"
      break
    fi
  done
  if [ -z "${JOLT_CHEZ:-}" ]; then
    echo "park/lock check: no Chez Scheme executable found on PATH" >&2
    exit 1
  fi
fi

exec "$JOLT_CHEZ" --script host/chez/park-lock-check.ss "$@"
