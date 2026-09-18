#!/bin/sh
# regex-dfa-check.sh — vendored-copy staleness gate for regex-dfa.ss (POSIX sh).
#
# Runs host/chez/regex-dfa-check.ss under the build's Chez. With no flag this is
# the gate: exit 1 when irregex's own nfa->dfa no longer matches the pinned copy
# jolt's replacement was derived from. Flags pass through:
#   --regen   re-pin host/chez/regex-dfa-upstream.scm from the submodule
#
# Chez resolution mirrors portability-check.sh: JOLT_CHEZ wins (the Makefile
# hands down the interpreter it selected), then a PATH search.
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
    echo "regex-dfa: no Chez Scheme executable found on PATH" >&2
    exit 1
  fi
fi

exec "$JOLT_CHEZ" --script host/chez/regex-dfa-check.ss "$@"
