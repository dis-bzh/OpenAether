#!/usr/bin/env bash
# OpenAether — failover management cluster (cross-provider).
#
# Stands up a SECOND management on a DIFFERENT cloud when the primary provider
# is unreachable. Re-running your own management on the same provider is the
# everyday recovery; this is the cross-provider case. Target RTO ~30 min.
#
# Usage: failover-management.sh <provider>   |   task failover PROVIDER=ovh
#   Needs the fallback provider's credentials, S3 access to the primary
#   tfstate, and its Talos image already published.
set -euo pipefail

PROVIDER="${1:-${PROVIDER:-}}"

if [[ -z "$PROVIDER" ]]; then
  echo "Usage: $0 <provider>"
  echo "       Supported: scaleway, ovh, outscale, proxmox (pick one that is NOT your primary)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ../.. — this script lives in scripts/bootstrap/, not scripts/. With a single
# `..` it resolved to scripts/infrastructure/opentofu/cluster, so the guard
# below always fired and printed a path that cannot exist. Four sibling
# scripts were addressed the same wrong way; they live in internal/ and ops/.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOFU_DIR="${REPO_ROOT}/infrastructure/opentofu/cluster"
ENVFILE="${TOFU_DIR}/envs/failover-${PROVIDER}.tfvars"

if [[ ! -f "${ENVFILE}" ]]; then
  echo "❌ Failover env file not found: ${ENVFILE}"
  echo "   Create it from the template:"
  echo "     cp ${TOFU_DIR}/envs/failover-${PROVIDER}.tfvars.example ${ENVFILE}"
  echo "   then fill in your failover provider config."
  exit 1
fi

echo "🚨 OpenAether Failover — Standing up a management cluster on ${PROVIDER}"
echo "   Env file: ${ENVFILE}"
echo ""
echo "⚠️  This will deploy a NEW management cluster. Workload clusters continue"
echo "   running independently. ETA: ~30 minutes."
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

cd "${TOFU_DIR}"

# ─── Phase 1: Infrastructure ──────────────────────────────────────────────────
echo ""
echo "▶ Phase 1: Provisioning infrastructure on ${PROVIDER}..."
# Ensure the backup buckets exist before init (the S3 backend won't create them).
"${REPO_ROOT}/scripts/internal/ensure-buckets.sh" "${ENVFILE}"
# Partial backend derived from the tfvars (single source of truth): the failover
# cluster's state lives on its own provider, reachable when the primary is down.
tofu init -reconfigure $("${REPO_ROOT}/scripts/internal/tf-backend.sh" "${ENVFILE}")
tofu apply -var-file="${ENVFILE}" -auto-approve

BASTION_IP=$(tofu output -raw bastion_ip)
BASTION_USER=$(tofu output -raw bastion_user)
CONTROL_PLANE_IPS=$(tofu output -json control_plane_private_ips)

echo "  ✅ Infrastructure ready"
echo "     Bastion: ${BASTION_USER}@${BASTION_IP}"
echo "     Control planes: ${CONTROL_PLANE_IPS}"

# ─── Phase 2: SSH Tunnels ──────────────────────────────────────────────────────
echo ""
echo "▶ Phase 2: Establishing SSH tunnels for Talos bootstrap..."
echo "   Opening tunnels to control planes via bastion ${BASTION_IP}..."

TUNNEL_PIDS=()
PORT=50000
for ip in $(echo "${CONTROL_PLANE_IPS}" | jq -r '.[]'); do
  echo "   Tunnel: localhost:${PORT} → ${ip}:50000 via ${BASTION_USER}@${BASTION_IP}"
  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 \
    -L "${PORT}:${ip}:50000" \
    "${BASTION_USER}@${BASTION_IP}" -N &
  TUNNEL_PIDS+=($!)
  PORT=$((PORT + 1))
done

trap "echo 'Closing SSH tunnels...'; kill ${TUNNEL_PIDS[*]} 2>/dev/null || true" EXIT

echo "   Waiting for tunnels to stabilize..."
sleep 5

# ─── Phase 3: Talos Bootstrap ─────────────────────────────────────────────────
echo ""
echo "▶ Phase 3: Applying Talos configuration and bootstrapping cluster..."
tofu apply -var-file="${ENVFILE}" -var talos_bootstrap=true -auto-approve

echo "  ✅ Talos cluster bootstrapped"

# Replicate the rebuilt cluster's (encrypted) state to its -backup store. Set
# BACKUP_AWS_* to the recovering primary's creds to push it back there.
"${REPO_ROOT}/scripts/ops/backup-state.sh" "${TOFU_DIR}" || echo "  ⚠️  state replication skipped"

# ─── Phase 4: Verify & Instructions ──────────────────────────────────────────
echo ""
echo "▶ Phase 4: Cluster health check..."
export TALOSCONFIG="${TOFU_DIR}/talosconfig"
export KUBECONFIG="${TOFU_DIR}/kubeconfig"

talosctl health --endpoints 127.0.0.1 || echo "  ⚠️  Health check failed — cluster may still be initializing"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ Failover complete — Management cluster running on ${PROVIDER}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Flux is bootstrapping — wait ~10 min for Git sync to complete"
echo "  2. Monitor: kubectl -n management-gitops get applications"
echo "  3. Re-register spoke clusters:"
echo "     for provider in scaleway ovh outscale; do"
echo "       task register-spoke CLUSTER=openaether-\${provider}-prod PROVIDER=\${provider}"
echo "     done"
echo ""
echo "  4. Update DNS for management endpoints (manual until Phase 4 ExternalDNS)"
echo ""
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  TALOSCONFIG=${TALOSCONFIG}"
