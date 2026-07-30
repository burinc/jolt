#!/bin/sh
# Build phase breakdown — where does `jolt build` spend its time?
#
# bench/startup-phases.sh attributes a program RUN to its phases; this does the
# same for a BUILD, which has a completely different shape. A build's cost splits
# in two, and the two halves want unrelated fixes:
#
#   jolt's own passes : parsing each app source (several times over), the
#                       whole-program inference fixpoint, and per-form emit.
#                       Scales with the app's source size.
#   Chez's compile    : compile-file over the flat runtime+app Scheme, then
#                       make-boot-file and the stub link. The runtime half of
#                       that file is the same ~1.7 MB for every app a given jolt
#                       builds, so most of this is a FIXED cost per build.
#
# Optimizing the wrong half is easy without the split: an app with little source
# is dominated by the fixed Chez compile, a large one by the passes. So measure,
# then decide.
#
# The phases come from the build itself (JOLT_BUILD_PROFILE=1, build.ss), not
# from external subtraction — each is the real elapsed time between two points in
# one build, so they sum to the whole.
#
#   bench/build-phases.sh ../examples/ring-app app.core
#   REPS=3 bench/build-phases.sh ../examples/hiccup-app app.core
#   JOLT_BIN=target/release/jolt bench/build-phases.sh ../examples/ring-app app.core
#
# Every configuration is built from scratch (fresh -o path) so no phase is
# reading another run's artifact. Best-of-REPS per configuration, since a build
# does enough I/O to pick up scheduler noise; run it on an otherwise idle machine
# — a concurrent rebuild or test run makes these numbers meaningless.
#
# jolt must be a BUILT binary, not the dev bin/jolt source launcher: the dev
# script boots from source and compiles jolt.main every time, which lands in the
# startup phase and swamps the comparison.

set -e

proj="$1"
entry="$2"
if [ -z "$proj" ] || [ -z "$entry" ]; then
  echo "usage: bench/build-phases.sh PROJECT_DIR ENTRY_NS" >&2
  exit 2
fi

REPS="${REPS:-3}"
JOLT_BIN="${JOLT_BIN:-target/release/jolt}"
if [ ! -x "$JOLT_BIN" ]; then
  echo "no jolt binary at $JOLT_BIN (make testbin, or set JOLT_BIN)" >&2
  exit 2
fi
jolt="$(cd "$(dirname "$JOLT_BIN")" && pwd)/$(basename "$JOLT_BIN")"
proj="$(cd "$proj" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# One build. $1 = label, $2 = extra env assignments, $3 = extra build flags.
# Prints the profile table, then the flat.ss size and the two-way split.
run_config() {
  label="$1"; envs="$2"; flags="$3"
  best=""; best_wall=""
  i=0
  while [ "$i" -lt "$REPS" ]; do
    i=$((i + 1))
    out="$work/bin-$i"
    rm -rf "$out" "$out.build"
    log="$work/log-$i"
    # `env` rather than an exported assignment so a config's variables cannot
    # leak into the next one.
    t0="$(now_ms)"
    ( cd "$proj" && env JOLT_BUILD_PROFILE=1 $envs "$jolt" build -m "$entry" -o "$out" $flags ) \
      >/dev/null 2>"$log" || { echo "  BUILD FAILED ($label) — stderr:"; sed 's/^/    /' "$log"; return 1; }
    wall=$(( $(now_ms) - t0 ))
    total="$(awk '/\[profile\]/ {gsub(/[()]/,""); t=$NF} END {print t+0}' "$log")"
    if [ -z "$best" ] || [ "$total" -lt "$best" ]; then
      best="$total"; best_wall="$wall"; cp "$log" "$work/best-$label.log" 2>/dev/null || true
      flat_bytes="$(wc -c < "$out.build/flat.ss" 2>/dev/null | tr -d ' ')"
    fi
  done

  echo
  # The profile total covers build-binary only. Wall clock also includes process
  # start, deps resolution, and the lazy eval of the build subsystem itself
  # (build-jolt.ss bakes build.ss as source and loads it on the first `build`) —
  # so the gap between the two is real cost that the phase table cannot see.
  echo "=== $label — best of $REPS: ${best} ms in build-binary, ${best_wall} ms wall ==="
  sed -n 's/^jolt build: \[profile\] /  /p' "$work/best-$label.log"
  [ -n "$flat_bytes" ] && echo "  flat.ss: $((flat_bytes / 1024)) KB"
  # The split. "Chez" is compile-file + make-boot-file + link; everything before
  # writing flat.ss is jolt's own work. The prologue pass sits between: it reads
  # and rewrites flat.ss, so it is jolt's code but scales with the flat file.
  awk -v label="$label" '
    /\[profile\]/ {
      # after stripping parens a line reads:
      #   jolt build: [profile] <name words…> <ms> ms cumulative <total>
      gsub(/[()]/, "");
      ms = $(NF-3);
      name = "";
      for (i = 4; i <= NF - 4; i++) name = name (name == "" ? "" : " ") $i;
      if (name ~ /compile-file|make-boot-file|payload link/) chez += ms;
      else if (name ~ /prologue/)                            pro  += ms;
      else                                                   jolt += ms;
    }
    END {
      t = jolt + pro + chez;
      if (t > 0) printf("  split: jolt passes %d ms (%.0f%%)   prologue %d ms (%.0f%%)   Chez compile+link %d ms (%.0f%%)\n",
                        jolt, 100*jolt/t, pro, 100*pro/t, chez, 100*chez/t);
    }' "$work/best-$label.log"
}

echo "build-phases: $proj -m $entry   ($REPS reps per configuration, best of)"
echo "jolt: $jolt"

run_config "release" "" ""
run_config "release-no-wp-infer" "JOLT_NO_WP_INFER=1" ""
run_config "dev" "" "--dev"
run_config "dev-no-direct-link" "" "--dev --no-direct-link"

echo
echo "Read the split, not the total: a fix to the jolt-side passes cannot move"
echo "the Chez column, and caching the runtime half of flat.ss cannot move the"
echo "jolt column."
