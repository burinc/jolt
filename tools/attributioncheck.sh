#!/bin/sh
# No AI-assistant attribution in git history: a Claude-Session trailer or
# claude.ai session link, a Co-Authored-By: Claude line, or the "Generated with
# Claude Code" footer. The project's commit messages describe the change and
# nothing else, and a session link is a private URL that has no business in a
# public repository's history.
#
#   tools/attributioncheck.sh                 the commits not yet on origin/main
#                                             (falls back to HEAD when the
#                                             remote branch is unknown)
#   tools/attributioncheck.sh <range|rev>     what git log takes
#   tools/attributioncheck.sh --msg-file F    one message file (git commit-msg
#                                             hook: tools/git-hooks/commit-msg)
#   tools/attributioncheck.sh --text          a message body on stdin (CI reads
#                                             a PR description through it)
#
# Exit 1 naming each offending commit (or the offending lines), 0 when clean.
# Make target: attributioncheck (in the ci gate). CI: the attribution job in
# .github/workflows/tests.yml runs it over the pushed or PR range with full
# history, because the test job's shallow checkout has no range to scan.
set -eu
pattern='Claude-Session:|claude\.ai/code/session_|Co-Authored-By:.*[Cc]laude|Generated with \[?Claude Code|noreply@anthropic\.com'

scan_text() {  # stdin -> offending lines on stdout; status 1 if any
  grep -En "$pattern" || return 1
}

case "${1:-}" in
  --msg-file)
    if hits=$(scan_text < "$2"); then
      echo "attributioncheck: the commit message carries AI attribution:" >&2
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      exit 1
    fi
    exit 0 ;;
  --text)
    if hits=$(scan_text); then
      echo "attributioncheck: the text carries AI attribution:" >&2
      printf '%s\n' "$hits" | sed 's/^/  /' >&2
      exit 1
    fi
    exit 0 ;;
esac

if [ $# -ge 1 ]; then
  range="$1"
elif git rev-parse --verify -q origin/main >/dev/null 2>&1; then
  range="origin/main..HEAD"
else
  range="HEAD"
fi

bad=$(git log --format='%H' -E --grep="$pattern" "$range" 2>/dev/null || true)
if [ -n "$bad" ]; then
  echo "attributioncheck: commit(s) in $range carry AI attribution (a Claude-Session" >&2
  echo "  trailer, claude.ai session link, Co-Authored-By: Claude, or Generated-with footer):" >&2
  for c in $bad; do
    printf '  %s %s\n' "$(git log -1 --format='%h' "$c")" "$(git log -1 --format='%s' "$c")" >&2
    git log -1 --format='%B' "$c" | grep -En "$pattern" | sed 's/^/      /' >&2
  done
  echo "  Reword the message(s) (amend, or an interactive rebase) and push again." >&2
  exit 1
fi
n=$(git rev-list --count "$range" 2>/dev/null || echo 0)
echo "attributioncheck: $n commit(s) in $range carry no AI attribution"
