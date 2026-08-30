#!/usr/bin/env bash
# Unit tests for #118: check-dead-references.sh, against an isolated,
# throwaway git repo — never this one, so the fixtures cannot collide with a
# real path and the test needs no network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$ROOT/scripts/dev/check-dead-references.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

fixture_repo() { # sets up $TMP/repo, a fresh throwaway git repo
  rm -rf "$TMP/repo"
  mkdir -p "$TMP/repo/scripts" "$TMP/repo/docs"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" config user.email test@example.invalid
  git -C "$TMP/repo" config user.name test
}
commit() { git -C "$TMP/repo" add -A && git -C "$TMP/repo" commit -q -m fixture; }

echo "=== Markdown: a fenced code block citing a missing path is flagged ==="

fixture_repo
printf '# doc\n\n```\nscripts/gone.sh --help\n```\n' >"$TMP/repo/docs/a.md"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing path inside a fence fails (rc=${rc})" ||
  bad "a missing path inside a fence passed"
grep -q 'scripts/gone.sh' <<<"$out" && ok "the missing path is named" ||
  bad "the missing path is never named: ${out}"

echo
echo "=== Markdown: an inline backtick span citing a missing path is flagged ==="

fixture_repo
printf 'Run `scripts/gone.sh` first.\n' >"$TMP/repo/docs/a.md"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing path in a backtick span fails (rc=${rc})" ||
  bad "a missing path in a backtick span passed"

echo
echo "=== Markdown: plain prose is never checked, even path-shaped ==="

fixture_repo
printf 'scripts/gone.sh used to exist, with no backticks or fence around it.\n' \
  >"$TMP/repo/docs/a.md"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "plain prose outside fences/backticks is not checked (rc=0)" ||
  bad "plain prose was checked — false positive: ${out}"

echo
echo "=== Markdown: link text before an external URL is not a local claim ==="

fixture_repo
printf 'See [\x60docs/gone.md\x60](https://example.invalid/docs/gone.md) upstream.\n' \
  >"$TMP/repo/docs/a.md"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "backtick text that is an external link's label is not checked (rc=0)" ||
  bad "an external link's own label was flagged — false positive: ${out}"

echo
echo "=== Code: a comment line citing a missing path is flagged, code itself is not ==="

fixture_repo
printf '#!/usr/bin/env bash\n# see scripts/gone.sh for details\nscripts/gone.sh --run\n' \
  >"$TMP/repo/scripts/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing path in a comment fails (rc=${rc})" ||
  bad "a missing path in a comment passed"
[ "$(grep -c 'scripts/gone.sh' <<<"$out")" -eq 1 ] && ok "only the comment line is reported, not the code line" ||
  bad "reported more than the one comment line: ${out}"

echo
echo "=== Code: a printed string citing a missing path is flagged ==="

fixture_repo
printf '#!/usr/bin/env bash\necho "read scripts/gone.sh first"\n' >"$TMP/repo/scripts/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing path in a printed string fails (rc=${rc})" ||
  bad "a missing path in a printed string passed"

echo
echo "=== Code: an HCL heredoc description body is checked ==="

fixture_repo
cat >"$TMP/repo/scripts/a.tf" <<'EOF'
variable "x" {
  description = <<-EOT
    See docs/gone.md for details.
  EOT
}
EOF
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a missing path in an HCL description heredoc fails (rc=${rc})" ||
  bad "a missing path in a description heredoc passed"

echo
echo "=== Code: a line WRITING a path (redirect) is a fixture, not a claim ==="

fixture_repo
printf '#!/usr/bin/env bash\n# fixture setup\nprintf x >"$TMP/repo/scripts/gone.sh"\n' \
  >"$TMP/repo/scripts/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a redirect target is not checked (rc=0)" ||
  bad "a test fixture's own redirect target was flagged — false positive: ${out}"

echo
echo "=== \${path.module}/... resolves relative to the citing file, not repo root ==="

fixture_repo
mkdir -p "$TMP/repo/scripts/sub"
printf 'x' >"$TMP/repo/scripts/sub/here.sh"
printf '#!/usr/bin/env bash\n# see ${path.module}/here.sh\n' >"$TMP/repo/scripts/sub/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a \${path.module} reference resolves next to its own file (rc=0)" ||
  bad "a real \${path.module} sibling was reported missing: ${out}"

echo
echo "=== apps/... is a separate repository, always out of scope ==="

fixture_repo
printf '#!/usr/bin/env bash\n# see apps/base/does/not/exist.yaml\n' >"$TMP/repo/scripts/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "an apps/ path is never checked, even absent (rc=0)" ||
  bad "an apps/ path was checked against this checkout: ${out}"

echo
echo "=== a gitignored path is expected to not exist yet, not a defect ==="

fixture_repo
printf 'infrastructure/opentofu/cluster/envs/*.tfvars\n' >"$TMP/repo/.gitignore"
printf '#!/usr/bin/env bash\n# copy infrastructure/opentofu/cluster/envs/real.tfvars\n' \
  >"$TMP/repo/scripts/a.sh"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a gitignored path is not reported missing (rc=0)" ||
  bad "a gitignored, not-yet-created path was flagged — false positive: ${out}"

echo
echo "=== .deadreferencesignore suppresses one file:candidate pair, not the path everywhere ==="

fixture_repo
printf '#!/usr/bin/env bash\n# see docs/gone.md\n' >"$TMP/repo/scripts/a.sh"
printf '#!/usr/bin/env bash\n# see docs/gone.md\n' >"$TMP/repo/scripts/b.sh"
printf '# reason\nscripts/a.sh:docs/gone.md\n' >"$TMP/repo/.deadreferencesignore"
commit
out="$("$CHECKER" "$TMP/repo" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "the un-listed file:candidate pair still fails (rc=${rc})" ||
  bad "the ignore file silenced a file it does not name"
grep -q 'scripts/a.sh' <<<"$out" && bad "the ignored pair was still reported: ${out}" ||
  ok "the ignored pair (scripts/a.sh) is not reported"
grep -q 'scripts/b.sh' <<<"$out" && ok "the same candidate in another file is still reported" ||
  bad "scripts/b.sh's own citation was silenced too — over-broad ignore: ${out}"

echo
echo "=== proof against reality: this repository's own tree is clean today ==="

out="$("$CHECKER" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "every reference in THIS repo resolves (rc=0)" ||
  bad "this repository has a dead reference the checker caught: ${out}"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
