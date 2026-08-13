#!/bin/sh
# stdlib-fasl smoke (R1): the embedded per-namespace stdlib fasls actually take.
#
# A built jolt compiles each install-owned stdlib namespace to a fasl at build
# time, concatenates them into one C-array blob (jolt_stdlib_fasls, xxd'd into
# the binary), and records an index the launcher hands to
# jolt-stdlib-fasls-attach!. A require then loads the compiled code via
# load-compiled-from-port instead of recompiling from source.
#
# Four non-vacuous checks, all against target/release/jolt:
#   (a) JOLT_TRACE_LOAD=1 on (require 'clojure.test) emits ZERO [load-form]
#       lines — nothing was read+compiled from source.
#   (b) JOLT_DEBUG=1 on (require 'clojure.test) prints the "[jolt.aot] embedded
#       clojure.test" line — the fasl path actually fired (not just that nothing
#       loaded from source).
#   (c) a real deftest runs and reports its pass summary through the binary.
#   (d) jolt.time.temporal + jolt.time.local replay their __register-* seams from
#       the fasl: a LocalDate equality/compare/str expression gives the expected
#       output.
#   (e) the manifest lists clojure.test (cheap grep — guards a pin that would
#       otherwise silently drop it).

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

jolt="target/release/jolt"
fails=0
pass=0

if [ ! -x "$jolt" ]; then
  echo "FAIL: $jolt not built — run 'make jolt-release' first" >&2
  exit 1
fi

# (a) zero [load-form] lines for clojure.test
n="$(JOLT_TRACE_LOAD=1 "$jolt" -e "(require 'clojure.test)" 2>&1 | grep -c '\[load-form\]' || true)"
if [ "$n" = "0" ]; then
  echo "PASS: (a) clojure.test loads with zero [load-form] lines"; pass=$((pass+1))
else
  echo "FAIL: (a) clojure.test produced $n [load-form] line(s) — not fully embedded"; fails=$((fails+1))
fi

# (b) the embedded-fasl aot-info line fires
if JOLT_DEBUG=1 "$jolt" -e "(require 'clojure.test)" 2>&1 | grep -q '\[jolt.aot\] embedded clojure.test'; then
  echo "PASS: (b) JOLT_DEBUG prints the embedded clojure.test aot-info line"; pass=$((pass+1))
else
  echo "FAIL: (b) no embedded clojure.test aot-info line — fasl path did not fire"; fails=$((fails+1))
fi

# (c) a real deftest runs and reports its pass summary
out_c="$("$jolt" -e '
(require (quote clojure.test))
(clojure.test/deftest t (clojure.test/is (= 1 1)) (clojure.test/is (= (+ 1 1) 2)))
(let [r (clojure.test/run-tests)]
  (println "SMOKE_SUMMARY test=" (:test r) "pass=" (:pass r) "fail=" (:fail r) "error=" (:error r)))' 2>&1)"
if printf '%s' "$out_c" | grep -q 'SMOKE_SUMMARY test= 1 pass= 2 fail= 0 error= 0'; then
  echo "PASS: (c) deftest runs and reports pass summary"; pass=$((pass+1))
else
  echo "FAIL: (c) deftest summary missing/wrong"
  printf '%s\n' "$out_c" | tail -5
  fails=$((fails+1))
fi

# (d) jolt.time.temporal + jolt.time.local replay their __register-* seams from
# the fasl: LocalDate equality, compare, and str.
out_d="$("$jolt" -e '
(require (quote jolt.time.temporal))
(require (quote jolt.time.local))
(let [a (jolt.time.local/local-date 0)
      b (jolt.time.local/local-date 0)
      c (jolt.time.local/local-date 1)]
  (println "SMOKE_DATE eq=" (= a b) "cmp=" (compare a c) "str=" (str a)))' 2>&1)"
if printf '%s' "$out_d" | grep -q 'SMOKE_DATE eq= true cmp= -1 str= 1970-01-01'; then
  echo "PASS: (d) LocalDate eq/compare/str replay from the fasl"; pass=$((pass+1))
else
  echo "FAIL: (d) LocalDate expression did not give expected output"
  printf '%s\n' "$out_d" | tail -5
  fails=$((fails+1))
fi

# (e) the manifest lists clojure.test
if grep -q '^clojure.test$' host/chez/stdlib-fasl-manifest.txt; then
  echo "PASS: (e) manifest lists clojure.test"; pass=$((pass+1))
else
  echo "FAIL: (e) manifest does not list clojure.test"; fails=$((fails+1))
fi

echo
echo "stdlib-fasl smoke: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
