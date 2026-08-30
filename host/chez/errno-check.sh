#!/bin/sh
# errno-check.sh — the socket layer must ask about a syscall's errno exactly
# once, at the syscall, and branch on the captured VALUE.
#
# WHY THIS GATE EXISTS. errno survives only until the next thing that can set
# it, and on this runtime that includes READING it: jolt.ffi/errno is a foreign
# call (__error / __errno_location) and an allocation on the way can trip a
# collection whose mmap leaves ENOMEM behind. So a caller that asks two
# questions about one syscall -- (eintr?) and then (eagain?) -- is asking about
# two different values.
#
# That is not theoretical. io-call did exactly that, and under CPU load recv's
# EAGAIN read back as ENOMEM often enough to matter: the retry branch was
# missed, the -1 fell through, and do-recv answered EOF on a live connection.
# Downstream that surfaced as a go block throwing on (String. b 0 -1 "UTF-8"),
# its channel closing empty, and a poller stress case reporting "1 of 8
# readiness registrations lost" -- a failure that named the poller, which was
# innocent. Measured 13 of 60 runs under load; 0 of 60 once the errno was
# captured once, at the call.
#
# The shape is invisible in review -- (poller/eagain?) reads exactly like
# (poller/eagain? e) -- and the failure it produces points somewhere else
# entirely, so it is checked here rather than left to whoever writes the next
# syscall wrapper to remember.
#
#   sh host/chez/errno-check.sh
set -eu
cd "$(dirname "$0")/../.."

bad=0

# The no-arg predicates read errno themselves. In the socket layer, where the
# read follows a syscall whose result is already in hand, the value-taking
# arity is the only correct form.
for f in stdlib/jolt/socket.clj; do
  [ -f "$f" ] || continue
  hits=$(grep -n '(poller/eagain?)\|(poller/eintr?)' "$f" || true)
  if [ -n "$hits" ]; then
    echo "errno-check: $f asks errno a second time instead of branching on the"
    echo "             value captured at the syscall:"
    echo "$hits" | sed 's/^/             /'
    bad=1
  fi
done

# More than one errno read per syscall wrapper is the same defect wearing a
# different spelling.
n=$(grep -c '(poller/errno)' stdlib/jolt/socket.clj || true)
if [ "$n" -gt 2 ]; then
  echo "errno-check: stdlib/jolt/socket.clj reads errno $n times."
  echo "             One read per syscall site (io-call, connect). If a new"
  echo "             syscall wrapper needs one, raise this bound deliberately."
  bad=1
fi

if [ "$bad" -ne 0 ]; then exit 1; fi
echo "errno-check: errno is captured at the syscall"
