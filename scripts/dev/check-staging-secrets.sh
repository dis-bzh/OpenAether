#!/usr/bin/env bash
# Say whether the credentialed lane can actually run, and name what is missing.
#
# `.github/workflows/staging.yml` was merged with none of its secrets configured
# and no `staging` environment at all, so its first scheduled fire would have
# died on an empty blob. Nothing said so — a workflow that has never run looks
# exactly like one that passes. This turns that into a command.
#
# Reads names only. It never prints a value, and GitHub would not return one.
#
# Usage: check-staging-secrets.sh [environment]     (default: staging)
set -euo pipefail

ENVIRONMENT="${1:-staging}"
WORKFLOW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/workflows/staging.yml"

command -v gh >/dev/null || { echo "✗ gh is not installed" >&2; exit 1; }

# The required set is READ FROM THE WORKFLOW, not restated here: a hardcoded list
# would drift the first time someone adds a secret, and pass while the lane broke.
mapfile -t REQUIRED < <(
  grep -oE 'secrets\.[A-Z0-9_]+' "$WORKFLOW" | cut -d. -f2 | grep -v '^GITHUB_TOKEN$' | sort -u
)
[ "${#REQUIRED[@]}" -gt 0 ] || { echo "✗ read no secret names from $WORKFLOW" >&2; exit 1; }

if ! gh api "repos/:owner/:repo/environments/${ENVIRONMENT}" >/dev/null 2>&1; then
  echo "✗ no '${ENVIRONMENT}' environment on this repository."
  echo "  gh api -X PUT repos/:owner/:repo/environments/${ENVIRONMENT}"
  exit 1
fi

mapfile -t PRESENT < <(gh secret list --env "$ENVIRONMENT" --json name -q '.[].name' 2>/dev/null | sort)

MISSING=()
for name in "${REQUIRED[@]}"; do
  printf '%s\n' "${PRESENT[@]}" | grep -qx "$name" || MISSING+=("$name")
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  echo "✓ ${ENVIRONMENT}: all ${#REQUIRED[@]} secrets set"
  exit 0
fi

echo "✗ ${ENVIRONMENT}: ${#MISSING[@]} of ${#REQUIRED[@]} secrets missing — the lane cannot run."
echo
for name in "${MISSING[@]}"; do
  echo "  gh secret set ${name} --env ${ENVIRONMENT}"
done
echo
echo "The three STAGING_TFVARS_B64_* are one base64 blob per provider, each built"
echo "from the matching envs/<role>-<provider>.tfvars.example and each pinning"
echo "talos_version / kubernetes_version ONE PATCH BELOW cluster/variables.tf —"
echo "that gap is what the upgrade stage moves. Build one with:"
echo "  base64 -w0 < infrastructure/opentofu/cluster/envs/management-scaleway.tfvars"
exit 1
