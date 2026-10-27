#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
jolt="${JOLT_BIN:-target/release/jolt}"
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac
app="$root/test/chez/embedded-migratus-upstream"
out="$(mktemp -d)/app-bin"
trap 'rm -rf "$(dirname "$out")"' EXIT HUP INT TERM
JOLT_PWD="$app" "$joltabs" build -m check.core -o "$out" >/dev/null 2>&1
got="$(cd / && "$out")"
if [ "$got" != ':upstream-migratus-ok' ]; then
  echo "upstream Migratus discovery failed: $got" >&2
  exit 1
fi
printf 'upstream Migratus 1.6.8 discovery passed\n'
