#!/usr/bin/env bash
# Refuse an authorship trailer naming a tool. See CONTRIBUTING.md, "AI-assisted
# contributions": `Co-Authored-By` asserts authorship and `Signed-off-by`
# certifies origin — a model does neither, so it gets `Assisted-by:` instead.
#
# Matches on the tool names we actually use rather than on "any trailer": a
# human co-author is legitimate and must keep working.
set -euo pipefail

msg="${1:?usage: check-commit-trailers.sh <commit-msg-file>}"
tools='claude|copilot|chatgpt|gpt-[0-9]|gemini|cursor|codex|devin|aider'

if grep -qiE "^(Co-Authored-By|Signed-off-by):.*($tools)" "$msg"; then
  cat >&2 <<'EOT'
✗ authorship trailer naming a tool

  A model is not an author and cannot certify origin. Use instead:

      Assisted-by: Claude Code

  CONTRIBUTING.md → AI-assisted contributions.
EOT
  exit 1
fi
