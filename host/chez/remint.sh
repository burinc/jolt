#!/bin/sh
# Re-mint the checked-in Chez seed. Run after changing a seed source — the reader
# (host/chez/reader.ss), the analyzer/IR/backend (jolt-core/jolt/*.clj), or the
# clojure.core overlay (jolt-core/clojure/core/*.clj). Iterates bootstrap.ss from the
# current seed to a byte-fixpoint and overwrites host/chez/seed/, then cross-mints
# host/gambit/seed/ from it.
set -e
root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
# JOLT_CHEZ wins (see host/chez/selfcheck.sh) — re-minting the seed under the
# wrong Chez is exactly the mistake this script exists to avoid.
CHEZ="${JOLT_CHEZ:-${CHEZ:-$(command -v chez || command -v chezscheme || command -v scheme)}}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp host/chez/seed/prelude.ss "$tmp/cur-p.ss"
cp host/chez/seed/image.ss   "$tmp/cur-i.ss"
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  # capture stderr so the fixpoint pass can be checked for skipped forms; the
  # skip count is only trustworthy once converged (an earlier pass compiling off
  # an older seed may skip a form that a later pass, off the rebuilt seed, emits).
  # a bootstrap failure must leave its error readable: the temp dir dies with
  # the trap, so surface stderr before set -e aborts the loop
  # JOLT_MINT_DEBUG puts each skipped form's reason in the log. A form a pass
  # skips is missing from the seed the next pass runs, so when that form is part
  # of the compiler, the pass that fails is a later one and its own error (an
  # unbound jv$ name, say) points nowhere near the cause: show what the passes
  # before it skipped, and why.
  if ! JOLT_MINT_DEBUG=1 "$CHEZ" --script host/chez/bootstrap.ss \
      "$tmp/cur-p.ss" "$tmp/cur-i.ss" "$tmp/new-p.ss" "$tmp/new-i.ss" >/dev/null 2>"$tmp/err"; then
    echo "re-mint: bootstrap pass $i failed:" >&2
    grep -v '^mint: ' "$tmp/err" >&2 || true
    if [ -s "$tmp/skips" ]; then
      echo "re-mint: forms the earlier passes skipped:" >&2
      cat "$tmp/skips" >&2
    fi
    exit 1
  fi
  grep '^mint: .* raised: ' "$tmp/err" | sed "s/^/pass $i: /" >>"$tmp/skips" || true
  if diff -q "$tmp/cur-p.ss" "$tmp/new-p.ss" >/dev/null \
     && diff -q "$tmp/cur-i.ss" "$tmp/new-i.ss" >/dev/null; then
    skipped=$(sed -n 's/^mint: \([0-9][0-9]*\) form(s) skipped$/\1/p' "$tmp/err" | tail -1)
    if [ -n "$skipped" ] && [ "$skipped" -ne 0 ]; then
      echo "re-mint: $skipped form(s) failed to compile in the fixpoint pass:" >&2
      grep '^mint: .* raised: ' "$tmp/err" >&2
      exit 1
    fi
    cp "$tmp/new-p.ss" host/chez/seed/prelude.ss
    cp "$tmp/new-i.ss" host/chez/seed/image.ss
    echo "re-minted seed (converged after $i pass(es))"
    # The gambit seed is cross-minted FROM this one (host/gambit/gen-seed.ss
    # re-emits it with the :gambit target), and gambitseedcheck in CI holds the
    # two to the same sources. Re-minting only the chez half left it stale, which
    # is how a contributor who did exactly what CONTRIBUTING said arrived with a
    # red gate (#1057). set -e: a gen-seed failure fails the remint.
    "$CHEZ" --script host/gambit/gen-seed.ss
    exit 0
  fi
  cp "$tmp/new-p.ss" "$tmp/cur-p.ss"
  cp "$tmp/new-i.ss" "$tmp/cur-i.ss"
done
echo "re-mint did not converge in 8 passes" >&2
exit 1
