#!/bin/sh
# deps-no-unzip-smoke.sh — dependency resolution with no unzip on PATH (jolt
# issue #988). jolt.deps extracts a jar in process, through
# jolt.host/extract-zip!, so:
#   1. a :mvn/version dependency from an offline local Maven repository, whose
#      jar tools/mkjar.clj writes, resolves and loads with an empty PATH, and
#      its extraction has the .jolt-ok marker;
#   2. a jar that is not a zip fails resolution loudly, and leaves no .jolt-ok
#      marker;
#   3. a jar whose entry fails its CRC-32, which fails after a temporary file
#      exists, leaves no .jolt-ok marker, no temporary file, no entry and no
#      cpcache;
#   4. host/gambit defines no jolt.host/extract-zip!, so a call there raises the
#      unbound-var error: an absent capability raises (CONTRIBUTING.md, "Scheme
#      backends").
#
# JOLT_BIN is a built jolt, which needs no program on PATH; the gate runs
# target/release/jolt (make testbin).
#   JOLT_BIN=target/release/jolt sh host/chez/deps-no-unzip-smoke.sh
set -u
root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1
JOLT="${JOLT_BIN:-target/release/jolt}"
case "$JOLT" in /*) ;; *) JOLT="$root/$JOLT" ;; esac
pass=0; fail=0
# Hermetic: no user deps.edn, and the default Maven layout.
export JOLT_NO_USER_DEPS=1
unset JOLT_MVNLIBS GRENADINE_MAVEN_REPOSITORY
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# label, then a yes/no word
yn() { if [ "$2" = "yes" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL: $1" >&2; fi; }

m2="$tmp/m2"
empty="$tmp/empty-path"
mkdir -p "$empty"

# A POM for org.example/NAME 1.0.0 in the local repository.
pom() {
  mkdir -p "$m2/org/example/$1/1.0.0"
  printf '<project><modelVersion>4.0.0</modelVersion><groupId>org.example</groupId><artifactId>%s</artifactId><version>1.0.0</version></project>\n' "$1" \
    > "$m2/org/example/$1/1.0.0/$1-1.0.0.pom"
}

# 1. a jar from the local repository resolves and loads with an empty PATH
pom nounzip
printf '(ns nounzip.core)\n(def answer 42)\n' > "$tmp/core.clj"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" \
  "$m2/org/example/nounzip/1.0.0/nounzip-1.0.0.jar" "nounzip/core.clj=$tmp/core.clj" >/dev/null \
  || { echo "  FAIL: 1: mkjar did not write the jar" >&2; fail=$((fail+1)); }
mkdir -p "$tmp/proj/src/app"
printf '{:paths ["src"] :deps {org.example/nounzip {:mvn/version "1.0.0"}}}\n' > "$tmp/proj/deps.edn"
printf '(ns app.core (:require [nounzip.core :as n]))\n(defn -main [& _] (println "answer" n/answer))\n' \
  > "$tmp/proj/src/app/core.clj"
out1="$(PATH="$empty" JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app.core 2>&1)"
yn "1: resolves and loads with an empty PATH" \
   "$(printf '%s\n' "$out1" | tail -1 | grep -qx 'answer 42' && echo yes || echo no)"
jdir="$m2/org/example/nounzip/1.0.0/nounzip-1.0.0.jar.jolt"
yn "1: the extraction has its .jolt-ok marker" \
   "$([ -f "$jdir/.jolt-ok" ] && [ -f "$jdir/nounzip/core.clj" ] && echo yes || echo no)"

# 2. a jar that is not a zip fails loudly and leaves nothing behind
pom broken
printf 'this is not a zip file\n' > "$m2/org/example/broken/1.0.0/broken-1.0.0.jar"
mkdir -p "$tmp/proj2/src/app2"
printf '{:paths ["src"] :deps {org.example/broken {:mvn/version "1.0.0"}}}\n' > "$tmp/proj2/deps.edn"
printf '(ns app2.core)\n(defn -main [& _] (println "ran"))\n' > "$tmp/proj2/src/app2/core.clj"
out2="$(PATH="$empty" JOLT_PWD="$tmp/proj2" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app2.core 2>&1)"
yn "2: a jar that is not a zip fails resolution loudly" \
   "$(printf '%s' "$out2" | grep -q 'could not be extracted' && echo yes || echo no)"
yn "2: no .jolt-ok marker" \
   "$([ ! -e "$m2/org/example/broken/1.0.0/broken-1.0.0.jar.jolt/.jolt-ok" ] && echo yes || echo no)"

# 3. a jar whose entry fails its CRC-32 fails while the entry is being written,
# so a temporary file exists when the extraction gives up. mkjar writes a stored
# entry: its data follows a 30-byte local header and the entry's name, and one
# byte changed there leaves the header's CRC-32 behind.
pom midfail
entry=midfail/core.clj
printf '(ns midfail.core)\n(def answer 1)\n' > "$tmp/mid.clj"
midjar="$m2/org/example/midfail/1.0.0/midfail-1.0.0.jar"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" "$midjar" "$entry=$tmp/mid.clj" >/dev/null \
  || { echo "  FAIL: 3: mkjar did not write the jar" >&2; fail=$((fail+1)); }
# dd writes a file that is not there, so the jar must be there first: without it
# the archive would be refused at its end record, which case 2 already covers.
[ -s "$midjar" ] || { echo "  FAIL: 3: no jar to damage" >&2; fail=$((fail+1)); }
printf 'X' | dd of="$midjar" bs=1 seek=$((30 + ${#entry})) conv=notrunc 2>/dev/null
mkdir -p "$tmp/proj3/src/app3"
printf '{:paths ["src"] :deps {org.example/midfail {:mvn/version "1.0.0"}}}\n' > "$tmp/proj3/deps.edn"
printf '(ns app3.core)\n(defn -main [& _] (println "ran"))\n' > "$tmp/proj3/src/app3/core.clj"
out3="$(PATH="$empty" JOLT_PWD="$tmp/proj3" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app3.core 2>&1)"
yn "3: an entry that fails its CRC-32 fails resolution loudly" \
   "$(printf '%s' "$out3" | grep -q 'could not be extracted' && echo yes || echo no)"
yn "3: no .jolt-ok marker" \
   "$([ ! -e "$midjar.jolt/.jolt-ok" ] && echo yes || echo no)"
yn "3: no temporary file" \
   "$([ -z "$(find "$m2" -name '.jolt-extract-*')" ] && echo yes || echo no)"
yn "3: no entry file" \
   "$([ ! -e "$midjar.jolt/$entry" ] && echo yes || echo no)"
# extract-zip! makes the entry's directory before it opens the temporary file,
# so this says the extraction reached the entry and failed there.
yn "3: the extraction reached the entry" \
   "$([ -d "$midjar.jolt/${entry%/*}" ] && echo yes || echo no)"
yn "3: nothing cached" \
   "$([ ! -d "$tmp/proj3/.jolt/cpcache" ] && echo yes || echo no)"

# 4. Gambit has no extract-zip! to call
yn "4: host/gambit defines no jolt.host/extract-zip!" \
   "$([ -d host/gambit ] && ! grep -rqF '"extract-zip!"' host/gambit && echo yes || echo no)"

echo "deps-no-unzip-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
