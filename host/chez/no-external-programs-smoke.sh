#!/bin/sh
# no-external-programs smoke: the runtime answers about its own process without
# running a program from PATH.
#
# jolt is meant to run with nothing installed beyond git for git deps (jolt
# issue #988). (System/getenv) as a map, the environment a ProcessBuilder seeds
# its child with, and the os.version property used to come from subprocesses:
# `env -0` and `sw_vers` / `uname -r`, spawned through /bin/sh. With an empty
# PATH the shell finds none of them, so the map came back empty, a child got an
# empty environment, and os.version was nil; on Windows, where the shell is
# cmd.exe, `env` is not a command at all. Each answer is read through the C
# runtime now (environ, sysctl, uname(2)), so it must hold with PATH empty.
#
# /bin/sh itself is still reachable by absolute path, which is what keeps the
# ProcessBuilder spawn below working: the test is about programs found on PATH.
#
#   JOLT_BIN=target/release/jolt sh host/chez/no-external-programs-smoke.sh
root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root" || exit 1

jolt="${JOLT_BIN:-bin/jolt}"
case "$jolt" in /*) joltabs="$jolt" ;; *) joltabs="$root/$jolt" ;; esac

fail() { echo "  FAIL: $*"; exit 1; }
pass=0

# A value with a newline and an equals sign in it, and a name the map must not
# lose. A built binary runs with PATH empty. The launcher script (bin/jolt)
# needs dirname, sed and the rest of coreutils, which live beside env, so it
# runs instead with a directory of decoys FIRST on PATH: an env, sw_vers and
# uname that exit 1 after printing nonsense. A runtime that still spawned one of
# them would get the decoy's answer and fail the same checks.
nl_value="$(printf 'first line\nsecond=line')"
decoys="$(mktemp -d)"
trap 'rm -rf "$decoys"' EXIT
for tool in env sw_vers uname; do
  printf '#!/bin/sh\necho DECOY-%s\nexit 1\n' "$tool" > "$decoys/$tool"
  chmod 755 "$decoys/$tool"
done
if [ "$jolt" = "bin/jolt" ]; then
  run() { env -i HOME="$HOME" PATH="$decoys:$PATH" JOLT_NO_USER_DEPS=1 JOLT_SMOKE_MULTILINE="$nl_value" JOLT_SMOKE_MARK=present "$joltabs" "$@"; }
  label="decoy env/sw_vers/uname first on PATH"
else
  run() { env -i HOME="$HOME" PATH= JOLT_NO_USER_DEPS=1 JOLT_SMOKE_MULTILINE="$nl_value" JOLT_SMOKE_MARK=present "$joltabs" "$@"; }
  label="PATH empty"
fi

echo "no-external-programs smoke: (System/getenv) map, $label"
got="$(run -e '(let [m (System/getenv)] [(get m "JOLT_SMOKE_MARK") (= (get m "JOLT_SMOKE_MULTILINE") (System/getenv "JOLT_SMOKE_MULTILINE")) (contains? m "HOME")])' 2>&1 | tail -1)"
[ "$got" = '["present" true true]' ] || fail "getenv map — want [\"present\" true true], got \`$got\`"
pass=$((pass + 1))

echo "no-external-programs smoke: ProcessBuilder environment seed, $label"
got="$(run -e '(let [e (.environment (ProcessBuilder. ["true"]))] [(.get e "JOLT_SMOKE_MARK") (= (.get e "JOLT_SMOKE_MULTILINE") (System/getenv "JOLT_SMOKE_MULTILINE"))])' 2>&1 | tail -1)"
[ "$got" = '["present" true]' ] || fail "ProcessBuilder environment — want [\"present\" true], got \`$got\`"
pass=$((pass + 1))

# The child sees the parent's environment. /bin/sh is spawned by absolute path;
# `printenv` would need PATH, so the shell's own expansion reads the variable.
echo "no-external-programs smoke: a child inherits the environment, $label"
got="$(run -e '(let [p (.start (ProcessBuilder. ["/bin/sh" "-c" "printf %s \"$JOLT_SMOKE_MARK\""]))] (.waitFor p) (slurp (.getInputStream p)))' 2>&1 | tail -1)"
[ "$got" = '"present"' ] || fail "child environment — want \"present\", got \`$got\`"
pass=$((pass + 1))

case "$(uname -s)" in
  Darwin|Linux)
    echo "no-external-programs smoke: os.version, $label"
    got="$(run -e '(let [v (System/getProperty "os.version")] (and (string? v) (re-find #"^[0-9]+\.[0-9]+" v)))' 2>&1 | tail -1)"
    case "$got" in
      '"'[0-9]*'"') ;;
      *) fail "os.version — want a dotted version string, got \`$got\`" ;;
    esac
    want="$(if [ "$(uname -s)" = Darwin ]; then /usr/bin/sw_vers -productVersion; else uname -r; fi)"
    got="$(run -e '(System/getProperty "os.version")' 2>&1 | tail -1)"
    [ "$got" = "\"$want\"" ] || fail "os.version — want \"$want\" (what the OS's own tool prints), got \`$got\`"
    pass=$((pass + 1)) ;;
esac

echo "no-external-programs smoke: passed ($pass checks)"
