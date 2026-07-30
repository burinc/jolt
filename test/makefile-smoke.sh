#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

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

# Make, not the shell, expands the expressions in this injected rule.
# shellcheck disable=SC2016
inspect='inspect-chez:
	@printf "%s\n" \
	  "chez=$(CHEZ)" \
	  "jolt-chez=$(JOLT-CHEZ)" \
	  "local-origin=$(origin LOCAL-LOADED)" \
	  "gcc-origin=$(origin GCC-LOADED)"'

check_override() {
  local name=$1
  local output

  output="$(
    make --no-print-directory -s \
      "$name=$fake_chez" \
      --eval "$inspect" \
      inspect-chez
  )"

  grep -Fx "chez=$fake_chez" <<<"$output" >/dev/null
  grep -Fx "jolt-chez=$fake_chez" <<<"$output" >/dev/null
  grep -Fx "local-origin=undefined" <<<"$output" >/dev/null
  grep -Fx "gcc-origin=undefined" <<<"$output" >/dev/null

  make --no-print-directory -s "$name=$fake_chez" deps
}

check_override CHEZ
check_override CHEZSCHEME

echo "makefile smoke: explicit Chez overrides bypass local provisioning"
