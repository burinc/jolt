#!/bin/sh
# ffi-load-failure smoke (issue #1127): a native library that is ON DISK but
# fails to load — because a library IT depends on is missing — was reported as
# "not found — tried [libssl-3-x64.dll]" plus "(a task may build it)", with the
# file sitting right beside jolt.exe. The loader's own reason was thrown away.
#
# The fixture is a library linked against a second one, with the second
# deleted: the first is there, and cannot load. Every report path has to name
# the file it found and not call it missing, and a genuinely absent candidate
# has to keep reading as not found (and, from a task, as buildable).
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
jolt="${JOLT_BIN:-bin/jolt}"
case "$jolt" in /*) ;; *) jolt="$root/$jolt" ;; esac

if ! command -v cc >/dev/null 2>&1; then
  echo "ffi-load-failure smoke: skipped (no C compiler)"
  exit 0
fi

case "$(uname -s)" in
  Darwin) soext="dylib"; shared="-dynamiclib" ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "ffi-load-failure smoke: skipped (covered under Wine, tools/wine)"
    exit 0 ;;
  *)      soext="so";    shared="-shared -fPIC" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/dep.c" <<'EOF'
int dep_answer(void) { return 40; }
EOF
cat > "$work/top.c" <<'EOF'
extern int dep_answer(void);
int top_answer(void) { return dep_answer() + 2; }
EOF
# shellcheck disable=SC2086
cc $shared "$work/dep.c" -o "$work/libdep.$soext"
# shellcheck disable=SC2086
cc $shared "$work/top.c" -L"$work" -ldep -o "$work/libtop.$soext" -Wl,-rpath,"$work"
rm "$work/libdep.$soext"

fails=0
report() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- load-library names the file and the loader's reason -----------------------
cat > "$work/direct.clj" <<EOF
(ns direct (:require [jolt.ffi :as ffi]))
(println "LOADED" (ffi/load-native "$work/libtop.$soext"))
(try (ffi/load-library "$work/libtop.$soext")
     (catch Exception e (println "ERR" (ex-message e))))
(println "NOTE-ABSENT" (pr-str (ffi/load-failure-note ["$work/libnothere.$soext"])))
EOF
out="$("$jolt" run "$work/direct.clj" 2>&1)" || { echo "$out"; report "direct fixture did not run"; }
echo "$out" | grep -q "LOADED false" \
  || report "a library whose dependency is missing loaded (got: $(echo "$out" | grep LOADED || echo none))"
echo "$out" | grep "^ERR" | grep -q "libtop.$soext is there but did not load" \
  || report "load-library did not say the library is there (got: $(echo "$out" | grep ERR || echo none))"
echo "$out" | grep "^ERR" | grep -q "libdep" \
  || report "load-library dropped the loader's reason naming the missing dependency"
echo "$out" | grep -q "NOTE-ABSENT nil" \
  || report "an absent candidate produced a failure note (got: $(echo "$out" | grep NOTE-ABSENT || echo none))"

# --- a project :jolt/native ----------------------------------------------------
mkdir -p "$work/proj/src/app"
cat > "$work/proj/deps.edn" <<EOF
{:paths ["src"]
 :jolt/native [{:name "top" :darwin ["$work/libtop.$soext"] :linux ["$work/libtop.$soext"]}]
 :tasks {hello {:task (println "TASK ran")}}}
EOF
cat > "$work/proj/src/app/core.clj" <<'EOF'
(ns app.core)
(defn -main [] (println "MAIN ran"))
EOF
run_out="$(cd "$work/proj" && "$jolt" run -m app.core 2>&1 || true)"
echo "$run_out" | grep -q "required native library top did not load — .*libtop.$soext is there" \
  || report "run did not report the library as present-but-unloadable (got: $(echo "$run_out" | head -3))"
echo "$run_out" | grep -q "not found" \
  && report "run still reports a library on disk as not found"
task_out="$(cd "$work/proj" && "$jolt" hello 2>&1 || true)"
echo "$task_out" | grep -q "warning: required native library top did not load" \
  || report "task warning did not say the library failed to load (got: $(echo "$task_out" | head -3))"
echo "$task_out" | grep -q "a task may build it" \
  && report "task warning offers to build a library that is already on disk"
echo "$task_out" | grep -q "TASK ran" || report "the task did not run past the warning"

# --- a candidate that really is absent is still "not found", still buildable ---
cat > "$work/proj/deps.edn" <<EOF
{:paths ["src"]
 :jolt/native [{:name "gone" :darwin ["$work/libgone.$soext"] :linux ["$work/libgone.$soext"]}]
 :tasks {hello {:task (println "TASK ran")}}}
EOF
task_out2="$(cd "$work/proj" && "$jolt" hello 2>&1 || true)"
echo "$task_out2" | grep -q "required native library gone not found .*(a task may build it)" \
  || report "an absent library lost its not-found/buildable warning (got: $(echo "$task_out2" | head -3))"

if [ "$fails" -eq 0 ]; then
  echo "ffi-load-failure smoke: passed"
  exit 0
fi
echo "ffi-load-failure smoke: $fails failure(s)" >&2
exit 1
