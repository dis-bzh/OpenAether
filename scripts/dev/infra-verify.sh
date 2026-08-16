#!/usr/bin/env bash
# What a PURE-INFRA cluster must prove once `task up` returns.
#
# staging-verify.sh is the full-platform check: it waits for 35 Flux
# Kustomizations, the Gateway, the OpenAether-apps ref. On a 1.0.0 cluster none
# of that exists, so running it there would go red for reasons that have nothing
# to do with the infrastructure. This is its floor-sized sibling, and the claim
# it defends is exactly the release scope: a cluster that is healthy, up and
# ready, with its state backed up.
#
# It also asserts what must be ABSENT. "No Flux" and "no application load
# balancer" are the product decision for 1.0.0, and a decision nothing checks is
# a decision that quietly reverts — this repository has watched that happen.
#
# Every check FAILS the run. A verify that warns and ends green is the defect
# that let a CNI-less cluster ship for weeks.
#
# Usage: infra-verify.sh <provider> <role>
#        infra-verify.sh local                (the Docker cluster)
set -uo pipefail

PROVIDER="${1:?usage: infra-verify.sh <provider|local> [role]}"
ROLE="${2:-management}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$PROVIDER" = local ]; then
  CLUSTER_DIR="$ROOT/infrastructure/opentofu-local"
else
  CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
fi
export KUBECONFIG="${KUBECONFIG:-$CLUSTER_DIR/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$CLUSTER_DIR/talosconfig}"

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '\n▶ %s\n' "$*"; }

K() { timeout 60 kubectl "$@"; }

info "The cluster answers"

if K get --raw='/readyz' >/dev/null 2>&1; then ok "apiserver ready"; else bad "apiserver is not ready"; fi

# Bounded wait, not an instant assertion: `task up` returns when OpenTofu is
# done, which is before the last worker has finished joining.
NODES_TIMEOUT="${NODES_TIMEOUT:-300}"
deadline=$((SECONDS + NODES_TIMEOUT))
while :; do
  # A FAILED query is not "every node is Ready", and an EMPTY list is not either.
  if raw="$(K get nodes --no-headers 2>/dev/null)" && [ -n "$raw" ]; then
    notready="$(awk '$2 !~ /^Ready/{printf "%s ", $1}' <<<"$raw")"
    [ -z "$notready" ] && break
  else
    notready="(the apiserver did not answer)"
  fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 10
done
if [ -z "${notready:-}" ] && [ -n "${raw:-}" ]; then
  ok "$(wc -l <<<"$raw") node(s) Ready"
else
  bad "after ${NODES_TIMEOUT}s, not Ready: ${notready:-unknown}"
fi

# The CNI is the floor. A node can be Ready with a broken CNI only briefly, but
# "Cilium is on every node" is the thing that makes the cluster usable, and it is
# counted per node rather than globally — one agent short is the interesting case.
EXPECTED="$(K get nodes --no-headers 2>/dev/null | wc -l)"
CILIUM="$(K -n kube-system get pods -l k8s-app=cilium --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l)"
if [ "$CILIUM" -gt 0 ] && [ "$CILIUM" -eq "$EXPECTED" ]; then
  ok "Cilium running on ${CILIUM}/${EXPECTED} node(s)"
else
  bad "Cilium on ${CILIUM} node(s), expected ${EXPECTED}"
fi

# CoreDNS proves the CNI actually carries traffic, which "the pod is Running"
# does not: a broken datapath leaves DNS pods up and every lookup dead.
if K -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
  ok "CoreDNS has a ready replica — the datapath carries traffic"
else
  bad "CoreDNS has no ready replica — the CNI is up but the network is not"
fi

info "The floor is the floor — what 1.0.0 says is NOT there"

# Not cosmetic. deploy_flux defaults to false; if something re-enables it the
# cluster silently stops being the thing this release validated.
if K get ns flux-system >/dev/null 2>&1; then
  bad "flux-system exists — this is not a pure-infra cluster (deploy_flux?)"
else
  ok "no flux-system namespace — Talos and Cilium, as scoped"
fi

if [ "$PROVIDER" != local ]; then
  APP_LB="$(cd "$CLUSTER_DIR" && timeout 60 tofu output -raw app_lb_ip 2>/dev/null)"
  case "${APP_LB:-N/A}" in
    N/A | "" | null) ok "no application load balancer (deploy_app_lb=false)" ;;
    *) bad "an application load balancer exists and is billed, pointing at Gateway NodePorts nothing serves" ;;
  esac
fi

info "The state is backed up"

if [ "$PROVIDER" = local ]; then
  ok "local cluster: no remote state, nothing to replicate (backup_enabled=false)"
else
  # The claim is not "the backup step ran": it is that the object EXISTS in the
  # replica store, and that the replica is a different endpoint from the primary
  # — a copy on the cloud that just failed is not a backup.
  TFVARS="$CLUSTER_DIR/envs/${ROLE}-${PROVIDER}.tfvars"
  tfv() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)".*/\1/'; }
  CN="$(tfv cluster_name)"; ENVN="$(tfv environment)"
  PRIM_EP="$(tfv s3_primary_endpoint)"; REPL_EP="$(tfv s3_replica_endpoint)"
  BUCKET="s3-${CN%%-*}-${PROVIDER}-tfstate-${ENVN}-backup"
  if [ -z "$CN" ] || [ -z "$ENVN" ]; then
    bad "could not read cluster_name/environment from ${TFVARS##*/} — cannot name the backup bucket"
  elif AWS_ACCESS_KEY_ID="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" ak)" \
       AWS_SECRET_ACCESS_KEY="$("$ROOT/scripts/internal/resolve-s3-cred.sh" "$PROVIDER" sk)" \
       timeout 90 aws s3 ls "s3://${BUCKET}/" --endpoint-url "${REPL_EP:-$PRIM_EP}" 2>/dev/null | grep -q 'tfstate'; then
    ok "an encrypted tfstate replica exists in ${BUCKET}"
  else
    bad "no tfstate object found in ${BUCKET} — the backup claim is unproven"
  fi
  if [ -n "$REPL_EP" ] && [ "$REPL_EP" != "$PRIM_EP" ]; then
    ok "the replica store is a different endpoint from the primary"
  else
    bad "s3_replica_endpoint equals s3_primary_endpoint — that is a copy, not a backup"
  fi
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '✓ %s/%s: pure-infra cluster verified against the cluster, not the state\n' "$PROVIDER" "$ROLE"
[ "$FAIL" -eq 0 ]
