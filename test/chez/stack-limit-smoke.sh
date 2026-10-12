#!/bin/sh
# stack-limit-smoke.sh — JOLT_STACK_LIMIT and the default it overrides, through a
# built jolt (test/stack_limit_test.clj has the per-mode programs). The limit is
# read once at startup, so every setting is its own process.
#
#   sh test/chez/stack-limit-smoke.sh [jolt-binary]
set -u
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
J="${1:-target/release/jolt}"
T=test/stack_limit_test.clj
CAP=120
pass=0; fail=0

# run MODE [VAR=VALUE...] -> out, rc (142 = killed at CAP seconds)
run() {
  mode="$1"; shift
  out=$(env JOLT_NO_USER_DEPS=1 "$@" perl -e 'alarm shift; exec @ARGV' "$CAP" "$J" run "$T" "$mode" < /dev/null 2>&1)
  rc=$?
}
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL stacklimit: $1 — rc=$rc out=[$out]"; }
# expect LABEL WANT-LINE-REGEX MODE [VAR=VALUE...]
expect() {
  label="$1"; want="$2"; shift 2
  run "$@"
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -Eq -- "$want"; then ok; else bad "$label"; fi
}

# 1. Runaway recursion under a small limit: the Error, its catch semantics, the
#    trace, a future, and ten in a row with every throwable kept under a heap
#    ceiling only an unwound stack fits in.
expect "runaway under 64m" '^runaway ok$' runaway JOLT_STACK_LIMIT=64m JOLT_MAX_HEAP=384m
printf '%s\n' "$out" | grep '^elapsed-ms' | sed 's/^/stacklimit: runaway x12 under 64m: /'

# 2. Legitimate depth under the default.
expect "1M frames under the default" '^1000000$' deep

# 3. -1 disables; the same recursion that overflows a small limit completes.
expect "-1 reads back as no limit" '^nil$' limit JOLT_STACK_LIMIT=-1
expect "-1: 10M frames complete" '^10000000$' bounded JOLT_STACK_LIMIT=-1
expect "16m: 10M frames overflow" '^:stack-overflow$' bounded JOLT_STACK_LIMIT=16m

# 4. Spellings: k/m/g in either case, plain bytes.
expect "512k" '^524288$' limit JOLT_STACK_LIMIT=512k
expect "64M" '^67108864$' limit JOLT_STACK_LIMIT=64M
expect "2g" '^2147483648$' limit JOLT_STACK_LIMIT=2g
expect "1048576" '^1048576$' limit JOLT_STACK_LIMIT=1048576

# 5. A bad value is refused by name at startup, the way JOLT_MAX_HEAP's are.
for v in abc 0 -2 1.5g 12x; do
  run limit JOLT_STACK_LIMIT="$v"
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "JOLT_STACK_LIMIT=$v is not valid"; then ok; else bad "invalid $v refused"; fi
done

# 6. The default is 80% of the memory limit. Unset everywhere: physical RAM.
#    Under `ulimit -v` (Linux; macOS refuses to set RLIMIT_AS): that limit.
run limit
def=$(printf '%s\n' "$out" | head -1)
case "$(uname -s)" in
  Darwin) phys=$(sysctl -n hw.memsize) ;;
  *) phys=$(( $(getconf _PHYS_PAGES) * $(getconf PAGE_SIZE) )) ;;
esac
if [ "$(ulimit -v)" != unlimited ] || [ "$(ulimit -d)" != unlimited ]; then
  echo "stacklimit: physical-RAM default skipped (this shell has a memory rlimit)"
elif [ "$rc" = 0 ] && [ "$def" = "$((phys * 4 / 5))" ]; then ok; else bad "default is 80% of physical RAM ($phys)"; fi
if [ "$(uname -s)" = Linux ] && (ulimit -v 16777216) 2>/dev/null; then
  out=$(ulimit -v 16777216; env JOLT_NO_USER_DEPS=1 "$J" run "$T" limit 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = "$((16777216 * 1024 * 4 / 5))" ]; then ok; else bad "default under ulimit -v 16G is 80% of RLIMIT_AS"; fi
else
  echo "stacklimit: RLIMIT_AS case skipped (cannot set ulimit -v here; the precedence is pinned in stack-limit-test.ss)"
fi

echo "stacklimit: $pass passed, $fail failed"
[ "$fail" = 0 ]
