#!/usr/bin/env bash
# ==============================================================================
# OpenAether — DRP Management Cluster
#
# Reconstructs the management cluster on a fallback provider when the primary
# (Scaleway) management cluster is unreachable.
#
# Target RTO: ~30 minutes (Phase 3). Will improve to <5 min in Phase 4b.
#
# Usage:
#   ./scripts/drp-management.sh <provider>
#   task drp PROVIDER=ovh
#
# Supported fallback providers: ovh, outscale
#
# Prerequisites:
#   - tofu CLI available
#   - Credentials for fallback provider exported (OS_* for OVH, OSC_* for Outscale)
#   - S3 access to backup bucket (primary tfstate, via AWS_ACCESS_KEY_ID/SECRET)
#   - Talos image pre-uploaded on fallback provider
# ==============================================================================
set -euo pipefail

PROVIDER="${1:-${PROVIDER:-}}"

if [[ -z "$PROVIDER" ]]; then
  echo "Usage: $0 <provider>"
  echo "       Supported: ovh, outscale"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOFU_DIR="${SCRIPT_DIR}/../infrastructure/opentofu"
ENVFILE="${TOFU_DIR}/envs/drp-${PROVIDER}.tfvars"

if [[ ! -f "${ENVFILE}" ]]; then
  echo "❌ DRP env file not found: ${ENVFILE}"
  echo "   Create it from the template:"
  echo "     cp ${TOFU_DIR}/envs/drp-${PROVIDER}.tfvars.example ${ENVFILE}"
  echo "   then fill in your fallback provider config."
  exit 1
fi

echo "🚨 OpenAether DRP — Rebuilding management cluster on ${PROVIDER}"
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
tofu init -reconfigure
tofu apply -var-file="${ENVFILE}" -auto-approve

BASTION_IP=$(tofu output -raw bastion_ip)
CONTROL_PLANE_IPS=$(tofu output -json control_plane_private_ips)

echo "  ✅ Infrastructure ready"
echo "     Bastion: ${BASTION_IP}"
echo "     Control planes: ${CONTROL_PLANE_IPS}"

# ─── Phase 2: SSH Tunnels ──────────────────────────────────────────────────────
echo ""
echo "▶ Phase 2: Establishing SSH tunnels for Talos bootstrap..."
echo "   Opening tunnels to control planes via bastion ${BASTION_IP}..."

TUNNEL_PIDS=()
PORT=50000
for ip in $(echo "${CONTROL_PLANE_IPS}" | jq -r '.[]'); do
  echo "   Tunnel: localhost:${PORT} → ${ip}:50000 via ${BASTION_IP}"
  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 \
    -L "${PORT}:${ip}:50000" \
    "ubuntu@${BASTION_IP}" -N &
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

# ─── Phase 4: Verify & Instructions ──────────────────────────────────────────
echo ""
echo "▶ Phase 4: Cluster health check..."
export TALOSCONFIG="${TOFU_DIR}/talosconfig"
export KUBECONFIG="${TOFU_DIR}/kubeconfig"

talosctl health --endpoints 127.0.0.1 || echo "  ⚠️  Health check failed — cluster may still be initializing"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ DRP complete — Management cluster rebuilt on ${PROVIDER}"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. ArgoCD is bootstrapping — wait ~10 min for Git sync to complete"
echo "  2. Monitor: kubectl -n management-gitops get applications"
echo "  3. Re-register spoke clusters:"
echo "     for provider in scw ovh outscale; do"
echo "       task register-spoke CLUSTER=openaether-\${provider}-prod PROVIDER=\${provider}"
echo "     done"
echo ""
echo "  4. Update DNS for management endpoints (manual until Phase 4 ExternalDNS)"
echo ""
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  TALOSCONFIG=${TALOSCONFIG}"
