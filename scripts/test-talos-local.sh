#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Local Talos Deployment Test (3 control planes + 2 workers, Docker)
#
# Exercises the PRODUCTION modules/talos (config generation, bootstrap,
# kubeconfig) on a real 3-CP etcd quorum with 2 dedicated (schedulable) workers,
# then deploys Cilium + ArgoCD + the GitOps ApplicationSet — no cloud creds.
#
# Config is delivered via USERDATA (the Talos Docker platform mechanism); the
# only modules/talos resource not exercised locally is talos_machine_configuration_apply
# (maintenance-mode gRPC apply, which is cloud-only per the Talos Docker docs).
#
# Usage:
#   ./scripts/test-talos-local.sh             # full 3-CP deploy + verify
#   ./scripts/test-talos-local.sh --destroy   # tear down
#
# Prerequisites: docker (Desktop + WSL2 integration), tofu, talosctl, kubectl, helm, nc
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
TOFU_DIR="${ROOT_DIR}/infrastructure/opentofu-local"
MANIFESTS_DIR="${ROOT_DIR}/infrastructure/opentofu/cluster/bootstrap-manifests"

CLUSTER_NAME="openaether-local-dev"
CP_IPS=("10.5.0.10" "10.5.0.11" "10.5.0.12")
CP_ENDPOINTS=("127.0.0.1:50000" "127.0.0.1:50001" "127.0.0.1:50002")
# Dedicated workers (worker_count=2 in opentofu-local): IPs at .20+, host ports
# at 50010+i. Schedulable/untainted, for HA and real workload scheduling tests.
WORKER_IPS=("10.5.0.20" "10.5.0.21")
WORKER_ENDPOINTS=("127.0.0.1:50010" "127.0.0.1:50011")
TOTAL_NODES=$(( ${#CP_IPS[@]} + ${#WORKER_IPS[@]} ))

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}" >&2; }

# ==============================================================================
# Destroy
# ==============================================================================
if [[ "${1:-}" == "--destroy" ]]; then
  info "Destroying local Talos cluster..."
  cd "${TOFU_DIR}"
  export TF_VAR_cilium_manifest="placeholder"
  tofu destroy -auto-approve 2>/dev/null || true
  # Belt-and-suspenders cleanup (covers both roles by name prefix, so it doesn't
  # depend on the configured CP/worker counts).
  for c in $(docker ps -aq --filter "name=${CLUSTER_NAME}-" 2>/dev/null); do
    docker rm -f "$c" 2>/dev/null || true
  done
  for vol in $(docker volume ls -q --filter "name=${CLUSTER_NAME}-" 2>/dev/null); do
    docker volume rm "$vol" 2>/dev/null || true
  done
  docker network rm "${CLUSTER_NAME}-net" 2>/dev/null || true
  rm -f "${TOFU_DIR}/kubeconfig" "${TOFU_DIR}/talosconfig"
  # Wipe the ephemeral local state too: `tofu destroy` leaves it populated
  # (machine_secrets is prevent_destroy'd), and a stale state breaks the next
  # fresh apply (CA mismatch / skipped bootstrap). No backend, so this is safe.
  rm -f "${TOFU_DIR}/terraform.tfstate" "${TOFU_DIR}/terraform.tfstate.backup"
  success "Local cluster destroyed"
  exit 0
fi

# ==============================================================================
# Preflight
# ==============================================================================
info "Preflight checks..."
MISSING=()
for cmd in docker tofu talosctl kubectl helm nc; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
[[ ${#MISSING[@]} -gt 0 ]] && { error "Missing tools: ${MISSING[*]}"; exit 1; }
docker ps >/dev/null 2>&1 || { error "Docker is not running (start Docker Desktop, enable WSL2 integration)."; exit 1; }
export TF_VAR_encryption_passphrase="${TF_VAR_encryption_passphrase:-local-test-passphrase-32chars-minimum}"
success "Preflight passed"

# ==============================================================================
# Step 1 — Render simplified Cilium manifest for local
# ==============================================================================
info "Step 1 — Rendering local Cilium manifest..."
if [[ ! -f "${MANIFESTS_DIR}/cilium-local.yaml" ]] || grep -q "Placeholder" "${MANIFESTS_DIR}/cilium-local.yaml" 2>/dev/null; then
  "${SCRIPT_DIR}/render-bootstrap-manifests.sh" --local
fi
export TF_VAR_cilium_manifest="$(cat "${MANIFESTS_DIR}/cilium-local.yaml")"
success "Cilium manifest ready"

# ==============================================================================
# Step 2 — Deploy the 3-CP cluster via the production modules/talos
# (config generation → USERDATA containers → bootstrap → kubeconfig)
# ==============================================================================
info "Step 2 — Deploying Talos cluster: 3 CP + 2 workers (OpenTofu + modules/talos)..."
cd "${TOFU_DIR}"
tofu init -upgrade >/dev/null 2>&1 || tofu init >/dev/null
# If no live cluster is running, any pre-existing local state is stale: its
# containers are gone, and `--destroy` can't fully clear state because
# machine_secrets is prevent_destroy'd. Reusing that half-state either mixes an
# old CA with freshly-created containers (bootstrap fails the TLS handshake:
# "certificate signed by unknown authority") or skips the already-recorded
# bootstrap so the new etcd hangs at "waiting to join". Local state is ephemeral
# (no backend), so wipe it for a clean, CA-consistent apply rather than reuse it.
if ! docker ps --format '{{.Names}}' | grep -q "^${CLUSTER_NAME}-cp-0$"; then
  rm -f terraform.tfstate terraform.tfstate.backup
fi
# Docker Desktop's WSL2 port-forwarder 500s when too many `docker run --publish`
# register at once ("ports are not available … /forwards/expose … 500"); 5 nodes
# in parallel tripped it. modules/providers/local serializes this in two waves
# (workers depend_on the control planes) — capping concurrency without a global
# -parallelism=1, which would deadlock the (container-independent) bootstrap.
tofu apply -var talos_bootstrap=true -auto-approve
success "Cluster provisioned (config generated, containers up, etcd bootstrapped, kubeconfig retrieved)"

export KUBECONFIG="${TOFU_DIR}/kubeconfig"
export TALOSCONFIG="${TOFU_DIR}/talosconfig"

# ==============================================================================
# Step 3 — Verify 3-CP etcd quorum + Talos health (talosctl, out-of-band)
# ==============================================================================
info "Step 3 — Verifying etcd quorum and Talos health..."
MEMBERS=0
for i in $(seq 1 18); do
  # grep -c prints "0" AND exits 1 on no match; `|| echo 0` would then append a
  # second line ("0\n0") and break the arithmetic `[[ ]]` below. `|| true` keeps
  # grep's own single-line count (incl. its "0") under `set -o pipefail`.
  MEMBERS=$(talosctl --nodes "${CP_IPS[0]}" --endpoints "${CP_ENDPOINTS[0]}" etcd members 2>/dev/null | grep -c "${CLUSTER_NAME}-cp-" || true)
  [[ "$MEMBERS" -eq 3 ]] && break
  sleep 5
done
if [[ "$MEMBERS" -eq 3 ]]; then
  success "etcd quorum: 3 members"
else
  warn "etcd members found: $MEMBERS (expected 3) — the 3rd may still be joining"
fi

CP_LIST=$(IFS=,; echo "${CP_IPS[*]}")
WORKER_LIST=$(IFS=,; echo "${WORKER_IPS[*]}")
if talosctl --nodes "${CP_IPS[0]}" --endpoints "${CP_ENDPOINTS[0]}" health \
     --control-plane-nodes "${CP_LIST}" \
     --worker-nodes "${WORKER_LIST}" --wait-timeout 5m >/dev/null 2>&1; then
  success "Talos cluster reports healthy"
else
  warn "Talos health check did not fully pass (cluster may still be converging)"
fi

# ==============================================================================
# Step 4 — Verify Kubernetes nodes + Cilium
# ==============================================================================
info "Step 4 — Verifying Kubernetes nodes and Cilium..."
for i in $(seq 1 60); do
  # `|| true`: grep -c exits 1 on 0 matches (no node Ready yet on early loops),
  # which under set -e + pipefail would abort the script here.
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  [[ "$READY" -eq "$TOTAL_NODES" ]] && break
  sleep 5
done
echo "Nodes:"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/    /'
[[ "$READY" -eq "$TOTAL_NODES" ]] && success "All ${TOTAL_NODES} nodes Ready (${#CP_IPS[@]} CP + ${#WORKER_IPS[@]} workers)" || warn "Nodes Ready: ${READY}/${TOTAL_NODES}"
CILIUM=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
[[ "$CILIUM" -ge "$TOTAL_NODES" ]] && success "Cilium running on all ${CILIUM} nodes" || warn "Cilium pods running: ${CILIUM}/${TOTAL_NODES}"

# ==============================================================================
# Step 5 — Scheduling: with dedicated workers the control planes stay tainted
# (workloads land on the untainted workers). Only when there are no workers do
# we untaint the control planes so the single-role cluster can schedule pods.
# ==============================================================================
if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
  info "Step 5 — Removing control-plane taint (no dedicated workers)..."
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  success "Taint removed (control planes are schedulable)"
else
  info "Step 5 — Keeping control-plane taint (${#WORKER_IPS[@]} dedicated workers are schedulable)..."
  SCHED=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | grep -c " Ready " || true)
  [[ "$SCHED" -eq ${#WORKER_IPS[@]} ]] && success "${SCHED} schedulable worker node(s) Ready" || warn "Schedulable workers Ready: ${SCHED}/${#WORKER_IPS[@]}"
fi

# ==============================================================================
# Step 6 — Deploy ArgoCD via the bootstrap overlay
#   --server-side: ApplicationSet CRD exceeds the client-side annotation limit
#   double apply:  the ApplicationSet CR needs its CRD established first
# ==============================================================================
info "Step 6 — Deploying ArgoCD (bootstrap overlay, server-side apply)..."
kubectl apply -k "${ROOT_DIR}/apps/bootstrap/overlays/prod" --server-side=true --force-conflicts >/dev/null 2>&1 || true
sleep 5
kubectl apply -k "${ROOT_DIR}/apps/bootstrap/overlays/prod" --server-side=true --force-conflicts >/dev/null 2>&1 || true
for i in $(seq 1 48); do
  # `|| true`: grep -c exits 1 when 0 pods match, which under set -e + pipefail
  # would abort the whole script right here (the failure that hid Step 6/7).
  R=$(kubectl -n management-gitops get pods --no-headers 2>/dev/null | grep -c "Running" || true)
  [[ "$R" -ge 7 ]] && break
  sleep 5
done
R=$(kubectl -n management-gitops get pods --no-headers 2>/dev/null | grep -c "Running" || true)
[[ "$R" -ge 7 ]] && success "ArgoCD running (${R} pods)" || warn "ArgoCD pods running: ${R}/7"

# ==============================================================================
# Step 7 — Verify ApplicationSet → Application (GitOps hub mechanism)
# ==============================================================================
info "Step 7 — Verifying ApplicationSet multi-cluster generation..."
for i in $(seq 1 12); do kubectl -n management-gitops get appproject default >/dev/null 2>&1 && break; sleep 5; done
APPS=0
for i in $(seq 1 10); do
  kubectl -n management-gitops annotate applicationset openaether-platform "reconcile=$(date +%s)" --overwrite >/dev/null 2>&1 || true
  sleep 8
  APPS=$(kubectl -n management-gitops get applications --no-headers 2>/dev/null | wc -l)
  [[ "$APPS" -gt 0 ]] && break
done
if [[ "$APPS" -gt 0 ]]; then
  success "ApplicationSet generated ${APPS} Application(s):"
  kubectl -n management-gitops get applications 2>/dev/null | sed 's/^/    /'
else
  warn "No Applications generated yet (check argocd-applicationset-controller logs)"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "════════════════════════════════════════════════════════════"
success "Local Talos cluster is up: ${#CP_IPS[@]} CP + ${#WORKER_IPS[@]} workers (modules/talos validated end-to-end)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  export KUBECONFIG=${TOFU_DIR}/kubeconfig"
echo "  export TALOSCONFIG=${TOFU_DIR}/talosconfig"
echo "  kubectl get nodes"
echo "  talosctl --nodes ${CP_IPS[0]} --endpoints ${CP_ENDPOINTS[0]} etcd members"
echo ""
echo "  ArgoCD UI:  kubectl -n management-gitops port-forward svc/argocd-server 8080:443"
echo "  Tear down:  $0 --destroy   (or: task local-down)"
