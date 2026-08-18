#!/usr/bin/env bash
# ==============================================================================
# The backup store is only a backup if it is somewhere else. This measures the
# credential resolution that decides WHERE the copy actually lands.
#
# The trap it exists for: s3_cred falls back to the PRIMARY keys when no backup
# ones are set. That fallback is right for a single-provider cluster and quietly
# wrong for a cross-provider one — the copy then authenticates as provider A
# against provider B, and the only trace used to be one ⚠ in a wall of output.
#
# The variables are namespaced by the CLUSTER's provider, not the backup's:
# a Scaleway cluster backing up to OVH puts the OVH key in SCW_BACKUP_AWS_*.
# Counter-intuitive, load-bearing, and asserted here so it cannot drift.
#
# Offline. No cloud, no account, no bill.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source scripts/lib/common.sh

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
is()  { # <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"
}

clear_env() {
  unset SCW_AWS_ACCESS_KEY_ID SCW_AWS_SECRET_ACCESS_KEY SCW_ACCESS_KEY SCW_SECRET_KEY \
        SCW_BACKUP_AWS_ACCESS_KEY_ID SCW_BACKUP_AWS_SECRET_ACCESS_KEY \
        OVH_AWS_ACCESS_KEY_ID OVH_BACKUP_AWS_ACCESS_KEY_ID \
        BACKUP_AWS_ACCESS_KEY_ID BACKUP_AWS_SECRET_ACCESS_KEY 2>/dev/null || true
}

echo "--- the namespaced backup key wins ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A SCW_BACKUP_AWS_ACCESS_KEY_ID=KEY-OF-B
is "a Scaleway cluster backing up elsewhere uses SCW_BACKUP_AWS_* for the copy" \
   "KEY-OF-B" "$(s3_cred scaleway backup ak)"
is "and the primary still uses SCW_AWS_* for itself" \
   "KEY-OF-A" "$(s3_cred scaleway primary ak)"

echo "--- the generic name is the second choice, not the first ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A BACKUP_AWS_ACCESS_KEY_ID=GENERIC-B
is "with no namespaced key, the generic BACKUP_AWS_* is used" \
   "GENERIC-B" "$(s3_cred scaleway backup ak)"
export SCW_BACKUP_AWS_ACCESS_KEY_ID=NAMESPACED-B
is "the namespaced one outranks the generic" \
   "NAMESPACED-B" "$(s3_cred scaleway backup ak)"

echo "--- the fallback: silent, correct for one provider, wrong for two ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A
BK="$(s3_cred scaleway backup ak)"
is "with no backup key at all, the copy is written with the PRIMARY's key" "KEY-OF-A" "$BK"
# The assertion that matters: this is INDISTINGUISHABLE from a configured backup,
# so nothing downstream can infer intent from the credentials alone. Whether the
# store is really elsewhere has to be decided from the ENDPOINTS, which is what
# scripts/internal/ensure-buckets.sh now does before creating anything.
if [ "$BK" = "$(s3_cred scaleway primary ak)" ]; then
  ok "and it is byte-identical to the primary's — so intent CANNOT be read from the keys"
else
  bad "the fallback no longer matches the primary; ensure-buckets' endpoint test may now be wrong"
fi

echo "--- one provider's backup key never leaks into another's ---"
clear_env
export SCW_AWS_ACCESS_KEY_ID=KEY-OF-A OVH_BACKUP_AWS_ACCESS_KEY_ID=OVH-ONLY
is "an OVH backup key is not served to a Scaleway cluster" \
   "KEY-OF-A" "$(s3_cred scaleway backup ak)"

echo "--- secrets resolve down the same chain as keys ---"
clear_env
export SCW_SECRET_KEY=SECRET-OF-A SCW_BACKUP_AWS_SECRET_ACCESS_KEY=SECRET-OF-B
is "the backup secret comes from SCW_BACKUP_AWS_SECRET_ACCESS_KEY" \
   "SECRET-OF-B" "$(s3_cred scaleway backup sk)"
is "and the primary secret still falls back to SCW_SECRET_KEY" \
   "SECRET-OF-A" "$(s3_cred scaleway primary sk)"

echo "--- the three shapes ensure-buckets.sh must tell apart ---"
# A stub `aws` stands in for the object stores: no account, no bill, and it can
# be made to refuse one endpoint, which is the case that matters.
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mk_stub() { # <endpoint-that-succeeds, or "all">
  if [ "$1" = all ]; then printf '#!/usr/bin/env bash\nexit 0\n' >"$SB/aws"
  else
    printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in %s*) exit 0 ;; esac; done\n' "$1" >"$SB/aws"
    printf 'for a in "$@"; do case "$a" in https://*) exit 255 ;; esac; done\nexit 0\n' >>"$SB/aws"
  fi
  chmod +x "$SB/aws"
}
mk_tfvars() { # <replica-endpoint> → path
  sed -E "s#^s3_primary_endpoint.*#s3_primary_endpoint = \"https://primary.example\"#;
          s#^s3_primary_region.*#s3_primary_region = \"r1\"#;
          s#^s3_replica_endpoint.*#s3_replica_endpoint = \"$1\"#;
          s#^s3_replica_region.*#s3_replica_region = \"r2\"#" \
    infrastructure/opentofu/cluster/envs/management-scaleway.tfvars.example >"$SB/t.tfvars"
  printf '%s' "$SB/t.tfvars"
}
run_ensure() { env -u SCW_BACKUP_AWS_ACCESS_KEY_ID -u SCW_BACKUP_AWS_SECRET_ACCESS_KEY \
  PATH="$SB:$PATH" SCW_AWS_ACCESS_KEY_ID=A SCW_AWS_SECRET_ACCESS_KEY=A \
  ./scripts/internal/ensure-buckets.sh "$1" 2>&1; }

mk_stub "https://primary.example"; TF="$(mk_tfvars https://replica.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'Refusing to continue' <<<"$OUT" \
  && ok "a backup asked for on another provider, and not obtainable, REFUSES the deploy" \
  || bad "an unobtainable cross-provider backup exited ${RC} — the deploy would proceed without a copy"
grep -q 'SCW_BACKUP_AWS_ACCESS_KEY_ID' <<<"$OUT" \
  && ok "and it names the variable to set, not just the failure" \
  || bad "the refusal does not say what to do about it"

TF="$(mk_tfvars https://primary.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'SAME endpoint' <<<"$OUT" \
  && ok "one provider, replica alongside: allowed, and stated rather than assumed" \
  || bad "the single-provider shape was refused or went unmentioned (exit ${RC})"

mk_stub all; TF="$(mk_tfvars https://replica.example)"
OUT="$(run_ensure "$TF")"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'DIFFERENT provider' <<<"$OUT" \
  && ok "a cross-provider backup that works: allowed, and reported as elsewhere" \
  || bad "a working cross-provider backup was refused (exit ${RC}) — the guard fires on the normal case"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
