#!/usr/bin/env bash
# OpenAether 0.5.0 — test e2e sprint 0 OpenBao (root + workload)
# Usage: KUBECONFIG=$PWD/infrastructure/opentofu-local/kubeconfig bash scripts/test-sprint0-openbao.sh
#
# Self-contained: n'exige PAS le CLI `bao` en local. Tout passe par l'API HTTP
# OpenBao (curl via port-forward + wget in-pod avec BAO_ADDR=http://127.0.0.1:8200).
# Raison: l'image openbao/openbao défaut le CLI sur HTTPS → `bao status` in-pod
# échoue contre un listener HTTP si BAO_ADDR n'est pas forcé en http.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

export ROOT_NS="foundation-pki-root"
export WORKLOAD_NS="foundation-vault"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Helpers HTTP (port-forward) ────────────────────────────────────
# pf_open NS POD LOCALPORT → exporte PF_PID
pf_open() {
  kubectl port-forward -n "$1" "$2" "$3:8200" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 4
}
pf_close() { kill "${PF_PID:-}" 2>/dev/null || true; }
# in-pod API GET: ipod NS POD PATH
ipod() { kubectl exec -n "$1" "$2" -- wget -qO- "http://127.0.0.1:8200$3" 2>/dev/null; }

log_section "OpenAether 0.5.0 — Tests e2e Sprint 0 OpenBao (HTTP API)"

# ─── Pre-flight ──────────────────────────────────────────────
log_section "Pre-flight checks"
command -v kubectl >/dev/null 2>&1 && log_ok "kubectl available" \
  || { log_ko "kubectl not found" "install kubectl"; exit 1; }
command -v jq >/dev/null 2>&1 && log_ok "jq available" \
  || { log_ko "jq not found" "install jq"; exit 1; }
kubectl get ns "$ROOT_NS" >/dev/null 2>&1 && log_ok "namespace $ROOT_NS exists" \
  || { log_ko "namespace $ROOT_NS missing" "apply apps/base/foundation/pki-root/"; exit 1; }
kubectl get ns "$WORKLOAD_NS" >/dev/null 2>&1 && log_ok "namespace $WORKLOAD_NS exists" \
  || { log_ko "namespace $WORKLOAD_NS missing" "apply apps/base/foundation/vault/"; exit 1; }

# ─── Test 1: Root unsealed + transit engine ───────────────────
log_section "Test 1: OpenBao root unsealed + transit engine + key"

wait_for_pod "app=openbao-pki-root" "$ROOT_NS" 180 \
  || { log_ko "Root pod not ready" "kubectl describe pod -n $ROOT_NS openbao-pki-root-0"; exit 1; }

ROOT_STATUS="$(ipod "$ROOT_NS" openbao-pki-root-0 /v1/sys/seal-status)"
assert_equal "$(echo "$ROOT_STATUS" | jq -r .initialized)" "true" "Root is initialized"
assert_equal "$(echo "$ROOT_STATUS" | jq -r .sealed)" "false" "Root is unsealed"

ROOT_TOKEN="$(kubectl get secret openbao-root-recovery -n "$ROOT_NS" -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")"
[ -n "$ROOT_TOKEN" ] && log_ok "Secret openbao-root-recovery present (root token + unseal keys)" \
  || log_ko "Secret openbao-root-recovery missing" "bootstrap Job a-t-il tourné ?"

MOUNTS="$(kubectl exec -n "$ROOT_NS" openbao-pki-root-0 -- sh -c \
  "wget -qO- --header='X-Vault-Token: $ROOT_TOKEN' http://127.0.0.1:8200/v1/sys/mounts" 2>/dev/null)"
echo "$MOUNTS" | jq -e '."transit/"' >/dev/null 2>&1 \
  && log_ok "transit engine mounted on root" \
  || log_ko "transit engine not mounted" "bootstrap step 4 failed"

KEY="$(kubectl exec -n "$ROOT_NS" openbao-pki-root-0 -- sh -c \
  "wget -qO- --header='X-Vault-Token: $ROOT_TOKEN' http://127.0.0.1:8200/v1/transit/keys/aether-workload" 2>/dev/null)"
echo "$KEY" | jq -e '.data.name=="aether-workload"' >/dev/null 2>&1 \
  && log_ok "transit key 'aether-workload' exists" \
  || log_ko "transit key 'aether-workload' missing" "bootstrap step 4 failed"

# ─── Test 2: Workload unsealed + raft 3/3 ─────────────────────
log_section "Test 2: OpenBao workload auto-unsealed + raft 3 voters"

wait_for_pod "app=openbao" "$WORKLOAD_NS" 240 \
  || { log_ko "Workload pod not ready" "kubectl describe pod -n $WORKLOAD_NS -l app=openbao"; exit 1; }

UNSEALED=false
for i in $(seq 1 24); do
  if ipod "$WORKLOAD_NS" openbao-0 "/v1/sys/seal-status" | jq -r .sealed 2>/dev/null | grep -q "false"; then
    UNSEALED=true; break
  fi
  sleep 5
done
[ "$UNSEALED" = "true" ] \
  && log_ok "Workload openbao-0 auto-unsealed via transit" \
  || { log_ko "Workload still sealed after 120s" "check Secret openbao-seal-token + root reachable"; }

# Seal type must be transit (auto-unseal), not shamir
SEALTYPE="$(ipod "$WORKLOAD_NS" openbao-0 /v1/sys/seal-status | jq -r .type)"
assert_equal "$SEALTYPE" "transit" "Workload seal type is transit (auto-unseal)"

# All 3 pods unsealed
ALL3=0
for i in 0 1 2; do
  S="$(ipod "$WORKLOAD_NS" openbao-$i /v1/sys/seal-status | jq -r .sealed 2>/dev/null || echo true)"
  [ "$S" = "false" ] && ALL3=$((ALL3+1))
done
assert_equal "$ALL3" "3" "all 3 workload pods unsealed"

# Raft voters via workload root token
WL_TOKEN="$(kubectl get secret openbao-workload-recovery -n "$WORKLOAD_NS" -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d || echo "")"
[ -n "$WL_TOKEN" ] && log_ok "Secret openbao-workload-recovery present" \
  || log_warn "Secret openbao-workload-recovery missing (workload init manuel ?)"
RAFT="$(kubectl exec -n "$WORKLOAD_NS" openbao-0 -- sh -c \
  "wget -qO- --header='X-Vault-Token: $WL_TOKEN' http://127.0.0.1:8200/v1/sys/storage/raft/configuration" 2>/dev/null)"
VOTERS="$(echo "$RAFT" | jq '[.data.config.servers[] | select(.voter==true)] | length' 2>/dev/null || echo 0)"
assert_equal "$VOTERS" "3" "raft cluster has 3 voters"
LEADERS="$(echo "$RAFT" | jq '[.data.config.servers[] | select(.leader==true)] | length' 2>/dev/null || echo 0)"
assert_equal "$LEADERS" "1" "raft cluster has exactly 1 leader"

# Raft addresses must be STABLE DNS (not pod IPs) — régression POD_IP
if echo "$RAFT" | jq -r '.data.config.servers[].address' 2>/dev/null | grep -q 'svc.cluster.local'; then
  log_ok "raft peers use stable DNS (pas d'IP éphémère)"
else
  log_ko "raft peers use IP addresses" "régression: BAO_CLUSTER_ADDR doit être DNS"
fi

# ─── Test 3: Auth k8s workload → login root ───────────────────
log_section "Test 3: Auth kubernetes (SA openbao-workload → root)"

JWT="$(kubectl create token openbao-workload -n "$WORKLOAD_NS" --duration=10m 2>/dev/null || echo "")"
if [ -z "$JWT" ]; then
  log_warn "Could not mint JWT for SA openbao-workload"
else
  pf_open "$ROOT_NS" openbao-pki-root-0 18200
  LOGIN="$(curl -s --max-time 10 -X POST \
    --data "$(jq -nc --arg j "$JWT" '{jwt:$j,role:"workload-unseal"}')" \
    "http://127.0.0.1:18200/v1/auth/kubernetes/login" 2>/dev/null || echo "")"
  pf_close
  echo "$LOGIN" | jq -e .auth.client_token >/dev/null 2>&1 \
    && log_ok "SA openbao-workload can login to root (transit wrap auth OK)" \
    || log_ko "SA openbao-workload login failed" "$(echo "$LOGIN" | jq -r '.errors // .' 2>/dev/null)"
fi

# ─── Test 4: Restart workload pod → auto-unseal ───────────────
log_section "Test 4: Restart workload openbao-0 → auto-unseal sans clés"

log_info "deleting openbao-0"
kubectl delete pod -n "$WORKLOAD_NS" openbao-0 --wait=false >/dev/null 2>&1
sleep 8
wait_for_pod "statefulset.kubernetes.io/pod-name=openbao-0" "$WORKLOAD_NS" 180 \
  && log_ok "openbao-0 restarted" || log_warn "openbao-0 restart slow"

UNSEALED=false
for i in $(seq 1 30); do
  if ipod "$WORKLOAD_NS" openbao-0 "/v1/sys/seal-status" | jq -r .sealed 2>/dev/null | grep -q "false"; then
    UNSEALED=true; break
  fi
  sleep 5
done
[ "$UNSEALED" = "true" ] \
  && log_ok "openbao-0 auto-unsealed via transit after restart (zéro intervention)" \
  || log_ko "openbao-0 did not auto-unseal" "kubectl logs -n $WORKLOAD_NS openbao-0 | tail -30"

# Raft reconverges to 3 voters after restart
sleep 10
RAFT2="$(kubectl exec -n "$WORKLOAD_NS" openbao-1 -- sh -c \
  "wget -qO- --header='X-Vault-Token: $WL_TOKEN' http://127.0.0.1:8200/v1/sys/storage/raft/configuration" 2>/dev/null)"
V2="$(echo "$RAFT2" | jq '[.data.config.servers[] | select(.voter==true)] | length' 2>/dev/null || echo 0)"
assert_equal "$V2" "3" "raft reconverged to 3 voters after restart (self-healing)"

# ─── Test 5: Restart root → sealed (Shamir protection) ────────
log_section "Test 5: Restart root → sealed (protection Shamir attendue)"

log_info "deleting openbao-pki-root-0"
kubectl delete pod -n "$ROOT_NS" openbao-pki-root-0 --wait=false >/dev/null 2>&1
sleep 8
wait_for_pod "statefulset.kubernetes.io/pod-name=openbao-pki-root-0" "$ROOT_NS" 180 \
  && log_ok "openbao-pki-root-0 restarted" || log_warn "root restart slow"
sleep 5

ROOT_SEALED="$(ipod "$ROOT_NS" openbao-pki-root-0 /v1/sys/seal-status | jq -r .sealed 2>/dev/null || echo true)"
if [ "$ROOT_SEALED" = "true" ]; then
  log_ok "Root sealed après restart (Shamir actif — unseal manuel requis, attendu)"
  log_info "Recovery: voir apps/base/foundation/pki-root/README.md"
else
  log_warn "Root unsealed après restart (inattendu pour Shamir)"
fi

# NB: après ce test, le root est SEALED → le workload ne pourra plus se
# re-unsealer tant que le root n'est pas re-unsealed manuellement. C'est le
# comportement voulu (le root est la racine de confiance Shamir).
log_info "⚠ root scellé: re-unseal via bootstrap (Secret recovery) ou cérémonie manuelle"
kubectl delete job openbao-bootstrap -n "$ROOT_NS" --ignore-not-found >/dev/null 2>&1
kubectl apply -k apps/base/foundation/pki-root >/dev/null 2>&1 && log_info "bootstrap relancé pour re-unseal root"

# ─── Test 6: NetworkPolicy sanity ─────────────────────────────
log_section "Test 6: NetworkPolicy Cilium présentes"
kubectl get ciliumclusterwidenetworkpolicy allow-dns >/dev/null 2>&1 && log_ok "CCNP allow-dns present"
kubectl get ciliumclusterwidenetworkpolicy allow-kube-api >/dev/null 2>&1 && log_ok "CCNP allow-kube-api present"
kubectl get cnp -n "$WORKLOAD_NS" openbao-workload >/dev/null 2>&1 && log_ok "CNP openbao-workload present"
kubectl get cnp -n "$ROOT_NS" openbao-pki-root >/dev/null 2>&1 && log_ok "CNP openbao-pki-root present"
kubectl get cnp -n "$ROOT_NS" openbao-bootstrap >/dev/null 2>&1 && log_ok "CNP openbao-bootstrap present"

# ─── Summary ─────────────────────────────────────────────────
print_summary "test-sprint0-openbao"
exit $?
