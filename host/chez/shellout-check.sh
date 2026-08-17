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
# the shell for the two things that really are external programs: git and unzip.
# That distinction is invisible in the source — a `(sh (str "rm -f " …))` reads
# exactly like a `(sh (str "git clone " …))` — so it is checked here rather than
# left to whoever adds the next one to remember which host they are on.
#
# The scan covers jolt-core/, which is the dependency resolver and the CLI: the
# code that runs on a user's machine before anything of theirs does. stdlib/ is
# deliberately out of scope — clojure.java.browse opening a URL through xdg-open
# IS a platform-specific program, and says so.
#
#   sh host/chez/shellout-check.sh
set -eu
cd "$(dirname "$0")/../.."

# The external programs jolt is allowed to run. Both are real dependencies with
# no in-process equivalent (jolt has neither a git client nor an inflater).
ALLOWED='git|unzip'

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

[ "$fail" -eq 0 ] || exit 1
echo "shellout-check: jolt-core shells out to $ALLOWED only"
