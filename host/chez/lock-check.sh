#!/bin/sh
# lock-check.sh — every lock in the runtime must route through jolt's wrapper.
#
# WHY THIS GATE EXISTS. A fiber suspended while holding an OS mutex loses mutual
# exclusion either way: if the switch unwinds, the lock is released
# mid-section; if it does not, the fiber keeps a mutex while another fiber on
# the SAME carrier runs, and Chez mutexes are recursive per thread, so that
# fiber's acquire succeeds anyway. Preemption is therefore refused while a lock
# is held, which only works if the runtime can TELL. It can only tell if every
# acquisition goes through the counting wrapper.
#
# A wrapper nobody is obliged to use decays back into the hand-marked scheme it
# replaced — which is exactly how the previous mechanism kept missing regions,
# one tightened quantum at a time. So the obligation is checked here rather than
# documented and hoped for.
#
# The scan covers the three mutex PRIMITIVES and nothing else. It used to also
# scan monitor-enter!/monitor-exit! by name, because jolt-with-monitor is the
# user-facing `locking` and therefore jolt's analogue of the `synchronized` case
# that pinned Loom's virtual threads until JEP 491. Those two now take their
# mutex through jolt-lock!, so scanning them was scanning a wrapper rather than a
# primitive, and it left two entries on the allowlist that could never go to
# zero. They are covered transitively and strictly: rewriting either of them to
# grab the mutex directly shows up here as a new bare mutex-acquire in
# concurrency.ss. Mutation-verified in that direction, not assumed.
#
#   sh host/chez/lock-check.sh          check against the allowlist
#   sh host/chez/lock-check.sh --regen  regenerate it (review the diff!)
set -eu
cd "$(dirname "$0")/../.."

ALLOW=host/chez/lock-allowlist.txt
# The files that DEFINE the wrapper are where these primitives are supposed to
# appear. Everything else must go through it.
SANCTIONED='host/chez/locks.ss'

scan() {
  for f in host/chez/*.ss host/chez/java/*.ss; do
    case " $SANCTIONED " in *" $f "*) continue ;; esac
    grep -nE '\((mutex-acquire|mutex-release|with-mutex)[ )]' "$f" 2>/dev/null \
      | while IFS=: read -r ln _; do
          op=$(sed -n "${ln}p" "$f" | grep -oE '\((mutex-acquire|mutex-release|with-mutex)[ )]' | head -1 | tr -d '() ')
          [ -n "$op" ] && echo "$f $op"
        done
  done | sort | uniq -c | awk '{print $2" "$3" "$1}' | sort
}

if [ "${1:-}" = "--regen" ]; then
  {
    echo "# host/chez/lock-allowlist.txt — generated. Regenerate with:"
    echo "#   sh host/chez/lock-check.sh --regen"
    echo "# Lines: <file> <primitive> <count>. A line whose count DROPS is stale"
    echo "# and fails the gate, so migrating a site to the wrapper must update this."
    echo "# Empty is the goal and the current state: every acquisition in the runtime
# routes through host/chez/locks.ss. A monitor counts transitively, through
# jolt-lock!, so it needs no entry here."
    scan
  } > "$ALLOW"
  echo "lock check: regenerated $(grep -cv '^#' "$ALLOW") entries"
  exit 0
fi

got=$(scan)
want=$(grep -v '^#' "$ALLOW" || true)

problems=$(
  # A NEW bare use, or MORE of them in a file than the allowlist records.
  echo "$got" | while read -r f op n; do
    [ -z "$f" ] && continue
    w=$(echo "$want" | awk -v f="$f" -v o="$op" '$1==f && $2==o {print $3}')
    if [ -z "$w" ]; then
      echo "  NEW bare lock use: $f $op ($n) — route it through host/chez/locks.ss"
    elif [ "$n" -gt "$w" ]; then
      echo "  MORE bare lock uses: $f $op ($w -> $n) — route them through host/chez/locks.ss"
    fi
  done
  # A line whose count DROPPED is stale: the migration happened but the
  # allowlist was not regenerated, which would let the count creep back unseen.
  echo "$want" | while read -r f op n; do
    [ -z "$f" ] && continue
    g=$(echo "$got" | awk -v f="$f" -v o="$op" '$1==f && $2==o {print $3}')
    g=${g:-0}
    if [ "$g" -lt "$n" ]; then
      echo "  STALE allowlist entry: $f $op ($n -> $g) — rerun with --regen"
    fi
  done
)

if [ -n "$problems" ]; then
  echo "$problems"
  echo "lock check: FAILED"
  exit 1
fi
echo "lock check: passed ($(echo "$got" | grep -c .) allowlisted sites, target is 0)"
