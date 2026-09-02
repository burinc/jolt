#!/bin/sh
# The version of this checkout: what `jolt --version` reports when nothing
# bakes one in (bin/jolt), what build-jolt.ss bakes into a binary when
# $JOLT_VERSION is unset, and what the release workflow bakes into a nightly.
# One definition, because the property below is lost by editing any one of the
# three back to a bare `git describe`.
#
#   v0.8.0                on a release tag
#   v0.8.0-56-g63374117   56 commits past it, at that sha (-dirty with edits)
#   dev-g63374117         no release tag reachable (a shallow clone)
#   dev                   not a git checkout (a source tarball; the flake sets
#                         JOLT_VERSION itself)
#
# Release tags only (`v` + digit). The rolling `vnightly` tag the release
# workflow moves to main's head every day is the NEAREST tag from main, so a
# plain `git describe --tags` on any clone that has fetched it answers
# "vnightly". And the no-tag case is prefixed rather than the bare sha:
# jolt.deps reads a version's leading digits, so a sha such as 0a1b2c3 would
# read as version 0 and fail every :jolt/min-version floor, while dev-g0a1b2c3
# reads as a version with no number, which no floor applies to.
#
# Usage: tools/version.sh [checkout]   (default: the checkout this script is in)
set -eu
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
v="$(git -C "$root" describe --tags --always --dirty --match 'v[0-9]*' 2>/dev/null)" || v=""
case "$v" in
  v[0-9]*) ;;
  "")      v=dev ;;
  *)       v="dev-g$v" ;;
esac
printf '%s\n' "$v"
