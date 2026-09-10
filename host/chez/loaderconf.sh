#!/bin/sh
# loaderconf.sh — the loader conformance gate.
#
# Runs test/chez/loaderconf-test.clj — the twelve cases that specify jolt.loader
# — and compares the per-case verdicts against
# test/chez/loaderconf-known-failures.txt. The baseline is exact, the way
# certify's and cts's are: a case that regresses fails the gate, and a case that
# starts passing ALSO fails it until the baseline is updated in the same change.
# Without the second rule a case that went green could go red again unnoticed.
#
# JOLT_LOADERCONF_WRITE_BASELINE=1 regenerates the baseline from the current run.
# JOLT_BIN names the jolt to run the suite through; `make loaderconf` points it
# at the built binary, and the bin/jolt default is for running this by hand.
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
jolt="${JOLT_BIN:-bin/jolt}"
suite=test/chez/loaderconf-test.clj
baseline=test/chez/loaderconf-known-failures.txt
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

"$jolt" run "$suite" > "$tmp/out" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  echo "FAIL: the loader conformance suite exited $status"
  tail -30 "$tmp/out" | sed 's/^/    /'
  exit 1
fi

# The verdict line is the proof the runner reached the end. Without it a suite
# that died mid-way would present as "no failing cases".
if ! grep -q '^LOADERCONF ' "$tmp/out"; then
  echo "FAIL: the suite printed no verdict line — it did not run to the end"
  tail -30 "$tmp/out" | sed 's/^/    /'
  exit 1
fi

grep -E '^CASE [0-9][0-9]* (PASS|FAIL)  ' "$tmp/out" > "$tmp/lines"
expected=$(grep -c '^(defcase ' "$suite")
got=$(wc -l < "$tmp/lines" | tr -d ' ')
if [ "$got" != "$expected" ]; then
  echo "FAIL: $expected cases are defined but $got reported a verdict"
  exit 1
fi

# case number -> verdict; the title travels with the number so the baseline
# stays readable when a case is renamed.
awk '{ n=$2; v=$3; $1=""; $2=""; $3=""; sub(/^ +/,""); print n"\t"v"\t"$0 }' "$tmp/lines" > "$tmp/verdicts"

if [ "${JOLT_LOADERCONF_WRITE_BASELINE:-}" = "1" ]; then
  {
    echo "# Loader conformance cases that do not pass yet, by case number."
    echo "# Regenerate: JOLT_LOADERCONF_WRITE_BASELINE=1 make loaderconf"
    echo "#"
    echo "# A case leaves this file in the same change that makes it pass."
    awk -F'\t' '$2 == "FAIL" { print $1"\t"$3 }' "$tmp/verdicts"
  } > "$baseline"
  echo "wrote $baseline ($(awk -F'\t' '$2 == "FAIL"' "$tmp/verdicts" | wc -l | tr -d ' ') failing)"
  exit 0
fi

awk -F'\t' '$2 == "FAIL" { print $1 }' "$tmp/verdicts" | sort > "$tmp/red"
grep -vE '^[[:space:]]*(#|$)' "$baseline" | awk -F'\t' '{ print $1 }' | sort > "$tmp/base"

fail=0
regressed=$(comm -23 "$tmp/red" "$tmp/base")
if [ -n "$regressed" ]; then
  echo "FAIL: loader conformance case(s) regressed — passing before, failing now:"
  for n in $regressed; do
    awk -F'\t' -v n="$n" '$1 == n { print "    case "$1": "$3 }' "$tmp/verdicts"
    sed -n "/^CASE $n /,/^CASE /p" "$tmp/out" | grep -E '^    ' | sed 's/^/    /'
  done
  fail=1
fi

stale=$(comm -13 "$tmp/red" "$tmp/base")
if [ -n "$stale" ]; then
  echo "FAIL: loader conformance case(s) now PASS but are still in $baseline:"
  for n in $stale; do
    awk -F'\t' -v n="$n" '$1 == n { print "    case "$1": "$3 }' "$tmp/verdicts"
  done
  echo "    Drop them from the baseline in the change that made them pass."
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  passing=$(awk -F'\t' '$2 == "PASS"' "$tmp/verdicts" | wc -l | tr -d ' ')
  echo "loaderconf: $passing/$expected passing, $(wc -l < "$tmp/base" | tr -d ' ') baselined"
fi
exit "$fail"
