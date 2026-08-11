#!/bin/sh
# cap.sh SECONDS CMD [ARG...] — run CMD under a wall-clock cap, POSIX sh only.
#
# A stand-in for `timeout --foreground` on a host without GNU coreutils (a stock
# macOS has neither timeout nor gtimeout). smoke.sh ran every case UNCAPPED
# there, having printed one note about it, so a case that hung wedged the whole
# gate: `make test` sat on the poller-registration case for over ninety minutes
# with no output, because make prints nothing for a target until it finishes
# (jolt-8tma).
#
# Like --foreground and unlike a plain `timeout`, this leaves the process group
# alone: the command runs as an ordinary child, so a case that spawns children
# and asserts on their process group (jolt.process, the SIGTERM exit 143 case)
# sees the same group it would with no cap at all.
#
# Exits with the command's own status, or 124 on expiry — the status timeout(1)
# reports, so a caller can tell "this case failed" from "this case hung".
secs="$1"
shift

# 0<&0 is not redundant: a shell with job control off points a BACKGROUND
# command's stdin at /dev/null unless the command redirects it itself, and the
# cases that pipe a program in (`jolt - < prog.clj`, every REPL case) then read
# nothing at all. An explicit redirection opts back into the caller's stdin.
"$@" 0<&0 &
cmd_pid=$!

# A marker file rather than "is the watchdog still alive": the watchdog outlives
# its own expiry by the grace period below, so its being alive says nothing about
# whether it fired.
marker="${TMPDIR:-/tmp}/jolt-cap.$$"
rm -f "$marker"

# The watchdog polls in one-second steps and ENDS ITSELF once the command is
# gone. Signalling it instead does not work: a POSIX shell waiting on a
# foreground `sleep` defers the signal until that sleep returns, so a `kill` here
# followed by a `wait` there charged every single capped invocation the full cap
# — the smoke suite went from three minutes to two minutes PER CASE.
#
# Both streams go to /dev/null because this outlives cap.sh itself: a caller
# reading the case's output through $(...) waits for EOF on the pipe, and a
# background writer still holding it would hang the caller for exactly as long as
# the deferred-signal version did.
(
  waited=0
  while [ "$waited" -lt "$secs" ]; do
    sleep 1
    kill -0 "$cmd_pid" 2>/dev/null || exit 0
    waited=$((waited + 1))
  done
  : > "$marker"
  kill -TERM "$cmd_pid" 2>/dev/null
  # A jolt wedged on a lock does not always act on SIGTERM, and the whole point
  # of a cap is that it always ends.
  sleep 2
  kill -KILL "$cmd_pid" 2>/dev/null
) >/dev/null 2>&1 &

# The shell announces a killed background job on ITS stderr ("Terminated: 15"),
# which would land in the middle of the case output that smoke.sh reads. Only the
# reaping is silenced here; the command's own stderr is its own and untouched.
{ wait "$cmd_pid"; status=$?; } 2>/dev/null

if [ -f "$marker" ]; then
  rm -f "$marker"
  exit 124
fi
exit "$status"
