#!/bin/sh
# deps-no-unzip-smoke.sh — Maven dependencies load from their jars in place,
# with no unzip on PATH and no extraction (jolt issues #988 and #1005). A jar
# on the roots is read through its central directory (host/chez/java/zip-file.ss),
# so:
#   1. a :mvn/version dependency from an offline local Maven repository, whose
#      jar tools/mkjar.clj writes, resolves and loads with an empty PATH; the
#      root IS the jar, nothing is extracted beside it, a resource in the jar
#      resolves to a jar:file: URL that slurps, and *file* names the entry;
#   2. a jar that is not a zip fails resolution loudly and caches nothing;
#   3. a jar cut short inside its central directory fails the same way;
#   4. a jar whose entry fails its CRC-32 resolves (its directory is whole), and
#      the require of that entry fails with a ZipException that names the jar,
#      as reading a damaged entry does;
#   5. a :local/root jar is its own root too, with no extraction cache.
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
printf '(ns nounzip.core)\n(def answer 42)\n(def here *file*)\n' > "$tmp/core.clj"
printf '{:from "the jar"}\n' > "$tmp/data.edn"
jar1="$m2/org/example/nounzip/1.0.0/nounzip-1.0.0.jar"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" \
  "$jar1" "nounzip/core.clj=$tmp/core.clj" "nounzip/data.edn=$tmp/data.edn" >/dev/null \
  || { echo "  FAIL: 1: mkjar did not write the jar" >&2; fail=$((fail+1)); }
mkdir -p "$tmp/proj/src/app"
printf '{:paths ["src"] :deps {org.example/nounzip {:mvn/version "1.0.0"}}}\n' > "$tmp/proj/deps.edn"
cat > "$tmp/proj/src/app/core.clj" <<'EOF'
(ns app.core (:require [nounzip.core :as n] [clojure.java.io :as io]))
(defn -main [& _]
  (println "answer" n/answer)
  (println "file" n/here)
  (let [u (io/resource "nounzip/data.edn")]
    (println "url" (str u))
    (println "data" (pr-str (read-string (slurp u))))
    (println "stream" (pr-str (slurp (io/input-stream u))))
    (println "missing" (pr-str (io/resource "nounzip/absent.edn")))))
EOF
out1="$(PATH="$empty" JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app.core 2>&1)"
yn "1: resolves and loads with an empty PATH" \
   "$(printf '%s\n' "$out1" | grep -qx 'answer 42' && echo yes || echo no)"
yn "1: *file* names the entry inside the jar" \
   "$(printf '%s\n' "$out1" | grep -qx "file jar:file:$jar1!/nounzip/core.clj" && echo yes || echo no)"
yn "1: a resource in the jar resolves to its jar:file: URL" \
   "$(printf '%s\n' "$out1" | grep -qx "url jar:file:$jar1!/nounzip/data.edn" && echo yes || echo no)"
yn "1: the resource slurps through its URL" \
   "$(printf '%s\n' "$out1" | grep -qx 'data {:from "the jar"}' && echo yes || echo no)"
yn "1: the resource opens as a stream" \
   "$(printf '%s\n' "$out1" | grep -qx 'stream "{:from \\"the jar\\"}\\n"' && echo yes || echo no)"
yn "1: an absent resource is nil" \
   "$(printf '%s\n' "$out1" | grep -qx 'missing nil' && echo yes || echo no)"
yn "1: nothing was extracted beside the jar" \
   "$([ ! -e "$jar1.jolt" ] && [ -z "$(find "$m2" -name '.jolt-ok' -o -name '.jolt-extract-*')" ] && echo yes || echo no)"
out1p="$(PATH="$empty" JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" path 2>&1)"
yn "1: the jar itself is on the roots" \
   "$(printf '%s\n' "$out1p" | grep -qF "$jar1" && echo yes || echo no)"
yn "1: a second run hits the classpath cache and still loads" \
   "$(PATH="$empty" JOLT_PWD="$tmp/proj" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app.core 2>&1 | grep -qx 'answer 42' && echo yes || echo no)"

# 2. a jar that is not a zip fails loudly and caches nothing
pom broken
printf 'this is not a zip file\n' > "$m2/org/example/broken/1.0.0/broken-1.0.0.jar"
mkdir -p "$tmp/proj2/src/app2"
printf '{:paths ["src"] :deps {org.example/broken {:mvn/version "1.0.0"}}}\n' > "$tmp/proj2/deps.edn"
printf '(ns app2.core)\n(defn -main [& _] (println "ran"))\n' > "$tmp/proj2/src/app2/core.clj"
out2="$(PATH="$empty" JOLT_PWD="$tmp/proj2" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app2.core 2>&1)"
yn "2: a jar that is not a zip fails resolution loudly" \
   "$(printf '%s' "$out2" | grep -q 'not a whole zip archive' && echo yes || echo no)"
yn "2: the message names the jar" \
   "$(printf '%s' "$out2" | grep -q 'broken-1.0.0.jar' && echo yes || echo no)"
yn "2: nothing cached" \
   "$([ ! -d "$tmp/proj2/.jolt/cpcache" ] && echo yes || echo no)"

# 3. a jar cut short inside its central directory: the END record is gone
pom cut
printf '(ns cut.core)\n(def answer 1)\n' > "$tmp/cut.clj"
cutjar="$m2/org/example/cut/1.0.0/cut-1.0.0.jar"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" "$cutjar" "cut/core.clj=$tmp/cut.clj" >/dev/null \
  || { echo "  FAIL: 3: mkjar did not write the jar" >&2; fail=$((fail+1)); }
size="$(wc -c < "$cutjar" | tr -d ' ')"
head -c "$((size - 30))" "$cutjar" > "$cutjar.tmp" && mv "$cutjar.tmp" "$cutjar"
mkdir -p "$tmp/proj3/src/app3"
printf '{:paths ["src"] :deps {org.example/cut {:mvn/version "1.0.0"}}}\n' > "$tmp/proj3/deps.edn"
printf '(ns app3.core)\n(defn -main [& _] (println "ran"))\n' > "$tmp/proj3/src/app3/core.clj"
out3="$(PATH="$empty" JOLT_PWD="$tmp/proj3" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app3.core 2>&1)"
yn "3: a cut jar fails resolution loudly" \
   "$(printf '%s' "$out3" | grep -q 'not a whole zip archive' && echo yes || echo no)"
yn "3: nothing cached" \
   "$([ ! -d "$tmp/proj3/.jolt/cpcache" ] && echo yes || echo no)"

# 4. a jar whose entry fails its CRC-32: the directory is whole, so it
# resolves; the require reads the entry and refuses it. mkjar writes a stored
# entry: its data follows a 30-byte local header and the entry's name, and one
# byte changed there leaves the header's CRC-32 behind.
pom midfail
entry=midfail/core.clj
printf '(ns midfail.core)\n(def answer 1)\n' > "$tmp/mid.clj"
midjar="$m2/org/example/midfail/1.0.0/midfail-1.0.0.jar"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" "$midjar" "$entry=$tmp/mid.clj" >/dev/null \
  || { echo "  FAIL: 4: mkjar did not write the jar" >&2; fail=$((fail+1)); }
[ -s "$midjar" ] || { echo "  FAIL: 4: no jar to damage" >&2; fail=$((fail+1)); }
printf 'X' | dd of="$midjar" bs=1 seek=$((30 + ${#entry})) conv=notrunc 2>/dev/null
mkdir -p "$tmp/proj4/src/app4"
printf '{:paths ["src"] :deps {org.example/midfail {:mvn/version "1.0.0"}}}\n' > "$tmp/proj4/deps.edn"
printf '(ns app4.core (:require [midfail.core]))\n(defn -main [& _] (println "ran"))\n' > "$tmp/proj4/src/app4/core.clj"
out4="$(PATH="$empty" JOLT_PWD="$tmp/proj4" JOLT_QUIET=1 JOLT_MAVEN_REPOSITORY="$m2" "$JOLT" run -m app4.core 2>&1)"
yn "4: the damaged entry is refused when it is required" \
   "$(printf '%s' "$out4" | grep -q 'invalid entry CRC' && echo yes || echo no)"
yn "4: the refusal names the jar and the entry" \
   "$(printf '%s' "$out4" | grep -q "midfail-1.0.0.jar!/$entry" && echo yes || echo no)"
yn "4: the program did not run" \
   "$(printf '%s\n' "$out4" | grep -qx 'ran' && echo no || echo yes)"

# 5. a :local/root jar is its own root
mkdir -p "$tmp/proj5/src/app5"
printf '(ns locjar.core)\n(def y 7)\n' > "$tmp/loc.clj"
JOLT_PWD="$tmp" JOLT_QUIET=1 "$JOLT" run "$root/tools/mkjar.clj" "$tmp/proj5/libj.jar" "locjar/core.clj=$tmp/loc.clj" >/dev/null \
  || { echo "  FAIL: 5: mkjar did not write the jar" >&2; fail=$((fail+1)); }
printf '{:paths ["src"] :deps {local/jarlib {:local/root "libj.jar"}}}\n' > "$tmp/proj5/deps.edn"
printf '(ns app5.core (:require [locjar.core :as j]))\n(defn -main [& _] (println "jarlib" j/y))\n' > "$tmp/proj5/src/app5/core.clj"
out5="$(PATH="$empty" JOLT_PWD="$tmp/proj5" JOLT_QUIET=1 HOME="$tmp/home5" "$JOLT" run -m app5.core 2>&1)"
yn "5: a :local/root jar loads in place" \
   "$(printf '%s\n' "$out5" | tail -1 | grep -qx 'jarlib 7' && echo yes || echo no)"
yn "5: no extraction cache under HOME" \
   "$([ ! -d "$tmp/home5/.jolt/jarlibs" ] && echo yes || echo no)"

echo "deps-no-unzip-smoke: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
