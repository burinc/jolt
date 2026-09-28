#!/bin/sh
# aot-cache smoke: verify the per-namespace AOT/compile cache.
#
# The cache fasls a required namespace's emitted Scheme on first load (miss)
# and loads the .so on subsequent loads (hit), keyed by source content hash +
# jolt version. This script drives the fast dev bin/jolt (devcache mode loads
# the same loader.ss, so the hook is exercised) with a temp cache dir.
#
# Phases (added incrementally):
#   1 — core miss/hit/invalidate        (this file)
#   2 — correctness edge cases          (macro/record/data-reader/transitive)
#   3 — bypass semantics                (:reload, install-owned never cached)
#   4 — performance gate                (cold vs warm wall-clock)

set -e

pass=0
fails=0
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"

jolt="bin/jolt"
cache="$(mktemp -d)"
tmp="$(mktemp -d)"
mkdir -p "$tmp/src/mylib"

# A program that requires a disk-backed ns via add-deps (the real require path)
# and prints a value computed in it. \$1 = the temp project dir.
run_prog() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps)
    (jolt.deps/add-deps {:deps {'mylib/mylib {:local/root \"$1\"}}})
    (require 'mylib.core)
    (println (mylib.core/answer))" 2>/dev/null | tail -1
}

count_cache_files() { find "$cache" -name '*.so' 2>/dev/null | wc -l | tr -d ' '; }

# --- (a) cold load writes a .so and produces correct output -------------------
cat > "$tmp/src/mylib/core.clj" <<'CLJ'
(ns mylib.core)
(defn answer [] 42)
CLJ
out_a="$(run_prog "$tmp")"
n_a="$(count_cache_files)"
if [ "$out_a" = "42" ] && [ "$n_a" -ge 1 ]; then
  echo "PASS: (a) cold load output=42, cache files=$n_a"; pass=$((pass+1))
else
  echo "FAIL: (a) cold load output='$out_a' cache files=$n_a (expected output 42, >=1 .so)"; fails=$((fails+1))
fi

# --- (b) warm load produces identical output (cache hit) ----------------------
out_b="$(run_prog "$tmp")"
if [ "$out_b" = "42" ]; then
  echo "PASS: (b) warm load output=42"; pass=$((pass+1))
else
  echo "FAIL: (b) warm load output='$out_b' (expected 42)"; fails=$((fails+1))
fi

# --- (c) editing source invalidates: recompiles, output reflects the edit -----
sleep 1  # ensure mtime advances
cat > "$tmp/src/mylib/core.clj" <<'CLJ'
(ns mylib.core)
(defn answer [] 99)
CLJ
out_c="$(run_prog "$tmp")"
n_c="$(count_cache_files)"
if [ "$out_c" = "99" ]; then
  echo "PASS: (c) after edit output=99"; pass=$((pass+1))
else
  echo "FAIL: (c) after edit output='$out_c' (expected 99 — cache did not invalidate)"; fails=$((fails+1))
fi

# --- (c2) same-length edit on a realistically-sized source --------------------
# equal-hash samples at most ~26 bytes regardless of length, so a same-length
# edit away from those sampling points produces a collision and serves stale
# code. The fixture is ~4 KB with the value in the middle — far from the small
# test above where the edit happens to land in a sampled byte. 42 -> 99.
c2="$tmp/c2"; mkdir -p "$c2/src/mylib"
# Regenerated rather than sed-edited: `sed -i ''` is BSD-only (GNU sed reads the
# '' as the script and the s/// as a filename, exits 2, and set -e kills the run),
# and both values are two digits so rewriting the file is length-preserving anyway.
gen_c2() {
  {
    # pad: ~2 KB of comment lines above the value
    i=0; while [ "$i" -lt 32 ]; do
      printf ';; padding line %s for cache key size ---------------------------------------\n' "$i"
      i=$((i + 1))
    done
    echo '(ns mylib.core)'
    printf '(defn answer [] %s)\n' "$1"
    # pad: ~2 KB of comment lines below the value
    i=0; while [ "$i" -lt 32 ]; do
      printf ';; padding line %s for cache key size ---------------------------------------\n' "$i"
      i=$((i + 1))
    done
  } > "$c2/src/mylib/core.clj"
}
gen_c2 42
c2_len=$(wc -c < "$c2/src/mylib/core.clj")
if [ "$c2_len" -lt 4096 ]; then
  echo "FAIL: (c2) fixture too small: $c2_len bytes (need >=4096)"; fails=$((fails+1))
else
  sleep 1  # ensure mtime advances
  c2_cold="$(run_prog "$c2")"
  if [ "$c2_cold" != "42" ]; then
    echo "FAIL: (c2) cold output='$c2_cold' (expected 42)"; fails=$((fails+1))
  else
    # length-preserving edit: 42 -> 99
    c2_orig_len=$(wc -c < "$c2/src/mylib/core.clj")
    gen_c2 99
    c2_new_len=$(wc -c < "$c2/src/mylib/core.clj")
    if [ "$c2_orig_len" != "$c2_new_len" ]; then
      echo "FAIL: (c2) edit changed length: $c2_orig_len -> $c2_new_len (expected equal)"; fails=$((fails+1))
    else
      sleep 1
      c2_edit="$(run_prog "$c2")"
      if [ "$c2_edit" = "99" ]; then
        echo "PASS: (c2) large-fixture edit invalidated, output=99"; pass=$((pass+1))
      else
        echo "FAIL: (c2) after edit output='$c2_edit' (expected 99 — equal-hash sampled stale)"; fails=$((fails+1))
      fi
    fi
  fi
fi

# --- Phase 2: correctness the tee must preserve (cold == warm == expected) ----
# case_cold_warm <label> <projdir> <expr-after-add-deps> <expected>
# projdir has src/proj/core.clj (+ siblings); expr requires proj.core and prints
# (proj.core/run). Asserts cold and warm runs both print `expected`.
case_cold_warm() {
  clabel="$1"; cproj="$2"; cexpr="$3"; cexp="$4"
  cmd="(require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$cproj\"}}}) $cexpr"
  ccold="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "$cmd" 2>/dev/null | tail -1)"
  cwarm="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "$cmd" 2>/dev/null | tail -1)"
  if [ "$ccold" = "$cexp" ] && [ "$cwarm" = "$cexp" ]; then
    echo "PASS: ($clabel) cold='$ccold' warm='$cwarm'"; pass=$((pass+1))
  else
    echo "FAIL: ($clabel) cold='$ccold' warm='$cwarm' (expected '$cexp')"; fails=$((fails+1))
  fi
}

# (d) same-file macro def-then-use — the forward ref only works because the tee
# records each form AFTER its eval has marked the macro (so the later form's emit
# has the macro already expanded; the .so replays that).
d="$tmp/d"; mkdir -p "$d/src/proj"
cat > "$d/src/proj/core.clj" <<'CLJ'
(ns proj.core)
(defmacro mx [x] (str "macro-" x))
(defn run [] (mx 42))
CLJ
case_cold_warm "d" "$d" "(require 'proj.core) (println (proj.core/run))" "macro-42"

# (e) defrecord — compile-time type registration must reproduce on cache hit.
e="$tmp/e"; mkdir -p "$e/src/proj"
cat > "$e/src/proj/core.clj" <<'CLJ'
(ns proj.core)
(defrecord Pt [x y])
(defn run [] (:x (->Pt 7 8)))
CLJ
case_cold_warm "e" "$e" "(require 'proj.core) (println (proj.core/run))" "7"

# (f) data reader #tag in a required ns — the reader rewrite is baked into the
# captured emit (post ldr-apply-readers), so the .so carries it. data_readers.clj
# at the source root registers the reader (add-deps' set-source-roots! scans it).
f="$tmp/f"; mkdir -p "$f/src/proj"
cat > "$f/src/data_readers.clj" <<'CLJ'
{greet proj.dr/foo}
CLJ
cat > "$f/src/proj/dr.clj" <<'CLJ'
(ns proj.dr)
(defn foo [v] (str "got-" v))
CLJ
cat > "$f/src/proj/core.clj" <<'CLJ'
(ns proj.core (:require [proj.dr]))
(defn run [] #greet "hi")
CLJ
case_cold_warm "f" "$f" "(require 'proj.core) (println (proj.core/run))" "got-hi"

# (g) transitive require — proj.core requires proj.sub; the cached .so for
# proj.core re-triggers the require, loading proj.sub (from its own cache entry).
g="$tmp/g"; mkdir -p "$g/src/proj"
cat > "$g/src/proj/core.clj" <<'CLJ'
(ns proj.core (:require [proj.sub :as s]))
(defn run [] (s/subval))
CLJ
cat > "$g/src/proj/sub.clj" <<'CLJ'
(ns proj.sub)
(defn subval [] :subval)
CLJ
case_cold_warm "g" "$g" "(require 'proj.core) (println (proj.core/run))" ":subval"

# --- Phase 3: bypass semantics ------------------------------------------------
# (h) :reload bypasses the cache and picks up an edit even when a fresh .so for
# the OLD content exists. The :reload sets force?=#t → aot-load-or-compile takes
# the plain load-jolt-file branch (no read, no write of the cache), so the edited
# source compiles and runs.
h="$tmp/h"; mkdir -p "$h/src/proj"
printf '(ns proj.core)\n(defn answer [] 42)\n' > "$h/src/proj/core.clj"
hcmd="(require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$h\"}}})"
# cold: populate the cache with the v1 .so
JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "$hcmd (require 'proj.core) (println (proj.core/answer))" >/dev/null 2>&1
# warm (no reload): cache hit → still 42
warm1="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "$hcmd (require 'proj.core) (println (proj.core/answer))" 2>/dev/null | tail -1)"
# edit, then :reload — must show the edit despite the stale v1 .so in the cache
sleep 1
printf '(ns proj.core)\n(defn answer [] 99)\n' > "$h/src/proj/core.clj"
reload_out="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "$hcmd (require 'proj.core :reload) (println (proj.core/answer))" 2>/dev/null | tail -1)"
if [ "$warm1" = "42" ] && [ "$reload_out" = "99" ]; then
  echo "PASS: (h) warm=$warm1, :reload-after-edit=$reload_out"; pass=$((pass+1))
else
  echo "FAIL: (h) warm='$warm1' (want 42), :reload-after-edit='$reload_out' (want 99)"; fails=$((fails+1))
fi

# (i) install-owned namespaces (stdlib/jolt-core — embedded in the binary) are
# NEVER cached. Run in SOURCE mode (chez --script cli.ss) so clojure.set actually
# loads on demand (the devcache preloads it); ldr-install-file? must bypass it.
# JOLT_CHEZ wins (see host/chez/selfcheck.sh) — otherwise this runs (i) under
# whatever Chez happens to be on PATH, independent of the one the rest of this
# gate actually built with.
chez_bin="${JOLT_CHEZ:-$(command -v chez || command -v scheme || command -v chezscheme)}"
n_i="(not cached)"
if [ -n "$chez_bin" ]; then
  cache_i="$(mktemp -d)"
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_i" JOLT_VERSION=dev "$chez_bin" --script host/chez/cli.ss \
    -e "(require 'clojure.set) (println (clojure.set/union #{1 2} #{2 3}))" >/dev/null 2>&1
  n_i="$(find "$cache_i" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$cache_i"
fi
if [ "$n_i" = "0" ]; then
  echo "PASS: (i) install-owned clojure.set produced 0 cache files"; pass=$((pass+1))
else
  echo "FAIL: (i) install-owned clojure.set produced $n_i cache files (expected 0)"; fails=$((fails+1))
fi

# --- (j) corrupt cache file is recovered, not fatal --------------------------
# A truncated/garbage .so (killed process, concurrent mid-write) must fall back
# to recompile and still produce correct output — not crash the program. Populate
# the cache with a good entry, then overwrite the .so with garbage and run.
j="$tmp/j"; mkdir -p "$j/src/mylib"
printf '(ns mylib.core)\n(defn answer [] 42)\n' > "$j/src/mylib/core.clj"
jrun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'mylib/mylib {:local/root \"$j\"}}})
    (require 'mylib.core) (println (mylib.core/answer))" 2>/dev/null | tail -1
}
# cold: populate
jrun >/dev/null 2>&1
# corrupt every cached .so
find "$cache" -name '*.so' -exec sh -c 'printf "GARBAGE-NOT-FASL" > "$1"' sh {} \;
jout="$(jrun)"
jso_after="$(count_cache_files)"
if [ "$jout" = "42" ] && [ "$jso_after" -ge 1 ]; then
  echo "PASS: (j) corrupt cache recovered, output=42, rebuilt .so"; pass=$((pass+1))
else
  echo "FAIL: (j) corrupt cache: output='$jout' .so-after=$jso_after (expected 42, >=1 rebuilt)"; fails=$((fails+1))
fi

# --- (k) two runtimes reporting one version don't share a cache namespace ----
# The fasl a namespace compiles to is only valid for the runtime that emitted it,
# and the version string does not pin one: `git describe` reports the same
# "…-dirty" for every edit in a working tree, so a rebuilt jolt used to load its
# predecessor's output. Drive the SAME namespace through two genuinely different
# runtimes — the source tree and the built binary — with the version forced equal,
# and require them to land in separate cache namespaces.
k="$tmp/k"; mkdir -p "$k/src/mylib"
printf '(ns mylib.core)\n(defn answer [] 42)\n' > "$k/src/mylib/core.clj"
cache_k="$(mktemp -d)"
kprog="(require 'jolt.deps)
       (jolt.deps/add-deps {:deps {'mylib/mylib {:local/root \"$k\"}}})
       (require 'mylib.core) (println (mylib.core/answer))"
kbin="target/release/jolt"
n_k="(skipped)"; k_out_src=""; k_out_bin=""
if [ -n "$chez_bin" ] && [ -x "$kbin" ]; then
  # the binary bakes its version, so read it back and hand it to the source run
  kver="$("$kbin" --version 2>/dev/null | sed 's/^jolt //')"
  k_out_src="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_k" JOLT_VERSION="$kver" JOLT_QUIET=1 \
    "$chez_bin" --script host/chez/cli.ss -e "$kprog" 2>/dev/null | tail -1)"
  k_out_bin="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_k" JOLT_QUIET=1 \
    "$kbin" -e "$kprog" 2>/dev/null | tail -1)"
  n_k="$(find "$cache_k" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
fi
rm -rf "$cache_k"
if [ "$n_k" = "(skipped)" ]; then
  echo "SKIP: (k) needs chez + $kbin (make testbin)"
elif [ "$n_k" = "2" ] && [ "$k_out_src" = "42" ] && [ "$k_out_bin" = "42" ]; then
  echo "PASS: (k) source and binary runtimes keyed separately under one version"; pass=$((pass+1))
else
  echo "FAIL: (k) cache namespaces=$n_k (expected 2), source='$k_out_src' binary='$k_out_bin' (expected 42)"; fails=$((fails+1))
fi

# --- (l) editing a REQUIRED namespace invalidates its consumers ---------------
# A namespace's fasl bakes in whatever its dependencies contributed at compile
# time — macro expansions above all — so keying only on its own source leaves it
# serving expansions from a macro definition that no longer exists. The consumer
# is untouched here; only the macro namespace changes.
l="$tmp/l"; mkdir -p "$l/src/dep"
printf '(ns dep.macros)\n(defmacro tag [] "v1")\n' > "$l/src/dep/macros.clj"
printf '(ns dep.core (:require [dep.macros :as m]))\n(defn answer [] (m/tag))\n' > "$l/src/dep/core.clj"
lrun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'dep/dep {:local/root \"$l\"}}})
    (require 'dep.core) (println (dep.core/answer))" 2>/dev/null | tail -1
}
l_cold="$(lrun)"
sleep 1
printf '(ns dep.macros)\n(defmacro tag [] "v2")\n' > "$l/src/dep/macros.clj"
l_warm="$(lrun)"
if [ "$l_cold" = "v1" ] && [ "$l_warm" = "v2" ]; then
  echo "PASS: (l) macro-ns edit invalidated its consumer (v1 -> v2)"; pass=$((pass+1))
else
  echo "FAIL: (l) cold='$l_cold' (want v1) after-macro-edit='$l_warm' (want v2)"; fails=$((fails+1))
fi

# --- (m) invalidation reaches through a chain, not just direct requires -------
# top -> mid -> low, with the macro at the bottom: top's key has to fold in the
# whole transitive closure, since mid contributes low's expansion to it.
m="$tmp/m"; mkdir -p "$m/src/chain"
printf '(ns chain.low)\n(defmacro tag [] "v1")\n' > "$m/src/chain/low.clj"
printf '(ns chain.mid (:require [chain.low :as l]))\n(defn mid-answer [] (l/tag))\n' > "$m/src/chain/mid.clj"
printf '(ns chain.top (:require [chain.mid :as mid]))\n(defn answer [] (mid/mid-answer))\n' > "$m/src/chain/top.clj"
mrun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'chain/chain {:local/root \"$m\"}}})
    (require 'chain.top) (println (chain.top/answer))" 2>/dev/null | tail -1
}
m_cold="$(mrun)"
sleep 1
printf '(ns chain.low)\n(defmacro tag [] "v2")\n' > "$m/src/chain/low.clj"
m_warm="$(mrun)"
if [ "$m_cold" = "v1" ] && [ "$m_warm" = "v2" ]; then
  echo "PASS: (m) transitive dep edit invalidated the chain (v1 -> v2)"; pass=$((pass+1))
else
  echo "FAIL: (m) cold='$m_cold' (want v1) after-transitive-edit='$m_warm' (want v2)"; fails=$((fails+1))
fi

# --- (n) superseded runtime generations are pruned ---------------------------
# The cache namespace moves whenever the runtime does, so a dev loop that
# rebuilds jolt leaves a full generation behind per build. Plant stale
# generations with old markers and require the run to collect them, keeping the
# few most recently used (the current one always among them).
cache_n="$(mktemp -d)"
i=1
while [ "$i" -le 6 ]; do
  mkdir -p "$cache_n/stale-gen-$i/v1"
  : > "$cache_n/stale-gen-$i/.used"
  touch -t "2020010100$(printf '%02d' "$i")" "$cache_n/stale-gen-$i/.used"
  i=$((i+1))
done
n_before="$(find "$cache_n" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
out_n="$(JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_n" JOLT_QUIET=1 "$jolt" -e "
  (require 'jolt.deps) (jolt.deps/add-deps {:deps {'mylib/mylib {:local/root \"$k\"}}})
  (require 'mylib.core) (println (mylib.core/answer))" 2>/dev/null | tail -1)"
n_after="$(find "$cache_n" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
n_live="$(find "$cache_n" -name '*.so' | wc -l | tr -d ' ')"
rm -rf "$cache_n"
if [ "$n_before" = "6" ] && [ "$n_after" -le 3 ] && [ "$n_live" -ge 1 ] && [ "$out_n" = "42" ]; then
  echo "PASS: (n) pruned $n_before generations to $n_after, current one live"; pass=$((pass+1))
else
  echo "FAIL: (n) generations $n_before -> $n_after (want <=3), live .so=$n_live, output='$out_n'"; fails=$((fails+1))
fi

# --- (o) an artifact holds its OWN namespace, not the ones it requires --------
# The capture teed every form compiled while a namespace loaded. A cacheable
# require redirected it (the nested aot-capture-load opens its own port), but an
# install-owned one bypasses the cache entirely and so never did — the requiring
# namespace's artifact ended up carrying a whole second copy of the stdlib
# namespace, replayed AFTER the require that already loaded it properly.
#
# That is only bloat until a sibling require layers something on top of what the
# stdlib namespace registered: the baked copy replays last and undoes it. Which is
# what jolt.time did — its 14-line ns form cached as 412 KB of eight jolt/time/*
# namespaces, and on a hit jolt.time.local's ISO-only java.time.LocalDate/parse
# landed back on top of jolt.time.fmt's pattern-aware override, so a warm cache
# silently ignored a DateTimeFormatter. Same shape here with clojure.zip:
# top requires the install-owned namespace and then the sibling that overrides it.
o="$tmp/o"; mkdir -p "$o/src/olib"
printf '{}' > "$o/deps.edn"
cat > "$o/src/olib/over.clj" <<'CLJ'
(ns olib.over (:require [clojure.zip :as z]))
(alter-var-root #'clojure.zip/root (constantly (fn [_] :overridden)))
(defn probe [] (z/root nil))
CLJ
cat > "$o/src/olib/top.clj" <<'CLJ'
(ns olib.top (:require [clojure.zip] [olib.over]))
(defn probe [] (olib.over/probe))
CLJ
cache_o="$(mktemp -d)"
run_o() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_o" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'olib/olib {:local/root \"$o\"}}})
    (require 'olib.top) (println (olib.top/probe))" 2>/dev/null | tail -1
}
o_cold="$(run_o)"
o_warm="$(run_o)"
o_scm="$(find "$cache_o" -name 'olib.top-*.scm' | head -1)"
# Each in-ns reference followed by the namespace symbol it interns. Matched
# through a window rather than adjacently, because the two are no longer
# neighbours in the emitted text: a top-level var reference now resolves through
# a per-form cache cell (jolt-g3u), so `in-ns` and its argument are separated by
# the cell's (or … (set! …)) . The window is what this check actually wants —
# which namespaces the artifact interns — independent of how a var ref is spelled.
o_defines="$(grep -o 'in-ns.\{0,200\}' "$o_scm" 2>/dev/null \
             | sed -n 's/.*jolt-symbol #f "\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$cache_o"
if [ "$o_cold" = ":overridden" ] && [ "$o_warm" = ":overridden" ] && [ "$o_defines" = "olib.top" ]; then
  echo "PASS: (o) artifact defines only olib.top; override survives the hit"; pass=$((pass+1))
else
  echo "FAIL: (o) cold='$o_cold' warm='$o_warm' (both want :overridden), artifact defines '$o_defines' (want 'olib.top')"
  fails=$((fails+1))
fi

# --- Phase 5: files read at compile time invalidate their reader --------------
# A macro that slurps an external file bakes that file's CONTENTS into the
# artifact, exactly the way it bakes a macro expansion. The key folded in the
# source and the required namespaces but nothing the compile read, so editing an
# embedded SQL migration (and nothing else) left every consumer serving the old
# statements out of the cache — silently, since the .clj is untouched and its
# hash still matches (jolt#576).

# (p) slurp of a path at macro-expansion time
p="$tmp/p"; mkdir -p "$p/src/proj"
printf 'v1' > "$p/mig.sql"
cat > "$p/src/proj/core.clj" <<CLJ
(ns proj.core)
(defmacro embed [] (slurp "$p/mig.sql"))
(defn run [] (embed))
CLJ
prun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$p\"}}})
    (require 'proj.core) (println (proj.core/run))" 2>/dev/null | tail -1
}
p_cold="$(prun)"
printf 'v2' > "$p/mig.sql"
p_warm="$(prun)"
if [ "$p_cold" = "v1" ] && [ "$p_warm" = "v2" ]; then
  echo "PASS: (p) slurped file edit invalidated its reader (v1 -> v2)"; pass=$((pass+1))
else
  echo "FAIL: (p) cold='$p_cold' (want v1) after-resource-edit='$p_warm' (want v2)"; fails=$((fails+1))
fi

# (q) io/resource — the classpath spelling, resolved against the source roots
q="$tmp/q"; mkdir -p "$q/src/proj" "$q/resources"
printf '{:paths ["src" "resources"]}' > "$q/deps.edn"
printf 'r1' > "$q/resources/mig.sql"
cat > "$q/src/proj/core.clj" <<'CLJ'
(ns proj.core (:require [clojure.java.io :as io]))
(defmacro embed [] (slurp (io/resource "mig.sql")))
(defn run [] (embed))
CLJ
qrun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$q\"}}})
    (require 'proj.core) (println (proj.core/run))" 2>/dev/null | tail -1
}
q_cold="$(qrun)"
printf 'r2' > "$q/resources/mig.sql"
q_warm="$(qrun)"
if [ "$q_cold" = "r1" ] && [ "$q_warm" = "r2" ]; then
  echo "PASS: (q) io/resource edit invalidated its reader (r1 -> r2)"; pass=$((pass+1))
else
  echo "FAIL: (q) cold='$q_cold' (want r1) after-resource-edit='$q_warm' (want r2)"; fails=$((fails+1))
fi

# (q2) a resource that did not exist yet — adding one (a new migration) has to
# invalidate the namespace that probed for it and found nothing.
printf '(ns proj.opt (:require [clojure.java.io :as io]))\n(defmacro embed [] (if-let [u (io/resource "opt.sql")] (slurp u) "none"))\n(defn run [] (embed))\n' > "$q/src/proj/opt.clj"
q2run() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$q\"}}})
    (require 'proj.opt) (println (proj.opt/run))" 2>/dev/null | tail -1
}
q2_cold="$(q2run)"
printf 'appeared' > "$q/resources/opt.sql"
q2_warm="$(q2run)"
if [ "$q2_cold" = "none" ] && [ "$q2_warm" = "appeared" ]; then
  echo "PASS: (q2) an added resource invalidated the ns that probed for it"; pass=$((pass+1))
else
  echo "FAIL: (q2) cold='$q2_cold' (want none) after-add='$q2_warm' (want appeared)"; fails=$((fails+1))
fi

# (q3) the same probe through a ClassLoader. RT/baseLoader's getResource is the
# other spelling of the same lookup, and libraries that reach the classpath
# rather than clojure.java.io use it — but it walked the roots on its own and
# announced nothing, so a compile-time probe through it was invisible to the key
# and an added resource kept serving the "not there" answer. It resolves through
# io/resource's resolver now, so it announces what that announces.
printf '(ns proj.clopt)\n(defmacro embed [] (if-let [u (.getResource (clojure.lang.RT/baseLoader) "clopt.sql")] (slurp u) "none"))\n(defn run [] (embed))\n' > "$q/src/proj/clopt.clj"
q3run() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'proj/proj {:local/root \"$q\"}}})
    (require 'proj.clopt) (println (proj.clopt/run))" 2>/dev/null | tail -1
}
q3_cold="$(q3run)"
printf 'appeared' > "$q/resources/clopt.sql"
q3_warm="$(q3run)"
if [ "$q3_cold" = "none" ] && [ "$q3_warm" = "appeared" ]; then
  echo "PASS: (q3) an added resource invalidated the ns that probed the loader"; pass=$((pass+1))
else
  echo "FAIL: (q3) cold='$q3_cold' (want none) after-add='$q3_warm' (want appeared)"; fails=$((fails+1))
fi

# (r) the read happens while compiling the CONSUMER (the macro lives one
# namespace away), so the resource belongs to the consumer's key, and editing it
# has to move that key even though neither .clj changed.
r="$tmp/r"; mkdir -p "$r/src/chain"
printf 'w1' > "$r/mig.sql"
cat > "$r/src/chain/mac.clj" <<CLJ
(ns chain.mac)
(defmacro embed [] (slurp "$r/mig.sql"))
CLJ
cat > "$r/src/chain/top.clj" <<'CLJ'
(ns chain.top (:require [chain.mac :as m]))
(defn run [] (m/embed))
CLJ
rrun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'chain/chain {:local/root \"$r\"}}})
    (require 'chain.top) (println (chain.top/run))" 2>/dev/null | tail -1
}
r_cold="$(rrun)"
printf 'w2' > "$r/mig.sql"
r_warm="$(rrun)"
if [ "$r_cold" = "w1" ] && [ "$r_warm" = "w2" ]; then
  echo "PASS: (r) cross-namespace macro read invalidated the consumer (w1 -> w2)"; pass=$((pass+1))
else
  echo "FAIL: (r) cold='$r_cold' (want w1) after-resource-edit='$r_warm' (want w2)"; fails=$((fails+1))
fi

# (s) a resource baked into a REQUIRED namespace's own artifact propagates
# through the chain the way an edit to that namespace's source does: deep.low
# expands the slurp into its OWN .so, and deep.top's key has to fold that in.
s="$tmp/s"; mkdir -p "$s/src/deep"
printf 'd1' > "$s/mig.sql"
cat > "$s/src/deep/low.clj" <<CLJ
(ns deep.low)
(defmacro mig [] (slurp "$s/mig.sql"))
(def payload (mig))
CLJ
cat > "$s/src/deep/top.clj" <<'CLJ'
(ns deep.top (:require [deep.low :as l]))
(defn run [] l/payload)
CLJ
srun() {
  JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'deep/deep {:local/root \"$s\"}}})
    (require 'deep.top) (println (deep.top/run))" 2>/dev/null | tail -1
}
s_cold="$(srun)"
printf 'd2' > "$s/mig.sql"
s_warm="$(srun)"
if [ "$s_cold" = "d1" ] && [ "$s_warm" = "d2" ]; then
  echo "PASS: (s) a required ns's resource edit reached the chain (d1 -> d2)"; pass=$((pass+1))
else
  echo "FAIL: (s) cold='$s_cold' (want d1) after-resource-edit='$s_warm' (want d2)"; fails=$((fails+1))
fi

# (t) a namespace that reads nothing writes no resource sidecar — the record is
# per-namespace, not a global list every artifact then keys on.
t_res="$(find "$cache" -name 'mylib.core-*.res' 2>/dev/null | wc -l | tr -d ' ')"
p_res="$(find "$cache" -name 'proj.core-*.res' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$t_res" = "0" ] && [ "$p_res" -ge 1 ]; then
  echo "PASS: (t) resource sidecars are per-namespace ($p_res for readers, 0 for mylib.core)"; pass=$((pass+1))
else
  echo "FAIL: (t) mylib.core sidecars=$t_res (want 0), proj.core sidecars=$p_res (want >=1)"; fails=$((fails+1))
fi

# --- (u) a fasl cut at a form boundary is detected, not served ----------------
# `load` of a .so truncated exactly at a compiled-form boundary SUCCEEDS — a
# Chez fasl is a sequence of objects — so the raise-based guard in (j) never
# fires and a partial namespace would be served on every run while a plain
# source load works. Every published .scm ends with a completion marker the
# loader checks after a hit-load. Simulate the partial artifact by stripping
# the marker from the cached .scm, recompiling that with the same Chez, and
# planting the result as the .so.
u="$tmp/u"; mkdir -p "$u/src/ulib"
printf '(ns ulib.core)\n(defn answer [] 42)\n' > "$u/src/ulib/core.clj"
cache_u="$(mktemp -d)"
urun() {
  JOLT_DEBUG="${UDEBUG:-}" JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_u" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'ulib/ulib {:local/root \"$u\"}}})
    (require 'ulib.core) (println (ulib.core/answer))" 2>&1
}
if [ -z "$chez_bin" ]; then
  echo "SKIP: (u) needs a chez on PATH to recompile the stripped .scm"
else
  urun >/dev/null 2>&1                                     # cold: populate
  u_scm="$(find "$cache_u" -name 'ulib.core-*.scm' | head -1)"
  u_so="${u_scm%.scm}.so"
  u_marked="$(tail -1 "$u_scm" | grep -c 'aot-mark-complete!')"
  u_warm="$(UDEBUG=1 urun)"                                # warm: real hit
  grep -v 'aot-mark-complete!' "$u_scm" > "$u_scm.cut"
  printf '(compile-file "%s" "%s")\n' "$u_scm.cut" "$u_so" | "$chez_bin" -q >/dev/null 2>&1
  u_cut="$(UDEBUG=1 urun)"                                 # partial artifact planted
  u_heal="$(UDEBUG=1 urun)"                                # must be a clean hit again
  if [ "$u_marked" = "1" ] \
     && echo "$u_warm" | grep -q '^42$' && echo "$u_warm" | grep -q 'hit ulib.core' \
     && ! echo "$u_warm" | grep -q 'incomplete cache' \
     && echo "$u_cut" | grep -q '^42$' && echo "$u_cut" | grep -q 'incomplete cache for ulib.core' \
     && echo "$u_heal" | grep -q '^42$' && echo "$u_heal" | grep -q 'hit ulib.core' \
     && ! echo "$u_heal" | grep -q 'incomplete cache'; then
    echo "PASS: (u) form-boundary-truncated fasl detected, recompiled, healed"; pass=$((pass+1))
  else
    echo "FAIL: (u) marker=$u_marked warm-hit=$(echo "$u_warm" | grep -c 'hit ulib.core') cut-detected=$(echo "$u_cut" | grep -c 'incomplete cache') cut-out=$(echo "$u_cut" | tail -1) heal-hit=$(echo "$u_heal" | grep -c 'hit ulib.core')"; fails=$((fails+1))
  fi
fi
rm -rf "$cache_u"

# --- (v) a namespace that sets a compiler flag still hits its cache -----------
# (set! *warn-on-reflection* true) at a namespace's top level is the standard
# idiom in ported Clojure libraries. A source load binds that var to a
# thread-local slot for the duration of the file; loading the cached .so has to
# bind it too, or the set! hits the root, raises, and the loader reads the raise
# as a broken artifact — deleting and recompiling the SAME .so on every run, so
# the cache never once takes.
v="$tmp/v"; mkdir -p "$v/src/vlib"
cat > "$v/src/vlib/core.clj" <<'CLJ'
(ns vlib.core)
(set! *warn-on-reflection* true)
(defn answer [] 42)
CLJ
# ...and the frame has to be the NAMESPACE's own. Every entry point binds these
# vars now, so a .so whose set! writes the CALLER's binding loads and hits fine
# — it just escapes into the requiring code. :leak is what fails if the loader
# stops establishing a frame per compiled load.
# Top-level forms on purpose: -e compiles form by form, so vlib.core/answer
# resolves only because the require evaluated in an earlier form. The || true
# matters under set -e — a raising jolt otherwise kills the whole script before
# the FAIL branch can say which case died.
vrun() {
  JOLT_DEBUG=1 JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_v" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'vlib/vlib {:local/root \"$v\"}}})
    (def b0 *warn-on-reflection*)
    (require 'vlib.core)
    (println :leak (not= b0 *warn-on-reflection*))
    (println (vlib.core/answer))" 2>&1
}
cache_v="$(mktemp -d)"
v_cold="$(vrun || true)"
v_warm="$(vrun || true)"
if echo "$v_cold" | grep -q '^42$' \
   && echo "$v_warm" | grep -q '^42$' \
   && echo "$v_warm" | grep -q 'hit vlib.core' \
   && ! echo "$v_warm" | grep -q 'corrupt cache for vlib.core' \
   && echo "$v_cold" | grep -q ':leak false' \
   && echo "$v_warm" | grep -q ':leak false'; then
  echo "PASS: (v) compiler-flag set! namespace hits its cache, set! stays in its own load"; pass=$((pass+1))
else
  echo "FAIL: (v) warm run: hit=$(echo "$v_warm" | grep -c 'hit vlib.core') corrupt=$(echo "$v_warm" | grep -c 'corrupt cache for vlib.core') out=$(echo "$v_warm" | grep -c '^42$') cold-leak=$(echo "$v_cold" | grep -c ':leak false') warm-leak=$(echo "$v_warm" | grep -c ':leak false')"; fails=$((fails+1))
fi
rm -rf "$cache_v"

# (w) A live VALUE a macro put in its expansion has to survive the fasl. jolt
# rebuilds one as CODE rather than stashing it in a process-local table
# (jolt-l7tq), and a table would be invisible here — the cold run would work and
# the warm one would load a .so referring to an index nothing filled. So this
# asserts the WARM run, off the fasl, still answers: a named fn read back
# through its var, and an anonymous literal rebuilt from its source form and its
# captured value.
elib="$(mktemp -d)"; mkdir -p "$elib/src/elib"
printf '{:paths ["src"]}\n' > "$elib/deps.edn"
cat > "$elib/src/elib/core.clj" <<'CLJ'
(ns elib.core)
(defmacro named-fn [] (deref #'clojure.core/memfn))
(defn mk-adder [n] (fn [x] (+ x n)))
(defmacro anon-fn [] (mk-adder 7))
(def a (named-fn))
(def b (anon-fn))
CLJ
erun() {
  JOLT_DEBUG=1 JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_e" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'elib/elib {:local/root \"$elib\"}}})
    (require 'elib.core)
    (println :embedded (fn? elib.core/a) (elib.core/b 35))" 2>&1
}
cache_e="$(mktemp -d)"
e_cold="$(erun || true)"
e_warm="$(erun || true)"
if echo "$e_cold" | grep -q ':embedded true 42' \
   && echo "$e_warm" | grep -q ':embedded true 42' \
   && echo "$e_warm" | grep -q 'hit elib.core'; then
  echo "PASS: (w) an embedded live value round-trips through the fasl"; pass=$((pass+1))
else
  echo "FAIL: (w) cold=$(echo "$e_cold" | grep -c ':embedded true 42') warm=$(echo "$e_warm" | grep -c ':embedded true 42') hit=$(echo "$e_warm" | grep -c 'hit elib.core')"
  echo "$e_warm" | tail -4 | sed 's/^/    /'
  fails=$((fails+1))
fi
rm -rf "$cache_e" "$elib"

# --- Phase 6: compile-time-relevance narrowing (JOLT_AOT_NARROW) --------------
# With direct-linking and whole-program inference off (plain `jolt run`), a
# dependency that defines no macros/records/protocols/forwarded vars cannot
# change a consumer's emitted code, so its edit must NOT recompile the consumer
# — while the consumer still reads the new value through the dep's var. A dep
# that GAINS a macro is the case the assumption has to catch: the consumer's
# cached artifact was compiled against an inert dep, so the hit is discarded and
# recompiled after the dep loads (loader.ss aot-assumptions-hold?).
xlib="$(mktemp -d)"; mkdir -p "$xlib/src/xlib" "$xlib/src/xapp"
printf '{:paths ["src"]}\n' > "$xlib/deps.edn"
printf '(ns xlib.core)\n(defn v [] 1)\n' > "$xlib/src/xlib/core.clj"
printf '(ns xapp.core (:require [xlib.core]))\n(defn run [] (xlib.core/v))\n' > "$xlib/src/xapp/core.clj"
cache_x="$(mktemp -d)"
xrun() {
  JOLT_AOT_NARROW=1 JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_x" JOLT_QUIET=1 JOLT_DEBUG=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'xapp/xapp {:local/root \"$xlib\"}}})
    (require 'xapp.core) (println (xapp.core/run))" 2>&1
}
x_cold="$(xrun || true)"
x_warm="$(xrun || true)"
printf '(ns xlib.core)\n(defn v [] 2)\n' > "$xlib/src/xlib/core.clj"
x_edit="$(xrun || true)"
if echo "$x_cold" | grep -q '^1$' && echo "$x_warm" | grep -q '^1$' \
   && echo "$x_edit" | grep -q '^2$' \
   && echo "$x_edit" | grep -q 'hit xapp.core' \
   && echo "$x_edit" | grep -q 'miss xlib.core'; then
  echo "PASS: (x) inert dep edit recompiles only the dep, consumer hits and sees v2"; pass=$((pass+1))
else
  echo "FAIL: (x) cold=$(echo "$x_cold" | tail -1) warm=$(echo "$x_warm" | tail -1) edit=$(echo "$x_edit" | tail -1) hit-consumer=$(echo "$x_edit" | grep -c 'hit xapp.core') miss-dep=$(echo "$x_edit" | grep -c 'miss xlib.core')"
  fails=$((fails+1))
fi
# the dep gains a macro: the consumer's stored assumption (inert) no longer
# holds, and the hit must be turned into a recompile rather than served
printf '(ns xlib.core)\n(defn v [] 2)\n(defmacro m [] :x)\n' > "$xlib/src/xlib/core.clj"
x_gain="$(xrun || true)"
if echo "$x_gain" | grep -q '^2$' \
   && echo "$x_gain" | grep -q 'stale-assumption cache for xapp.core, recompiling'; then
  echo "PASS: (y) a dep that gained a macro invalidated the assumed-inert consumer"; pass=$((pass+1))
else
  echo "FAIL: (y) after-gain=$(echo "$x_gain" | tail -1) stale=$(echo "$x_gain" | grep -c 'stale-assumption cache for xapp.core')"
  fails=$((fails+1))
fi
rm -rf "$cache_x" "$xlib"

# An inert dep still decides WHICH vars a consumer's compile can see: a var it
# drops makes a qualified reference a compile error, and under :refer :all a
# var it gains shadows a bare clojure.core symbol. Both must reach the consumer
# — its cached artifact is compiled against the old var set — so an inert dep
# is folded by its var names rather than as a constant.
slib="$(mktemp -d)"; mkdir -p "$slib/src/slib" "$slib/src/sapp"
printf '{:paths ["src"]}\n' > "$slib/deps.edn"
printf '(ns slib.core)\n(defn v [] 1)\n(defn w [] 2)\n' > "$slib/src/slib/core.clj"
printf '(ns sapp.core (:require [slib.core :refer :all]))\n(defn run [] [(inc 1) (slib.core/w)])\n' > "$slib/src/sapp/core.clj"
cache_s="$(mktemp -d)"
srun() {
  JOLT_AOT_NARROW=1 JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_s" JOLT_QUIET=1 JOLT_DEBUG=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'sapp/sapp {:local/root \"$slib\"}}})
    (println (try (require 'sapp.core) (pr-str ((resolve 'sapp.core/run)))
                  (catch Throwable t (str \"threw \" (ex-message t)))))" 2>&1
}
s_cold="$(srun || true)"; s_warm="$(srun || true)"
printf '(ns slib.core)\n(defn v [] 1)\n(defn w [] 2)\n(defn inc [x] :shadowed)\n' > "$slib/src/slib/core.clj"
s_gain="$(srun || true)"
printf '(ns slib.core)\n(defn v [] 1)\n(defn inc [x] :shadowed)\n' > "$slib/src/slib/core.clj"
s_drop="$(srun || true)"
if echo "$s_warm" | grep -q '^\[2 2\]$' \
   && echo "$s_gain" | grep -q '^\[:shadowed 2\]$' \
   && echo "$s_drop" | grep -q '^threw .*slib.core/w'; then
  echo "PASS: (x2) a var an inert dep gains or drops reaches its consumer"; pass=$((pass+1))
else
  echo "FAIL: (x2) warm=$(echo "$s_warm" | tail -1) gain=$(echo "$s_gain" | tail -1) drop=$(echo "$s_drop" | tail -1)"
  fails=$((fails+1))
fi
rm -rf "$cache_s" "$slib"

# --- Phase 7: async fasl compilation ------------------------------------------
# A miss's fasl compiles in a background worker of the running binary; the run
# itself must not wait. On by default, and JOLT_AOT_ASYNC=0 must put the compile
# back in the run (the fasl is there when it exits). Needs a built jolt — source
# mode's bin/jolt would spawn a plain Chez — so it skips without
# target/release/jolt, like (k).
async_bin="target/release/jolt"
if [ ! -x "$async_bin" ]; then
  echo "SKIP: (z) async worker needs $async_bin (make testbin)"
else
  alib="$(mktemp -d)"; mkdir -p "$alib/src/alib"; printf '{:paths ["src"]}\n' > "$alib/deps.edn"
  printf '(ns alib.core)\n(defn val [] 7)\n' > "$alib/src/alib/core.clj"
  zprog="(require 'jolt.deps) (jolt.deps/add-deps {:deps {'alib/alib {:local/root \"$alib\"}}}) (require 'alib.core) (println (alib.core/val))"
  zrun() {  # $1: cache dir; worker on (the default)
    env -u JOLT_AOT_ASYNC JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$1" JOLT_QUIET=1 JOLT_DEBUG=1 \
      "$async_bin" -e "$zprog" 2>&1
  }
  zrun_off() {  # $1: cache dir; in-process compile
    env -u JOLT_AOT_ASYNC JOLT_AOT_ASYNC=0 JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$1" JOLT_QUIET=1 JOLT_DEBUG=1 \
      "$async_bin" -e "$zprog" 2>&1
  }
  cache_z="$(mktemp -d)"
  z_cold="$(zrun "$cache_z" || true)"
  # the worker is a separate process: wait for its artifact, then prove it is
  # served. A crashed or mis-dispatched worker never writes one.
  i=0
  while [ "$i" -lt 40 ]; do
    [ "$(find "$cache_z" -name '*.so' | wc -l | tr -d ' ')" -ge 1 ] && break
    sleep 0.25; i=$((i+1))
  done
  z_so="$(find "$cache_z" -name '*.so' | wc -l | tr -d ' ')"
  z_warm="$(zrun "$cache_z" || true)"
  if echo "$z_cold" | grep -q '^7$' \
     && echo "$z_cold" | grep -q 'queued alib.core' \
     && [ "$z_so" -ge 1 ] \
     && echo "$z_warm" | grep -q '^7$' \
     && echo "$z_warm" | grep -q 'hit alib.core'; then
    echo "PASS: (z) a default-run miss queued to a worker, later runs hit its fasl"; pass=$((pass+1))
  else
    echo "FAIL: (z) cold=$(echo "$z_cold" | tail -1) queued=$(echo "$z_cold" | grep -c 'queued alib.core') so=$z_so warm=$(echo "$z_warm" | tail -1) hit=$(echo "$z_warm" | grep -c 'hit alib.core')"
    fails=$((fails+1))
  fi
  cache_z2="$(mktemp -d)"
  z_off="$(zrun_off "$cache_z2" || true)"
  z_off_so="$(find "$cache_z2" -name '*.so' | wc -l | tr -d ' ')"
  if echo "$z_off" | grep -q '^7$' \
     && ! echo "$z_off" | grep -q 'queued' \
     && [ "$z_off_so" -ge 1 ]; then
    echo "PASS: (z2) JOLT_AOT_ASYNC=0 compiles in-process and leaves the fasl"; pass=$((pass+1))
  else
    echo "FAIL: (z2) out=$(echo "$z_off" | tail -1) queued=$(echo "$z_off" | grep -c 'queued') so=$z_off_so"
    fails=$((fails+1))
  fi
  # A long-running program that misses again after the worker has gone idle:
  # the worker must still be there to take the job (it does not idle out while
  # its parent lives), and it removes its manifest once the parent is gone.
  printf '(ns alib.late)\n(defn val [] 8)\n' > "$alib/src/alib/late.clj"
  cache_z3="$(mktemp -d)"
  env -u JOLT_AOT_ASYNC JOLT_AOT_CACHE=1 JOLT_CACHE_DIR="$cache_z3" JOLT_QUIET=1 "$async_bin" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'alib/alib {:local/root \"$alib\"}}})
    (require 'alib.core) (Thread/sleep 12000) (require 'alib.late)" >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(find "$cache_z3" -name 'alib.late-*.so' | wc -l | tr -d ' ')" -ge 1 ] \
      && [ "$(find "$cache_z3" -name 'aot-jobs-*.edn' | wc -l | tr -d ' ')" -eq 0 ] && break
    sleep 0.25; i=$((i+1))
  done
  z3_so="$(find "$cache_z3" -name 'alib.late-*.so' | wc -l | tr -d ' ')"
  z3_mf="$(find "$cache_z3" -name 'aot-jobs-*.edn' | wc -l | tr -d ' ')"
  if [ "$z3_so" -ge 1 ] && [ "$z3_mf" -eq 0 ]; then
    echo "PASS: (z3) a miss after the worker idled still compiles; the manifest is removed"; pass=$((pass+1))
  else
    echo "FAIL: (z3) late fasl=$z3_so manifests-left=$z3_mf log=$(cat "$cache_z3"/*/*/aot-jobs-*.log 2>/dev/null | head -3)"
    fails=$((fails+1))
  fi
  rm -rf "$cache_z" "$cache_z2" "$cache_z3" "$alib"
fi

# --- (aa) a warm run reads and hashes each source once (#1161) ---------------
# A dependency's own key is computed while its consumer folds the dep digest, and
# again when the dependency itself loads. The second has to come from the first:
# for a jar root every read is an inflate + CRC + hash of the whole entry. The
# "hash" aot-info line fires once per source actually read for a key.
aa="$tmp/aa"; mkdir -p "$aa/src/exp"
printf '(ns exp.dep)\n(defn v [] 5)\n' > "$aa/src/exp/dep.clj"
printf '(ns exp.top (:require [exp.dep :as d]))\n(defn answer [] (d/v))\n' > "$aa/src/exp/top.clj"
JOLT_PWD="$aa" JOLT_QUIET=1 "$jolt" run "$root/tools/mkjar.clj" "$aa/exp.jar" \
  "exp/dep.clj=$aa/src/exp/dep.clj" "exp/top.clj=$aa/src/exp/top.clj" >/dev/null 2>&1 || true
cache_aa="$(mktemp -d)"
aarun() {
  JOLT_DEBUG=1 JOLT_AOT_CACHE=1 JOLT_AOT_ASYNC=0 JOLT_CACHE_DIR="$cache_aa" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'exp/exp {:local/root \"$1\"}}})
    (require 'exp.top) (println (exp.top/answer))" 2>&1
}
for aaroot in "$aa" "$aa/exp.jar"; do
  rm -rf "$cache_aa"; mkdir -p "$cache_aa"
  aarun "$aaroot" >/dev/null
  aa_warm="$(aarun "$aaroot")"
  aa_dep="$(echo "$aa_warm" | grep -c 'hash exp.dep$' || true)"
  aa_top="$(echo "$aa_warm" | grep -c 'hash exp.top$' || true)"
  if echo "$aa_warm" | grep -q '^5$' && echo "$aa_warm" | grep -q 'hit exp.dep' \
     && [ "$aa_dep" -eq 1 ] && [ "$aa_top" -eq 1 ]; then
    echo "PASS: (aa) warm run from $(basename "$aaroot") hashes each source once"; pass=$((pass+1))
  else
    echo "FAIL: (aa) warm run from $(basename "$aaroot"): out=$(echo "$aa_warm" | tail -1) dep hashed $aa_dep, top hashed $aa_top (want 1 each)"
    fails=$((fails+1))
  fi
done
rm -rf "$cache_aa"

# --- (ab) a reload in the same process still sees an edit --------------------
# The key a load reuses from the dep walk is only good for the source it was read
# from: dropping the namespace from *loaded-libs* and requiring it again after an
# equal-length edit has to read the new source, not serve the old artifact.
ab="$tmp/ab"; mkdir -p "$ab/src/rl"
printf '(ns rl.core)\n(defn v [] 11)\n' > "$ab/src/rl/core.clj"
cache_ab="$(mktemp -d)"
ab_out="$(JOLT_AOT_CACHE=1 JOLT_AOT_ASYNC=0 JOLT_CACHE_DIR="$cache_ab" JOLT_QUIET=1 "$jolt" -e "
  (require 'jolt.deps) (jolt.deps/add-deps {:deps {'rl/rl {:local/root \"$ab\"}}})
  (require 'rl.core) (println (rl.core/v))
  (spit \"$ab/src/rl/core.clj\" \"(ns rl.core)\\n(defn v [] 22)\\n\")
  (dosync (alter @#'clojure.core/*loaded-libs* disj 'rl.core))
  (require 'rl.core) (println (rl.core/v))" 2>&1 | tail -2 | tr '\n' ' ')"
if [ "$ab_out" = "11 22 " ]; then
  echo "PASS: (ab) an in-process reload after an edit loads the edit"; pass=$((pass+1))
else
  echo "FAIL: (ab) got '$ab_out' (want '11 22 ')"; fails=$((fails+1))
fi
rm -rf "$cache_ab"

# --- (ac) a library with data readers is cached in one run -------------------
# Every key folds the digest of each data reader's namespace. Computed before
# that namespace had compiled and written its sidecars, it keyed every artifact
# of the first run on a value no later run reproduces, so the whole project
# missed a second time (and the reader namespace a third). Only a reader
# namespace with requires of its own moves: a leaf's digest has no sidecar.
ac="$tmp/ac"; mkdir -p "$ac/src/rd"
printf '{rd/tag rd.readers/read-tag}\n' > "$ac/src/data_readers.clj"
printf '(ns rd.util)\n(defn label [x] (str "tagged:" x))\n' > "$ac/src/rd/util.clj"
printf '(ns rd.readers (:require [rd.util :as u]))\n(defn read-tag [x] (u/label x))\n' > "$ac/src/rd/readers.clj"
printf '(ns rd.plain)\n(defn v [] 7)\n' > "$ac/src/rd/plain.clj"
cache_ac="$(mktemp -d)"
acrun() {
  JOLT_DEBUG=1 JOLT_AOT_CACHE=1 JOLT_AOT_ASYNC=0 JOLT_CACHE_DIR="$cache_ac" JOLT_QUIET=1 "$jolt" -e "
    (require 'jolt.deps) (jolt.deps/add-deps {:deps {'rd/rd {:local/root \"$ac\"}}})
    (require 'rd.plain) (println (rd.plain/v))" 2>&1
}
# That includes a namespace the reader namespace itself requires: it compiles
# while the reader namespace's own compile is open above it, before that
# namespace's sidecars exist, so its artifact is keyed once they do.
acrun >/dev/null
ac_warm="$(acrun)"
if echo "$ac_warm" | grep -q '^7$' && echo "$ac_warm" | grep -q 'hit rd.plain' \
   && echo "$ac_warm" | grep -q 'hit rd.readers' && echo "$ac_warm" | grep -q 'hit rd.util' \
   && ! echo "$ac_warm" | grep -q 'miss '; then
  echo "PASS: (ac) a project with data readers hits on its second run"; pass=$((pass+1))
else
  echo "FAIL: (ac) second run: $(echo "$ac_warm" | grep -E 'hit |miss ' | tr '\n' ' ')"
  fails=$((fails+1))
fi
rm -rf "$cache_ac"

# Phase 4 (cold-vs-warm speedup) lives in aot-cache-perf.sh — a timing
# measurement doesn't belong in this deterministic correctness gate.

echo ""
echo "aot-cache smoke: $pass passed, $fails failed"
rm -rf "$cache" "$tmp"
[ "$fails" -eq 0 ]
