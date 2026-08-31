#!/usr/bin/env bash
# Compare the branch-protection rules GitHub actually enforces against what
# reported on a commit. Measured on PR #106: `check-runs` returns 14, not the
# 13 `security.yml` believes are required — the extra one is `Analyze
# (python)` (CodeQL, enabled through GitHub's default setup), with no workflow
# file and no mention anywhere in this tree (#122).
#
# ⚠️ LIVE MODE IS NOT WIRED INTO ANY WORKFLOW, ON PURPOSE. `GET
# /repos/{owner}/{repo}/rules/branches/{branch}` returns RULESETS — a
# DIFFERENT API from the classic branch protection this repository actually
# has today (main has been protected since 2026-08-20 via classic protection,
# not a ruleset). Against the real repo that endpoint legitimately answers
# `[]` with HTTP 200 until an admin adds a ruleset in
# Settings → Rules → Rulesets — an action outside this script's, and this
# PR's, reach. Wiring a live step into ci.yml/security.yml before that exists
# would fail-closed on every future PR, forever, for a reason no PR here can
# fix. So: ship the check + its offline self-test now; wire a live workflow
# step only after a ruleset exists on `main` (a follow-up, gated on that admin
# step) — see #122.
#
# An EMPTY rulesets response must be read as "not verifiable", never as
# "nothing is required": `[]`+200 is indistinguishable from a real ruleset
# with zero required contexts, and passing it as clean would make this check
# green for the same reason main's classic protection is invisible to it
# today. That is exactly what the self-test below proves.
#
# Usage:
#   check-required-checks.sh --self-test              # offline, task test-scripts
#   check-required-checks.sh <owner> <repo> [ref]      # live — needs GITHUB_TOKEN/GH_TOKEN
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HERE/testdata/check-required-checks"

# The diff itself — one place, exercised by both modes. Prints what differs
# and exits non-zero on any difference, INCLUDING an unreadable rulesets
# response (see the header: `[]` must fail loud, never pass as "nothing
# required").
diff_checks() {
  local rulesets_file="$1" checkruns_file="$2"
  python3 - "$rulesets_file" "$checkruns_file" <<'PY'
import json, sys

rulesets_path, checkruns_path = sys.argv[1], sys.argv[2]
rulesets = json.load(open(rulesets_path))
checkruns = json.load(open(checkruns_path))

rule = next((r for r in rulesets if r.get("type") == "required_status_checks"), None)
required_checks = (rule or {}).get("parameters", {}).get("required_status_checks") or []
if not required_checks:
    print("✗ not verifiable — no required_status_checks rule in the rulesets response. "
          "This is NOT \"nothing is required\": classic branch protection is invisible "
          "to this endpoint, and an empty ruleset list reads identically to a real one "
          "declaring zero required contexts. Put a ruleset on main "
          "(Settings -> Rules -> Rulesets), then re-run.")
    sys.exit(2)

required = {c["context"] for c in required_checks}
reported = {c["name"] for c in checkruns.get("check_runs", [])}

missing = sorted(required - reported)   # required, but did not report on this commit
extra = sorted(reported - required)     # reported, but not required

for name in missing:
    print(f"✗ required but did not report on this commit: {name}")
for name in extra:
    print(f"✗ reported on this commit but not required: {name}")

if missing or extra:
    sys.exit(1)
print(f"OK — {len(required)} required checks, all and only what reported")
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
  echo "=== check-required-checks.sh --self-test (offline) ==="
  fail=0

  echo "--- 13 required vs. 14 reported (a CodeQL-shaped extra) — must differ ---"
  if diff_checks "$FIXTURES/rulesets-sample.json" "$FIXTURES/check-runs-sample.json"; then
    echo "✗ expected a mismatch — the fixture's 14th check, Analyze (python), is not required — got none" >&2
    fail=1
  else
    echo "✓ correctly flagged the unrequired extra"
  fi

  echo "--- empty rulesets response — must fail loud, never pass as \"nothing required\" ---"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo '[]' > "$tmp/empty-rulesets.json"
  if diff_checks "$tmp/empty-rulesets.json" "$FIXTURES/check-runs-sample.json"; then
    echo "✗ an empty rulesets response must refuse, not pass as clean" >&2
    fail=1
  else
    echo "✓ correctly refused as not verifiable"
  fi

  echo
  [ "$fail" -eq 0 ] || { echo "self-test FAILED"; exit 1; }
  echo "OK — the diff logic catches an unrequired extra AND refuses on an empty rulesets response."
  exit 0
fi

# --- Live mode -------------------------------------------------------------
# Deliberately called by nothing in this repository — see the header.
OWNER="${1:?usage: check-required-checks.sh <owner> <repo> [ref] | --self-test}"
REPO="${2:?usage: check-required-checks.sh <owner> <repo> [ref] | --self-test}"
REF="${3:-main}"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
[ -n "$TOKEN" ] || echo "⚠ no GITHUB_TOKEN/GH_TOKEN: 60 requests an hour from a shared IP." >&2
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer ${TOKEN}")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/rules/branches/${REF}" > "$tmp/rulesets.json"
curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${OWNER}/${REPO}/commits/${REF}/check-runs?per_page=100" > "$tmp/check-runs.json"

diff_checks "$tmp/rulesets.json" "$tmp/check-runs.json"
