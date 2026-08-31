#!/usr/bin/env bash
# Unit tests for #132: check-commit-authors.sh must fail loud when `git log`
# itself fails, not read a bogus rev-range as "zero commits, all clean".
#
# Against an isolated throwaway git repo, not this one — a bad rev-range
# against THIS repo's own history is one accident away from actually being
# a valid (if unintended) range once this repo has enough commits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-commit-authors.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

repo="$TMP/repo"
rm -rf "$repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email human@example.invalid
git -C "$repo" config user.name "A Human"
echo one > "$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m "first"
echo two > "$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m "second"

echo "=== a bogus rev-range fails loud, not silently clean ==="

out="$(cd "$repo" && "$CHECKER" "not-a-real-ref..HEAD" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a malformed rev-range is a hard failure (rc=${rc})" ||
  bad "a malformed rev-range exited 0 — the #132 regression"
grep -qi "could not be checked\|failed" <<<"$out" && ok "the failure says the check did not run" ||
  bad "no failure explanation in output: ${out}"
grep -qi "no commit.*is authored by a tool" <<<"$out" &&
  bad "printed the SUCCESS line despite git log failing — exactly #132" ||
  ok "the success line is not printed on a failed git log"

echo
echo "=== a valid range with a human-authored commit passes ==="

out="$(cd "$repo" && "$CHECKER" "HEAD~1..HEAD" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a human-authored commit passes (rc=0)" ||
  bad "a clean range failed: ${out}"

echo
echo "=== a tool-authored commit is caught ==="

git -C "$repo" config user.email "noreply@anthropic.com"
git -C "$repo" config user.name "Claude"
echo three > "$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m "third"
git -C "$repo" config user.email human@example.invalid
git -C "$repo" config user.name "A Human"

out="$(cd "$repo" && "$CHECKER" "HEAD~1..HEAD" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a tool-authored commit fails the check (rc=${rc})" ||
  bad "a tool-authored commit passed"
grep -qi "authored by a tool" <<<"$out" && ok "it says which commit and why" ||
  bad "no explanation: ${out}"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
