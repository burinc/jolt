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

# (e) the manifest lists clojure.test (tr -d: a CRLF checkout must still match)
if tr -d '\r' < host/chez/stdlib-fasl-manifest.txt | grep -qx 'clojure.test'; then
  echo "PASS: (e) manifest lists clojure.test"; pass=$((pass+1))
else
  echo "FAIL: (e) manifest does not list clojure.test"; fails=$((fails+1))
fi

# (f) a dep NOT in the eager CLI image arrives via its OWN fasl, not source.
# jolt.fs proxies babashka.fs; nothing in the CLI image requires either, so if
# the fasl dropped the ns form's require (the bld-emit-ns regression this gates),
# babashka.fs never loads and every proxied var is unbound. This slipped past
# (a)-(d) because clojure.test/jolt.time deps happen to sit in the image.
debug_f="$(JOLT_DEBUG=1 "$jolt" -e "(require '[jolt.fs :as fs])" 2>&1)"
out_f="$("$jolt" -e '(require (quote [jolt.fs :as fs])) (println "SMOKE_FS" (str (fs/absolute? "/x")))' 2>&1)"
if printf '%s\n' "$debug_f" | grep -q '\[jolt.aot\] embedded jolt.fs' \
   && printf '%s\n' "$debug_f" | grep -q '\[jolt.aot\] embedded babashka.fs'; then
  echo "PASS: (f1) JOLT_DEBUG shows both embedded jolt.fs and babashka.fs"; pass=$((pass+1))
else
  echo "FAIL: (f1) dep did not arrive via its own fasl"
  printf '%s\n' "$debug_f" | grep '\[jolt.aot\]' | head
  fails=$((fails+1))
fi
if printf '%s' "$out_f" | grep -q 'SMOKE_FS true'; then
  echo "PASS: (f2) fs/absolute? runs (babashka.fs loaded via fasl)"; pass=$((pass+1))
else
  echo "FAIL: (f2) fs/absolute? did not run (babashka.fs unbound?)"
  printf '%s\n' "$out_f" | tail -5
  fails=$((fails+1))
fi

# (g) a namespace whose top level sets a compiler flag loads from its fasl.
# babashka.process and babashka.fs both do (set! *warn-on-reflection* true).
# Loading compiled code has to bind that var to a thread-local slot the way a
# source load does; without it the set! hits the root, raises, and the fallback
# quietly recompiles the whole namespace from source — the fasl is baked into
# the binary and never once used. (f1) did not catch it because the aot-info
# line it greps used to print before the load was attempted; it reports the
# outcome now, and this checks the outcome a second way.
for g_ns in babashka.fs babashka.process; do
  n_g="$(JOLT_TRACE_LOAD=1 "$jolt" -e "(require '$g_ns)" 2>&1 | grep -c '\[load-form\]' || true)"
  if [ "$n_g" = "0" ]; then
    echo "PASS: (g) $g_ns loads from its fasl with zero [load-form] lines"; pass=$((pass+1))
  else
    echo "FAIL: (g) $g_ns compiled $n_g form(s) from source — fasl did not take"; fails=$((fails+1))
  fi
  # The frame has to belong to the NAMESPACE, not to whoever required it. Every
  # entry point binds these vars now, so a fasl whose set! writes the CALLER's
  # binding loads without complaint and (g) above stays green — the set! just
  # escapes into the requiring code, where a stray *warn-on-reflection* is the
  # least of it: *unchecked-math* changes what later arithmetic compiles to.
  # This is the check that fails if the loader stops establishing its own frame.
  out_g="$("$jolt" -e "(let [b *warn-on-reflection*] (require '$g_ns) (println :leak (not= b *warn-on-reflection*)))" 2>&1)"
  if printf '%s' "$out_g" | grep -q ':leak false'; then
    echo "PASS: (g) $g_ns set! stays inside its own load"; pass=$((pass+1))
  else
    echo "FAIL: (g) $g_ns leaked its compiler-flag set! to the requiring code"
    printf '%s\n' "$out_g" | tail -3
    fails=$((fails+1))
  fi
done

echo
echo "stdlib-fasl smoke: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
