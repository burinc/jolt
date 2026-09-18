#!/bin/sh
# shellout-check.sh — jolt-core may hand the shell external programs, not
# filesystem operations.
#
# WHY THIS GATE EXISTS. jolt.host/sh is Chez's `system`: on Windows that runs
# the command string through cmd.exe, which shares almost nothing with a POSIX
# shell. `mkdir -p a/b` there does not create a/b's parents — cmd's mkdir has no
# options and takes a LIST of paths, so it creates a directory literally named
# `-p` and reports nothing wrong. mv, rm, touch, test and find are not commands
# at all. So a resolver written in shell commands does not fail on Windows, it
# half-works: jolt v0.7.14 littered every project it ran in with a `-p`
# directory and a growing pile of `.part-` files that the failed `mv` never
# published, and its classpath cache could never hit.
#
# The fix was to do the filesystem work through filesystem calls (jolt.host
# mkdirs!/rename-file!/delete-file!/delete-tree!/file-mtime/list-dir), leaving
# the shell for the one thing that really is an external program: git. Jars
# are read in place through their central directory, never extracted (jolt
# issues #988 and #1005).
# That distinction is invisible in the source — a `(sh (str "rm -f " …))` reads
# exactly like a `(sh (str "git clone " …))` — so it is checked here rather than
# left to whoever adds the next one to remember which host they are on.
#
# The scan covers jolt-core/, which is the dependency resolver and the CLI: the
# code that runs on a user's machine before anything of theirs does, and the
# Chez runtime under host/chez/ (not the build driver, whose C compiler is a
# documented requirement of a :static native or a --library). stdlib/ is
# deliberately out of scope — clojure.java.browse opening a URL through xdg-open
# IS a platform-specific program, and says so.
#
# The runtime rule is stricter than jolt-core's: it may spawn only what a
# caller hands it (jolt.host/sh, sh-out, ProcessBuilder, Runtime.exec) and
# never a program it names itself. It used to name three — `env -0` behind
# (System/getenv) and every ProcessBuilder child's environment, `sw_vers` and
# `uname -r` behind os.version, and a `chmod` fallback — each read through the
# C runtime now (host/chez/no-external-programs-smoke.sh proves the first two
# with PATH empty). The shell itself (`sh -c`, which is how sh-out runs the
# caller's command) is the seam, not a program.
#
#   sh host/chez/shellout-check.sh
set -eu
cd "$(dirname "$0")/../.."

# The external programs jolt is allowed to run: git, a real dependency with no
# in-process equivalent (jolt has no git client). unzip left the list when jars
# began to extract in process (jolt issue #988).
ALLOWED='git'

fail=0

# Every (sh …) / (sh-out* …) call site, reduced to the first word of the command
# it runs. A site whose command does not begin with a string literal — the one
# in sh-out* itself, which redirects a command it was handed — has no head to
# check and is skipped by the pattern.
bad=$(grep -rnoE '\((sh|sh-out\*)[[:space:]]+(\(str[[:space:]]+)?"[^" ]*' jolt-core/ \
      | grep -vE "\"($ALLOWED)\$" || true)
if [ -n "$bad" ]; then
  echo "shellout-check: these run something other than $ALLOWED through the shell." >&2
  echo "shellout-check: filesystem work goes through the jolt.host seams instead." >&2
  echo "$bad" >&2
  fail=1
fi

# A command that discards its output by redirecting to /dev/null is POSIX-only
# the same way: cmd.exe reads that as a path and fails the whole redirect, which
# takes the command with it. sh-out* captures through a temp file, which works
# everywhere and is what the callers that need silence use.
devnull=$(grep -rnE '\((sh|sh-out\*)[[:space:]]' jolt-core/ | grep '/dev/null' || true)
if [ -n "$devnull" ]; then
  echo "shellout-check: /dev/null is not a path on every host jolt runs on." >&2
  echo "$devnull" >&2
  fail=1
fi

# The runtime: every spawn site — Chez's system / open-process-ports, the
# adapter's sa-run-process — whose command begins with a string literal, less
# the sh-out seam's own `exec sh -c`. build*.ss are the compiler driver, and
# the seed is generated.
runtime_files="$(find host/chez -name '*.ss' -not -path 'host/chez/seed/*' -not -name 'build*.ss' -not -name '*-test.ss' -not -name 'run-*.ss' -not -name 'gate-*.ss' -not -name 'make-*.ss' -not -name '*-check.ss')"
rbad=$(grep -noE '\((system|open-process-ports|sa-run-process)[[:space:]]+(\(string-append[[:space:]]+)?"[^"]*' $runtime_files \
       | grep -vE '"exec sh -c $' || true)
if [ -n "$rbad" ]; then
  echo "shellout-check: the runtime names a program to run; it may only spawn what a caller hands it." >&2
  echo "shellout-check: read the answer through the C runtime (an FFI call) instead." >&2
  echo "$rbad" >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "shellout-check: jolt-core shells out to $ALLOWED only; the runtime names no program"
