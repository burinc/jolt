#!/bin/sh
# aot-cache-source-path smoke: a cache hit must report the source path THIS load
# found the namespace at, the same answer an uncached load gives.
#
# A namespace's path is baked into its cached artifact at compile time: the var's
# :file metadata, and any *file* a macro read while expanding. The path is spelled
# the way the classpath root is, so :paths ["src"] gives "./src/mylib/where.clj"
# and an absolute root gives an absolute path. The cache was keyed by namespace and
# source content only, so the same source reached through a different root
# replayed the first load's spelling. From another working directory that is a
# path to nothing:
#
#   cwd .../elsewhere, root /abs/proj/src
#   before:  {:file "./src/mylib/where.clj"}           <- no such file from here
#   after:   {:file "/abs/proj/src/mylib/where.clj"}   <- what JOLT_AOT_CACHE=0 says
#
# Each run prints the var's :file and a *file* captured by a macro, and the check
# compares a warm run against an uncached run from the same place.

set -e

pass=0
fails=0
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"

# The built binary, not bin/jolt: bin/jolt cd's to the repo and passes the project
# dir as JOLT_PWD, so its roots are already absolute and the relative spelling
# never arises.
jolt="$root/target/release/jolt"
cache="$(mktemp -d)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
mkdir -p "$tmp/proj/src/mylib" "$tmp/elsewhere"

cat > "$tmp/proj/src/mylib/where.clj" <<'EOF'
(ns mylib.where)
(defmacro compiled-in [] *file*)
(defn f [] 1)
(def baked (compiled-in))
EOF
echo '{:paths ["src"]}' > "$tmp/proj/deps.edn"
echo '{}' > "$tmp/elsewhere/deps.edn"

probe='(require (quote mylib.where))
       (println (:file (meta (var mylib.where/f))))
       (println mylib.where/baked)'

# $1 = cwd, $2 = JOLT_AOT_CACHE, rest = extra jolt args before -M
run_in() {
  dir="$1"; aot="$2"; shift 2
  (cd "$dir" && JOLT_AOT_CACHE="$aot" JOLT_CACHE_DIR="$cache" JOLT_QUIET=1 \
     "$jolt" "$@" -M -e "$probe" 2>&1) || true
}

abs_deps="{:paths [\"$tmp/proj/src\"]}"

# Two lines of output, both must name a file that exists from DIR. $1 = label,
# $2 = dir, $3 = output, $4 = the uncached output from the same dir.
check() {
  label="$1"; dir="$2"; out="$3"; want="$4"
  if [ "$out" = "$want" ]; then
    echo "PASS: ($label) matches the uncached load"; pass=$((pass+1))
  else
    echo "FAIL: ($label) differs from the uncached load"
    echo "  got:";  printf '%s\n' "$out"  | sed 's/^/    /'
    echo "  want:"; printf '%s\n' "$want" | sed 's/^/    /'
    fails=$((fails+1))
  fi
  n=0
  for p in $out; do
    n=$((n+1))
    if (cd "$dir" && [ -f "$p" ]); then
      echo "PASS: ($label.$n) $p exists from $(basename "$dir")"; pass=$((pass+1))
    else
      echo "FAIL: ($label.$n) $p does not exist from $(basename "$dir")"; fails=$((fails+1))
    fi
  done
}

want_proj="$(run_in "$tmp/proj" 0)"
want_else="$(run_in "$tmp/elsewhere" 0 -Sdeps "$abs_deps")"

# (a) cold, in the project: the miss that fills the cache
check a "$tmp/proj" "$(run_in "$tmp/proj" 1)" "$want_proj"
# (b) same source, other directory, absolute root: used to hit (a)'s artifact
check b "$tmp/elsewhere" "$(run_in "$tmp/elsewhere" 1 -Sdeps "$abs_deps")" "$want_else"
# (c) back in the project, warm: its own artifact still answers
check c "$tmp/proj" "$(run_in "$tmp/proj" 1)" "$want_proj"

echo
echo "aot-cache-source-path smoke: $pass passed, $fails failed"
rm -rf "$cache" "$tmp"
[ "$fails" -eq 0 ]
