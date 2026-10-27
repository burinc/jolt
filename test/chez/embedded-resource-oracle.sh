#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
if ! command -v jar >/dev/null 2>&1 || ! command -v javap >/dev/null 2>&1 || ! command -v clojure >/dev/null 2>&1; then
  printf 'embedded resource JDK/oracle skipped: jar, javap, and clojure are required\n'
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
resources="test/chez/embedded-java-app/resources"
jar="$work/embedded-resource-oracle.jar"
(cd "$resources" && jar --create --file "$jar" --manifest META-INF/MANIFEST.MF .)
clojure -Sdeps '{:paths ["test/chez"]}' -M -e "(require 'embedded-resource-oracle) (embedded-resource-oracle/-main \"$jar\")" > "$work/jvm.edn"
jolt="${JOLT_BIN:-target/release/jolt}"
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac
app="$root/test/chez/embedded-java-app"
JOLT_PWD="$app" "$joltabs" build -m app.core -o "$work/app-bin" >/dev/null 2>&1
"$work/app-bin" --oracle > "$work/jolt.edn"
diff -u "$work/jvm.edn" "$work/jolt.edn"
printf 'embedded resource JDK/Jolt oracle and signature audit passed\n'
