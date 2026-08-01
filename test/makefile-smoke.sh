#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Test each caller override independently of the Make process that launched us.
# Command-line variables also propagate to nested Makes through these flags.
unset CHEZ CHEZSCHEME MAKEFLAGS MAKEOVERRIDES

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_chez="$tmp/chez"
cat >"$fake_chez" <<'FAKE'
#!/usr/bin/env bash
case ${1-} in
  -q)
    cat >/dev/null
    printf '#t\n'
    ;;
  --version)
    printf '10.4.1\n'
    ;;
  *)
    exit 1
    ;;
esac
FAKE
chmod +x "$fake_chez"

# The probe lives in its own makefile that includes the real one, rather than
# being injected with `make --eval`: --eval arrived in GNU Make 3.82, and macOS
# still ships 3.81, where every check here died with "unrecognized option". Since
# this gate is part of `ci`, that took `make test` down on any Mac using the
# system make. Running with -C keeps every relative path in the included Makefile
# (.cache/makes, host/chez/...) resolving against the repo root.
probe_mk="$tmp/probe.mk"
cat >"$probe_mk" <<'MK'
include Makefile
inspect-chez:
	@printf "%s\n" \
	  "chez=$(CHEZ)" \
	  "jolt-chez=$(JOLT-CHEZ)" \
	  "local-origin=$(origin LOCAL-LOADED)" \
	  "gcc-origin=$(origin GCC-LOADED)"
MK

check_override() {
  local name=$1
  local output

  output="$(
    make -C "$root" -f "$probe_mk" --no-print-directory -s \
      "$name=$fake_chez" inspect-chez
  )"

  grep -Fx "chez=$fake_chez" <<<"$output" >/dev/null
  grep -Fx "jolt-chez=$fake_chez" <<<"$output" >/dev/null
  grep -Fx "local-origin=undefined" <<<"$output" >/dev/null
  grep -Fx "gcc-origin=undefined" <<<"$output" >/dev/null

  make --no-print-directory -s "$name=$fake_chez" deps
}

check_override CHEZ
check_override CHEZSCHEME

# A Chez already on PATH is used as-is, with NOTHING set. This is the case the
# release matrix depends on: every non-Linux row builds its own Chez and exposes
# it as `chez` on PATH, then runs a bare `make jolt-release`. If that fell through
# to local provisioning, a release would silently ship a binary built by a Chez
# other than the one the job prepared — and the two differ in exactly the ways
# that matter here (threading, libc floor, cross target).
check_path_discovery() {
  local output real

  # A toolchain already provisioned into .cache/local takes precedence over PATH,
  # so this checkout can no longer answer the question. Legitimate state, and it
  # does not arise on a release runner: those are fresh clones that put their own
  # chez on PATH before any make runs, so nothing provisions.
  if [ -d "$root/.cache/local" ]; then
    echo "makefile smoke: SKIP PATH discovery (.cache/local is provisioned here)"
    return 0
  fi

  # Deliberately the REAL chez, not the stub used above: provisioning validates
  # what it finds on PATH and rejects a stub, so a fake would fall through and
  # provision — testing the opposite of the intended case.
  real="$(command -v chez 2>/dev/null || command -v chezscheme 2>/dev/null || command -v scheme 2>/dev/null || true)"
  if [ -z "$real" ]; then
    echo "makefile smoke: SKIP PATH discovery (no Chez on PATH)"
    return 0
  fi

  output="$(make -C "$root" -f "$probe_mk" --no-print-directory -s inspect-chez)"

  grep -Fx "jolt-chez=$real" <<<"$output" >/dev/null || {
    echo "a Chez on PATH was not selected; expected $real, got:" >&2
    echo "$output" >&2
    exit 1
  }
  grep -Fx "local-origin=undefined" <<<"$output" >/dev/null || {
    echo "provisioned a local toolchain despite a Chez on PATH:" >&2
    echo "$output" >&2
    exit 1
  }
}

check_path_discovery

echo "makefile smoke: explicit Chez overrides bypass local provisioning,"
echo "                and a Chez on PATH is used without provisioning"
