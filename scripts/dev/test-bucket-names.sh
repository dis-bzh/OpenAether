#!/usr/bin/env bash
# Six places build a bucket name. They must agree, or the backend points at a
# bucket nothing created and the apply dies after the network exists.
#
# The derivations live in two languages that cannot import each other:
#   shell  — oa_project / oa_state_bucket / oa_artifact_bucket (lib/common.sh),
#            used by tf-backend.sh, ensure-buckets.sh, infra-verify.sh,
#            restore-artifacts.sh and talos-image.sh, all of which run BEFORE or
#            AROUND OpenTofu;
#   HCL    — local.backup_project in cluster/backup.tf, which names the same
#            buckets from inside the apply.
# Nothing but this file compares them.
#
# Why the suffix exists at all: S3 bucket names are unique across a whole
# provider (Scaleway "in our whole platform", OVH "within OVHcloud", Outscale per
# region), so the hardcoded names were unusable by any second account.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 → $2" || bad "$1 → got '$2', want '$3'"; }

echo "=== oa_project: the namespace, with and without a suffix ==="
eq "no suffix"              "$(oa_project example)"            "example"
eq "empty suffix"           "$(oa_project example '')"         "example"
eq "suffix appended"        "$(oa_project example a1b2c3)"     "example-a1b2c3"
# cluster_name's FIRST segment only — this is why `workload-scaleway` and
# `management-scaleway` share a state bucket, and why a hyphenated name does not
# silently create a second one.
eq "first segment only"     "$(oa_project example-scaleway)"   "example"
eq "first segment + suffix" "$(oa_project example-scaleway z9)" "example-z9"

echo "=== the full bucket names ==="
eq "state, no suffix"    "$(oa_state_bucket "$(oa_project example)" scaleway dev)"        "s3-example-scaleway-tfstate-dev"
eq "state, suffix"       "$(oa_state_bucket "$(oa_project example a1b2c3)" scaleway dev)" "s3-example-a1b2c3-scaleway-tfstate-dev"
eq "artifact, suffix"    "$(oa_artifact_bucket "$(oa_project example a1b2c3)" ovh management prod)" "s3-example-a1b2c3-ovh-management-prod"

echo "=== HCL and shell derive the SAME namespace ==="
# `join("-", compact([...]))` in backup.tf against oa_project here. Reproduced
# rather than executed: running tofu needs a backend and credentials, and this
# file must stay in the credential-free rung.
hcl_project() { # <cluster_name> <bucket_suffix> — mirrors local.backup_project
  local first="${1%%-*}"
  if [ -n "$2" ]; then printf '%s-%s' "$first" "$2"; else printf '%s' "$first"; fi
}
for cn in example example-scaleway my-cluster; do
  for sfx in "" a1b2c3; do
    s="$(oa_project "$cn" "$sfx")"; h="$(hcl_project "$cn" "$sfx")"
    [ "$s" = "$h" ] && ok "cluster_name='${cn}' suffix='${sfx:-<none>}' → both say ${s}" \
      || bad "cluster_name='${cn}' suffix='${sfx:-<none>}': shell says '${s}', HCL says '${h}'"
  done
done

echo "=== backup.tf still derives it the way this file assumes ==="
# The mirror above is only worth anything while the HCL it mirrors is unchanged.
# If someone rewrites local.backup_project, this fails and sends them here.
BT="$ROOT/infrastructure/opentofu/cluster/backup.tf"
if grep -qF 'backup_project        = join("-", compact([split("-", var.cluster_name)[0], var.bucket_suffix]))' "$BT"; then
  ok "backup.tf:local.backup_project is the expression mirrored above"
else
  bad "backup.tf:local.backup_project changed — update hcl_project() here, then re-check every caller"
fi

echo "=== every name is legal on all three providers ==="
# 3-63 characters, lowercase alphanumerics and hyphens, no leading or trailing
# hyphen, no double hyphen (OVH: "must not contain multiple punctuation marks in
# a row"). A leading hyphen in cluster_name would make the project empty and
# yield `s3--scaleway-…`, which OVH rejects.
for name in \
  "$(oa_state_bucket "$(oa_project example a1b2c3)" scaleway dev)" \
  "$(oa_artifact_bucket "$(oa_project example a1b2c3)" outscale management prod)-backup"; do
  if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{1,61})[a-z0-9]$ ]] && [[ ! "$name" =~ -- ]]; then
    ok "${name} is a legal bucket name (${#name} chars)"
  else
    bad "${name} is not a legal bucket name on at least one provider"
  fi
done

echo "=== the variable's own validation matches what the helper accepts ==="
VARS="$ROOT/infrastructure/opentofu/cluster/variables.tf"
if grep -qE 'regex\("\^\[a-z0-9\]\{0,16\}\$"' "$VARS"; then
  ok "bucket_suffix is validated as 0-16 lowercase alphanumerics"
else
  bad "bucket_suffix has no validation, or it no longer matches — an illegal suffix would reach a bucket name"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
