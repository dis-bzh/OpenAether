#!/usr/bin/env bash
# The trailer check reads the MESSAGE. Nothing read who git says wrote the
# commit — and that is where the tool identity actually enters. Seventeen of the
# fifty commits on main carry `Co-authored-by: Claude <noreply@anthropic.com>`
# while none of them is authored by a tool: GitHub synthesises that trailer AT
# SQUASH TIME from the branch commits, and the branch is where the author sits
# (measured on PR #106 — its 0764f61 is authored by Claude). So the message
# checks can never see it: by the time the trailer exists, the commit is on
# main. Only the author field says it, and only before the merge.
#
# Same rule as the trailer: a model is not an author. The human submitting is.
#
# Usage: check-commit-authors.sh <rev-range>
set -euo pipefail

range="${1:?usage: check-commit-authors.sh <rev-range>}"
tools='claude|copilot|chatgpt|gpt-[0-9]|gemini|cursor|codex|devin|aider|noreply@anthropic\.com|users\.noreply\.github\.com/copilot'

# `git log` written to a file first, not read from a process substitution: a
# failure inside `< <(...)` (a malformed rev-range, say) does not propagate
# through `set -e` — the pipeline it fails in is not a simple command `set -e`
# tracks — so the `while read` loop would just see EOF, run zero iterations,
# and this script would print its own success line over a check that never
# ran (#132). A file's exit status is the ordinary kind.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if ! git log --format='%H%x09%an <%ae>%x09%cn <%ce>' "$range" > "$tmp"; then
  echo "✗ git log $range failed — commit authors could not be checked" >&2
  exit 1
fi

bad=0
while IFS=$'\t' read -r sha ident _committer; do
  [ -n "$sha" ] || continue
  if grep -qiE "$tools" <<<"$ident"; then
    echo "✗ $sha is authored by a tool: $ident" >&2
    bad=1
  fi
done < "$tmp"

if [ "$bad" -eq 1 ]; then
  cat >&2 <<'EOT'

  A model is not an author. Set the commit's author to the person submitting:

      git commit --amend --author="Your Name <you@example.com>"
      git rebase --exec 'git commit --amend --no-edit --reset-author' <base>

  Disclose the assistance with the `Assisted-by:` trailer instead.
  CONTRIBUTING.md → AI-assisted contributions.
EOT
  exit 1
fi
echo "✓ no commit in $range is authored by a tool"
