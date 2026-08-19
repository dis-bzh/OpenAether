#!/usr/bin/env bash
# Re-run the bring-up on a cluster that is already up, and assert nothing moved.
#
# `task cluster-up` is documented as idempotent and was proven so by hand on 2026-07-30,
# after a re-run had silently re-sent the bootstrap RPC to a live etcd and
# invalidated the operator's kubeconfig. Nothing has re-proven it since, on any
# provider — which is the gap this closes.
#
# Three assertions, because "the second apply succeeded" is not one of them:
#   1. the plan afterwards is EMPTY  — the configuration converged
#   2. every node is the same node   — same names, same creationTimestamps
#   3. the kubeconfig still works    — the output was not invalidated
#
# Usage: staging-idempotency.sh <provider> <role> [ssh-key]
set -euo pipefail

PROVIDER="${1:?usage: staging-idempotency.sh <provider> <role> [ssh-key]}"
ROLE="${2:?usage: staging-idempotency.sh <provider> <role> [ssh-key]}"
KEY="${3:-$HOME/.ssh/id_ed25519}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export KUBECONFIG="$ROOT/infrastructure/opentofu/cluster/kubeconfig"

fail() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }

# Name plus creationTimestamp: a replaced node keeps its name and gets a new
# timestamp, so comparing names alone would call a full rebuild idempotent.
node_identities() {
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.creationTimestamp}{"\n"}{end}' |
    sort
}

BEFORE="$(node_identities)"
[ -n "$BEFORE" ] || fail "no nodes before the re-run — this check needs a live cluster"
echo "$BEFORE" | sed 's/^/  /'

echo "--- second bring-up ---"
# APPROVE=auto or this stops for an approval no CI runner can answer — after
# the first deploy has already been paid for.
task cluster-up ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" APPROVE=auto

# STRICT=1 turns a non-empty plan into exit 2. This is the assertion; the apply
# above merely has to not fail.
echo "--- the plan after it must be empty ---"
# KEY too: on a bootstrapped cluster infra-plan opens the Talos tunnels, and
# without it they are looked for under the default key that does not exist.
task infra-plan ROLE="$ROLE" PROVIDER="$PROVIDER" KEY="$KEY" STRICT=1 ||
  fail "the plan is not empty after a second bring-up — the configuration does not converge"
ok "plan empty: the second bring-up changed nothing"

# Re-fetched rather than reused: the 2026-07-30 defect invalidated this very
# output, so reading the file we already had would hide exactly what we test.
task kubeconfig ROLE="$ROLE" PROVIDER="$PROVIDER"
kubectl get --raw='/readyz' >/dev/null || fail "the kubeconfig no longer reaches the apiserver"
ok "kubeconfig still valid"

AFTER="$(node_identities)"
if [ "$BEFORE" != "$AFTER" ]; then
  diff <(echo "$BEFORE") <(echo "$AFTER") >&2 || true
  fail "the node set changed — a node was replaced, added or removed by a re-run"
fi
ok "$(echo "$AFTER" | wc -l) node(s) unchanged, same creation timestamps"

echo "✓ ${PROVIDER}/${ROLE}: idempotent"
