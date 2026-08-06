#!/bin/sh
# portability-check.sh — PSL R1 portability lint gate wrapper (POSIX sh).
#
# Runs host/chez/portability-check.ss under the build's Chez. The checker scans
# every handwritten host .ss file (including itself) for blocklisted Chez-only
# identifiers; with no flag this is the lint gate (exit 1 on a hit the
# allowlist does not cover, or a STALE allowlist line). Flags pass through:
#   --regen          rewrite host/chez/portability-allowlist.txt from reality
#   --census         emit .dirge/psl-census.md (regenerated, not hand-edited)
#   --dump-operators print the full operator inventory (dev aid)
#
# Chez resolution mirrors bin/jolt: JOLT_CHEZ wins (the Makefile hands down the
# interpreter it selected — same one that mints the seed and compiles
# target/dev/flat.so), then a PATH search over the standard names.
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
    echo "portability check: no Chez Scheme executable found on PATH" >&2
    exit 1
  fi
fi

exec "$JOLT_CHEZ" --script host/chez/portability-check.ss "$@"
