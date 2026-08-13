#!/usr/bin/env bash
# The .claude/skills are duplicated in OpenAether-infra and OpenAether-apps so
# that an agent working in either repository reads the same process. Duplication
# drifts unless something notices, so this compares them byte for byte.
#
# Skips — loudly — when the sibling is not checked out next door, because a
# check that quietly passes when it could not run is the failure mode the skill
# itself is about.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$(basename "$HERE")" in
  OpenAether-infra) SIBLING="$HERE/../OpenAether-apps" ;;
  OpenAether-apps)  SIBLING="$HERE/../OpenAether-infra" ;;
  *) echo "✗ unexpected repository name: $(basename "$HERE")" >&2; exit 1 ;;
esac

if [[ ! -d "$SIBLING/.claude/skills" ]]; then
  echo "↷ skill parity not checked — no $(basename "$SIBLING") checkout beside this one."
  exit 0
fi

# Only the skills listed in .claude/skills/SHARED are duplicated. The others are
# repository-specific on purpose — a provider-module skill has nothing to say in
# OpenAether-apps — and comparing those would fail for the wrong reason.
MANIFEST="$HERE/.claude/skills/SHARED"
[[ -f "$MANIFEST" ]] || { echo "✗ no .claude/skills/SHARED manifest" >&2; exit 1; }

drift=0
shared=0
while IFS= read -r name; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  shared=$((shared + 1))
  f="$HERE/.claude/skills/$name/SKILL.md"
  other="$SIBLING/.claude/skills/$name/SKILL.md"
  if [[ ! -f "$f" ]]; then
    echo "  ✗ $name is in SHARED but missing here"; drift=1
  elif [[ ! -f "$other" ]]; then
    echo "  ✗ $name is missing from $(basename "$SIBLING")"; drift=1
  elif ! diff -q "$f" "$other" >/dev/null; then
    echo "  ✗ $name differs between the two repositories:"
    diff "$f" "$other" | head -10 | sed 's/^/      /'
    drift=1
  fi
done < "$MANIFEST"

if ! diff -q "$MANIFEST" "$SIBLING/.claude/skills/SHARED" >/dev/null 2>&1; then
  echo "  ✗ the SHARED manifests themselves differ"; drift=1
fi

# A shared skill must also be VALID where it is copied: a relative link to a file
# only one repository has passes a byte-for-byte comparison and is still broken on
# the other side. That happened to docs/release-checklist.md.
while IFS= read -r name; do
  [[ -n "$name" && "$name" != \#* ]] || continue
  for side in "$HERE" "$SIBLING"; do
    f="$side/.claude/skills/$name/SKILL.md"
    [[ -f "$f" ]] || continue
    while read -r target; do
      [[ -n "$target" ]] || continue
      [[ -e "$(dirname "$f")/${target%%#*}" ]] || {
        echo "  ✗ $name links $target, which does not exist in $(basename "$side")"; drift=1; }
    done < <(grep -oE '\]\([^)#][^)]*\)' "$f" | sed -E 's/^\]\(//; s/\)$//' \
             | grep -vE '^(https?:|mailto:)')
  done
done < "$MANIFEST"

if [[ $drift -eq 1 ]]; then
  echo "✗ skills have drifted. They are duplicated on purpose — change both." >&2
  exit 1
fi
echo "  ✓ ${shared} shared skill(s) identical in both repositories"
