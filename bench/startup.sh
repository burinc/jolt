#!/bin/sh
# Startup / small-program latency — the axis run.sh does NOT measure. run.sh
# builds each benchmark to an optimized binary and times the compute inside it;
# it says nothing about how long `jolt` itself takes to get from exec to first
# result. That fixed floor (runtime + compiler image boot, then compile the
# program) is what dominates ys-style workloads: many short `jolt prog.clj`
# invocations where the program runs for milliseconds.
#
# This times whole-process wall clock (best of N, to shed scheduler noise) for a
# built jolt against babashka on the same sources, across three sizes:
#   - version : pure boot floor, no user program
#   - trivial : boot + compile + run of a one-liner
#   - script  : boot + compile + run of a small real program (a seq pipeline)
#
#   bench/startup.sh              # default 7 reps
#   REPS=15 bench/startup.sh      # more reps
#   COLD=1 bench/startup.sh       # add the cold-page-cache numbers (see below)
#   JOLT_BIN=/path/to/jolt bench/startup.sh
#
# Everything above the COLD section measures a WARM binary — the second and later
# runs, whose bytes are already in the page cache. That is not what a user's FIRST
# run of the day costs: jolt is one ~28MB file that nothing else on the machine
# keeps resident, and the embedded boot image inside it has to be read before the
# runtime exists. COLD=1 drops the binary from the page cache before each rep
# (bench/pagecache.clj — posix_fadvise on Linux, msync on macOS, no root) and
# reports that number too.
#
# jolt must be a BUILT binary (target/release/jolt or an installed jolt), not
# the dev bin/jolt source launcher — the dev script opts out of the AOT cache and
# boots from source, so it is not representative of what users run.
set -e
cd "$(dirname "$0")"
root="$(cd .. && pwd)"

jolt="${JOLT_BIN:-$root/target/release/jolt}"
[ -x "$jolt" ] || jolt="$(command -v jolt || true)"
if [ -z "$jolt" ] || [ ! -x "$jolt" ]; then
  echo "error: no built jolt found. Build one (make jolt-release) or set JOLT_BIN." >&2
  exit 1
fi
have_bb=""; command -v bb >/dev/null 2>&1 && have_bb=1

REPS="${REPS:-7}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '(println (reduce + (map inc (filter odd? (range 1000)))))\n' > "$work/trivial.clj"
# a small lazy-seq pipeline — representative of idiomatic script code
cat > "$work/script.clj" <<'EOF'
(println
  (reduce (fn [a x] (+ a x)) 0
          (take 5000 (map (fn [x] (* x x))
                          (filter even? (iterate inc 1))))))
EOF

# best-of-N wall-clock in milliseconds for a command.
best_ms() {
  best=""
  i=0
  while [ "$i" -lt "$REPS" ]; do
    t0=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
    "$@" >/dev/null 2>&1 || true
    t1=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
    ms=$((t1 - t0))
    if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
    i=$((i + 1))
  done
  echo "$best"
}

row() {
  label="$1"; shift
  jbin="$1"; shift
  jms=$(best_ms "$jolt" $jbin)
  if [ -n "$have_bb" ]; then
    bms=$(best_ms bb "$@")
    ratio=$(awk "BEGIN{ if ($bms>0) printf \"%.1fx\", $jms/$bms; else printf \"-\" }")
    printf '%-10s jolt %5s ms   bb %5s ms   %s\n' "$label" "$jms" "$bms" "$ratio"
  else
    printf '%-10s jolt %5s ms\n' "$label" "$jms"
  fi
}

echo "startup / small-program latency — best of $REPS  ($(basename "$jolt")${have_bb:+ vs bb})"
row "version" "--version" "--version"
row "trivial" "$work/trivial.clj" "$work/trivial.clj"
row "script"  "$work/script.clj"  "$work/script.clj"

# --- cold page cache (COLD=1) -----------------------------------------------
# Two caveats worth knowing before reading these numbers:
#
#   - Only the jolt binary is evicted, not libc or the loader, and not bb. This
#     is a jolt-vs-jolt measurement, for judging whether a change moved the cold
#     floor — not a cross-runtime comparison.
#   - Eviction clears the GUEST page cache. Under a VM or a caching disk
#     controller the layer below it stays warm, so repeated cold reps drift
#     downward and the first rep is the most honest one. Both are printed.
if [ -n "${COLD:-}" ]; then
  # the script cd'd into its own directory at the top, so $0 is no longer a
  # usable base; $root is.
  pc="$root/bench/pagecache.clj"
  if [ ! -f "$pc" ]; then
    echo
    echo "COLD=1 needs $pc (posix_fadvise/msync + mincore) — skipping."
    exit 0
  fi

  # first-rep and best-of-N wall clock, evicting before every rep.
  cold_ms() {
    first=""; best=""; i=0
    while [ "$i" -lt "$REPS" ]; do
      JOLT_NO_USER_DEPS=1 "$jolt" run "$pc" evict "$jolt" >/dev/null 2>&1 || true
      t0=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
      "$jolt" "$@" >/dev/null 2>&1 || true
      t1=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000')
      ms=$((t1 - t0))
      if [ -z "$first" ]; then first="$ms"; fi
      if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
      i=$((i + 1))
    done
    echo "$first $best"
  }

  echo
  echo "cold page cache — $REPS reps, binary evicted before each"
  for label in version trivial script; do
    case "$label" in
      version) arg="--version" ;;
      trivial) arg="$work/trivial.clj" ;;
      script)  arg="$work/script.clj" ;;
    esac
    set -- $(cold_ms "$arg")
    printf '%-10s first %5s ms   best %5s ms\n' "$label" "$1" "$2"
  done

  # How much of the binary a single cold run actually reads. This is the number
  # the cold floor is made of: shrink it and the cold floor moves, whatever the
  # prefetching does.
  JOLT_NO_USER_DEPS=1 "$jolt" run "$pc" evict "$jolt" >/dev/null 2>&1 || true
  "$jolt" --version >/dev/null 2>&1 || true
  set -- $(JOLT_NO_USER_DEPS=1 "$jolt" run "$pc" resident "$jolt")
  awk -v got="$1" -v total="$2" 'BEGIN {
    printf "\nfaulted in by one run: %.1f MB of a %.1f MB binary\n",
           got / 1000000, total / 1000000 }'
fi
