#!/bin/sh
# footprint-test.sh — what a jolt process holds beyond its data. Invoke from the
# repo root with the binary to check (default target/release/jolt):
#   sh test/chez/footprint-test.sh [jolt]
#
# The rows, each a leak of memory that was measured, not modeled:
#   - pinned chunks: a vfasl boot loads straight into the static generation
#     while its temporary buffers (the decompressed image, the relocations) live
#     in chunks of their own. A stock kernel hands such a chunk's spare aligned
#     segment to the next allocation, a static one there pins the whole chunk,
#     and jolt held 76MB of empty chunks for its whole life
#     (host/chez/chez-patches/0002-oversize-chunk-spare-segment.patch). On a
#     kernel without jolt's patches the row reports and passes; on a patched one
#     (the lockfree entry is the marker, both ship together) it must be clean.
#   - const boot arrays: the boot image and the other embedded files are read
#     only, and the launcher madvises the boot. Over writable data that makes
#     every page a private dirty copy on macOS (14MB per process); const puts
#     them in a read-only section, clean and shared.
#   - the GC policy's live baseline: it was read from bytes-allocated before any
#     collection, startup garbage and all (155MB against 62MB live), and sized
#     the nursery and the old-generation growth limit from that. The first
#     collection must report a baseline no bigger than the heap after it.
set -eu

J=${1:-target/release/jolt}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# --- pinned chunks ------------------------------------------------------------
cat > "$tmp/probe.clj" <<EOF
(System/gc)
(println (jolt.host/scheme-eval-string
  "(begin (define footprint-report \"$tmp/alloc.txt\")
          (load \"test/chez/footprint-chunks.ss\")
          (foreign-entry? \"(cs)lockfree_activation\"))"))
EOF
out=$(JOLT_NO_USER_DEPS=1 "$J" "$tmp/probe.clj")
line=$(echo "$out" | grep '^PINNED ' || true)
patched=$(echo "$out" | tail -n 1)
[ -n "$line" ] || { echo "FAIL: footprint probe printed no PINNED line:" >&2; echo "$out" >&2; exit 1; }
echo "footprint: $line (patched kernel: $patched)"
pinned=$(echo "$line" | awk '{print $2}')
if [ "$pinned" != 0 ]; then
  if [ "$patched" = true ] || [ "${JOLT_REQUIRE_LOCKFREE_CHEZ:-}" = 1 ]; then
    echo "FAIL: $pinned near-empty oversize chunk(s) pinned after a full collection" >&2
    fail=1
  else
    echo "footprint: stock Chez kernel, pinned chunks not checked"
  fi
fi

# --- const boot arrays --------------------------------------------------------
# Every embedded array (jolt_boot, jolt_petite_boot, ...; not the _len words)
# must sit in a read-only section: nm's D/d is writable data.
if command -v nm >/dev/null 2>&1; then
  writable=$(nm "$J" 2>/dev/null | awk '$3 ~ /^_?jolt_[A-Za-z0-9_]+$/ && $3 !~ /_len$/ && ($2 == "D" || $2 == "d") {print $3}')
  if [ -n "$writable" ]; then
    echo "FAIL: embedded arrays in writable data (dirtied by the boot prefetch):" >&2
    echo "$writable" >&2
    fail=1
  fi
  arrays=$(nm "$J" 2>/dev/null | awk '$3 ~ /^_?jolt_boot$/' | wc -l | tr -d ' ')
  [ "$arrays" -ge 1 ] || { echo "FAIL: no jolt_boot symbol in $J (nm row checks nothing)" >&2; fail=1; }
else
  echo "footprint: no nm, const-array row skipped"
fi

# --- GC live baseline ---------------------------------------------------------
first=$(JOLT_NO_USER_DEPS=1 JOLT_GC_LOG=1 "$J" -e '(println (reduce + (map count (repeatedly 400000 #(vector 1 2 3)))))' 2>&1 | grep '^gc: ' | head -n 1)
[ -n "$first" ] || { echo "FAIL: no collection logged by the GC baseline row" >&2; exit 1; }
heap=$(echo "$first" | sed -n 's/.* heap \([0-9]*\)MB .*/\1/p')
base=$(echo "$first" | sed -n 's/.* live-after-full \([0-9]*\)MB .*/\1/p')
if [ -z "$heap" ] || [ -z "$base" ]; then
  echo "FAIL: cannot read heap/live-after-full from: $first" >&2; exit 1
fi
if [ "$base" -gt $((heap + 1)) ]; then
  echo "FAIL: GC baseline ${base}MB exceeds the heap after the first collection (${heap}MB)" >&2
  fail=1
fi

# --- System/gc under a busy thread ----------------------------------------------
# A full collection is refused while another thread is active, and System/gc
# used to retry briefly and then do nothing, so with a compute loop running it
# was a no-op (and so was the collection the startup ceiling check depends on).
# It joins the collector's rendezvous now; a weakly held object must clear.
cleared=$(JOLT_NO_USER_DEPS=1 "$J" test/chez/gc-under-threads.clj 2>&1 | tail -n 1)
if [ "$cleared" != "cleared true" ]; then
  echo "FAIL: System/gc with a busy thread did not collect ($cleared)" >&2
  fail=1
fi

# The same early reading refused a ceiling well above the live heap: 150m read
# as under the runtime's 163MB (62MB live), and so would the default ceiling in
# a 512MB container (25% of it).
if ! small=$(JOLT_NO_USER_DEPS=1 JOLT_MAX_HEAP=150m "$J" -e '(println :ok)' 2>&1) || [ "$small" != ":ok" ]; then
  echo "FAIL: JOLT_MAX_HEAP=150m refused at startup:" >&2
  echo "$small" >&2
  fail=1
fi

[ "$fail" = 0 ] || exit 1
echo "footprint: passed"
