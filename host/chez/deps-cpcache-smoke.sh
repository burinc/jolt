#!/bin/sh
# deps-cpcache-smoke.sh — the resolved-roots cache (.jolt/cpcache).
#
# A warm `jolt -e nil` in a project with deps re-expands the dependency graph
# (POM parsing, version selection, gitlib probing) on every run. R2 of the
# startup plan caches the FINAL resolution under the project's .jolt/ dir,
# keyed on a content hash of the inputs — the project deps.edn bytes, the user
# deps.edn (or an explicit absent/skipped marker), JOLT_NO_USER_DEPS, the ACTIVE
# alias set, the runtime version, and every :local/root dep's deps.edn bytes —
# so a warm run skips the expansion. This gates that cache through the real CLI
# over a throwaway OFFLINE project (a :local/root lib + :paths; no network):
#   1. first run misses, second run hits;
#   2. touching the PROJECT deps.edn content -> miss, then hit again;
#   3. editing the LOCAL DEP's deps.edn -> miss (the :local/root fold-in works);
#   4. an alias flag selects a different key (miss); the no-alias entry still hits;
#   5. deleting a cached-referenced path -> re-expansion (miss), never an error.
# Also asserts the dev bin/jolt (JOLT_AOT_CACHE=0) never caches — same gate as
# the AOT namespace cache, so source-mode dev shows neither line.
#
# JOLT_BIN overrides the binary under test (defaults to bin/jolt source mode);
# the gate runs it through target/release/jolt (make testbin).
set -u
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
JOLT="${JOLT_BIN:-bin/jolt}"
pass=0; fail=0
# Hermetic: never read the developer's real ~/.clojure/deps.edn, and leave the
# binary's cache gate at its default (ON) regardless of the dev environment.
export JOLT_NO_USER_DEPS=1
unset JOLT_AOT_CACHE
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

hit()  { printf '%s' "$1" | grep -q '\[jolt.deps\] cpcache hit'; }
miss() { printf '%s' "$1" | grep -q '\[jolt.deps\] cpcache miss'; }
nocp() { ! printf '%s' "$1" | grep -q '\[jolt.deps\] cpcache'; }

# label, then a yes/no word
yn() { if [ "$2" = "yes" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1" >&2; fi; }

# throwaway project: an app that depends on a tiny local lib. Fully offline.
mkdir -p "$tmp/proj/src/app" "$tmp/proj/dev" "$tmp/lib/src/libx"
cat > "$tmp/proj/deps.edn" <<'EOF'
{:paths ["src"]
 :aliases {:dbg {}}
 :deps {local/lib {:local/root "../lib"}}}
EOF
cat > "$tmp/proj/src/app/core.clj" <<'EOF'
(ns app.core (:require [libx.core :as l]))
(defn -main [& _] (println "app+lib" l/x))
EOF
cat > "$tmp/proj/dev/extra.clj" <<'EOF'
(ns extra)
EOF
cat > "$tmp/lib/deps.edn" <<'EOF'
{:paths ["src"]}
EOF
cat > "$tmp/lib/src/libx/core.clj" <<'EOF'
(ns libx.core)
(def x 42)
EOF

run() { JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_DEBUG=1 "$JOLT" "$@" 2>&1; }

# 1. first run misses, second run hits, and a cached run still loads the lib.
out1="$(run -e nil)"; out2="$(run -e nil)"
yn "1: first run is a miss" "$(miss "$out1" && echo yes || echo no)"
yn "1: second run is a hit" "$(hit "$out2" && echo yes || echo no)"
yn "1: cached run loads the lib" "$(JOLT_PWD="$tmp/proj" JOLT_QUIET=1 "$JOLT" run -m app.core 2>&1 | tail -1 | grep -q 'app+lib 42' && echo yes || echo no)"

# 2. touching the PROJECT deps.edn content (add a key) -> miss, then hit again.
printf '{:paths ["src"] :aliases {:dbg {}} :deps {local/lib {:local/root "../lib"}} :tasks {}}\n' > "$tmp/proj/deps.edn"
out3="$(run -e nil)"; out4="$(run -e nil)"
yn "2: project-deps edit misses" "$(miss "$out3" && echo yes || echo no)"
yn "2: then hits again" "$(hit "$out4" && echo yes || echo no)"

# 3. editing the LOCAL DEP's deps.edn -> miss (the :local/root fold-in works).
printf '{:paths ["src"] :extra {:edit 1}}\n' > "$tmp/lib/deps.edn"
out5="$(run -e nil)"; out6="$(run -e nil)"
yn "3: local-dep edit misses" "$(miss "$out5" && echo yes || echo no)"
yn "3: then hits again" "$(hit "$out6" && echo yes || echo no)"

# 4. an alias flag selects a different key (miss); the no-alias entry still hits,
#    and the aliased entry hits on its second run.
out7="$(run -A:dbg -e nil)"; out8="$(run -e nil)"; out9="$(run -A:dbg -e nil)"
yn "4: aliased run misses (different key)" "$(miss "$out7" && echo yes || echo no)"
yn "4: no-alias run still hits" "$(hit "$out8" && echo yes || echo no)"
yn "4: second aliased run hits" "$(hit "$out9" && echo yes || echo no)"

# 5. deleting a cached-referenced path -> re-expansion (miss), never an error.
#    Re-establish a clean hit, then prune the local dep's source root.
out10="$(run -e nil)"; yn "5: baseline hit before deletion" "$(hit "$out10" && echo yes || echo no)"
rm -rf "$tmp/lib/src"
out11="$(run -e nil)"
yn "5: deleted dep root -> miss" "$(miss "$out11" && echo yes || echo no)"
yn "5: ...and no error/stacktrace" "$(printf '%s' "$out11" | grep -qi 'exception\|stacktrace\|error building' && echo no || echo yes)"

# 6. a resolution that FAILED to materialize an artifact is never cached.
#    A :local/root jar that cannot be extracted (corrupt zip — same machinery
#    as a missing unzip or a full disk) must fail resolution loudly, not
#    silently drop the root; and once the jar is fixed IN PLACE (the cache
#    material doesn't fold jar bytes) the next run must resolve it, which it
#    can only do if the degraded result was never written.
if command -v python3 >/dev/null 2>&1; then
  export JOLT_JARLIBS="$tmp/jarlibs"
  mkdir -p "$tmp/proj2/src/app2"
  cat > "$tmp/proj2/deps.edn" <<'EOF'
{:paths ["src"]
 :deps {local/jarlib {:local/root "libj.jar"}}}
EOF
  cat > "$tmp/proj2/src/app2/core.clj" <<'EOF'
(ns app2.core (:require [libj.core :as j]))
(defn -main [& _] (println "jarlib" j/y))
EOF
  printf 'this is not a zip file\n' > "$tmp/proj2/libj.jar"
  run2() { JOLT_PWD="$tmp/proj2" JOLT_QUIET=1 JOLT_DEBUG=1 "$JOLT" "$@" 2>&1; }
  out12="$(run2 -e nil)"
  yn "6: corrupt jar fails resolution loudly" "$(printf '%s' "$out12" | grep -qi 'could not be resolved' && echo yes || echo no)"
  python3 -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("libj/core.clj","(ns libj.core) (def y 7)"); z.close()' "$tmp/proj2/libj.jar"
  out13="$(JOLT_PWD="$tmp/proj2" JOLT_QUIET=1 "$JOLT" run -m app2.core 2>&1)"
  yn "6: fixed jar resolves and loads" "$(printf '%s' "$out13" | tail -1 | grep -q 'jarlib 7' && echo yes || echo no)"
  unset JOLT_JARLIBS
else
  echo "  (skip: python3 not available for case 6)" >&2
fi

# 7. the env knobs that move where Maven artifacts live select different keys:
#    a run with JOLT_MAVEN_REPOSITORY / JOLT_MVNLIBS /
#    GRENADINE_MAVEN_REPOSITORY set
#    must not share the unset run's entry (its cached roots would point into
#    the other location).
# (direct invocations, not run(): an env prefix on a shell FUNCTION call
# persists after the call in dash, which would contaminate later cases)
runenv() { JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_DEBUG=1 env "$@" "$JOLT" -e nil 2>&1; }
# case 5 deleted the lib's src root, so re-establish it and a warm entry first.
mkdir -p "$tmp/lib/src/libx"
printf '(ns libx.core)\n(def x 42)\n' > "$tmp/lib/src/libx/core.clj"
run -e nil >/dev/null 2>&1
out14="$(run -e nil)"; yn "7: baseline hit" "$(hit "$out14" && echo yes || echo no)"
out15="$(runenv JOLT_MAVEN_REPOSITORY="$tmp/alt-repo")"
yn "7: JOLT_MAVEN_REPOSITORY change misses" "$(miss "$out15" && echo yes || echo no)"
out16="$(runenv JOLT_MVNLIBS="$tmp/alt-mvnlibs")"
yn "7: JOLT_MVNLIBS change misses" "$(miss "$out16" && echo yes || echo no)"
out17="$(runenv GRENADINE_MAVEN_REPOSITORY="$tmp/alt-gren")"
yn "7: GRENADINE_MAVEN_REPOSITORY change misses" "$(miss "$out17" && echo yes || echo no)"

# Dev posture: bin/jolt exports JOLT_AOT_CACHE=0, so the cache is OFF — neither
# hit nor miss line appears, same gate as the AOT namespace cache. Skipped (not
# failed) if bin/jolt can't run here.
if "$root/bin/jolt" -e nil >/dev/null 2>&1; then
  devout="$(JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_DEBUG=1 "$root/bin/jolt" -e nil 2>&1)"
  yn "dev: bin/jolt shows no cpcache line" "$(nocp "$devout" && echo yes || echo no)"
else
  echo "  (skip: bin/jolt not runnable here)" >&2
fi

echo "deps-cpcache smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
