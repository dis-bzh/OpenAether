#!/usr/bin/env bash
# Unit tests for rolling-replace's gates, against a STUB kubectl.
#
# Every gate in rolling-replace.sh decides whether to drain a node, and the
# defects found in them on 2026-08-15 were all logic, not cloud: a resource name
# that resolved to the wrong CRD, an error read as an empty list, an `rc=$?` that
# `set -e` never reached. Each cost between 25 and 90 minutes of paid cloud time
# to notice. None of them needed a cluster to catch — they needed a fake kubectl
# and thirty seconds.
#
# The stub answers from fixture files keyed on the argv it receives, and can be
# told to FAIL a given query, which is the case the real ones kept getting wrong.
#
# Usage: test-rolling-replace.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# --- the stub ----------------------------------------------------------------
# STUB_PLAN is a file of "match<TAB>rc<TAB>stdout" lines. The first line whose
# match is a substring of the joined argv wins. No line matching = rc 1, empty.
cat >"$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
argv="$*"
[ -n "${STUB_PLAN:-}" ] && [ -f "$STUB_PLAN" ] || { exit 1; }
while IFS=$'\t' read -r match rc out; do
  [ -n "$match" ] || continue
  case "$argv" in
    *"$match"*)
      # Like the real thing: results on stdout, diagnostics on stderr. Getting
      # this wrong made the first run of these tests report two false failures,
      # which is the right way round for a harness to be wrong.
      if [ "${rc:-0}" = 0 ]; then
        [ -n "$out" ] && printf '%b\n' "$out"
      else
        [ -n "$out" ] && printf '%b\n' "$out" >&2
      fi
      exit "${rc:-0}"
      ;;
  esac
done <"$STUB_PLAN"
exit 1
STUB
chmod +x "$STUB_DIR/kubectl"
export PATH="$STUB_DIR:$PATH"

# --- load the functions under test -------------------------------------------
# rolling-replace.sh is a script, not a library: source it with a sentinel that
# makes it define its functions and stop before doing anything.
extract() { # <fn name>...  — pull the named functions out, with their helpers
  awk -v fns="$1" '
    BEGIN { n = split(fns, a, ","); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    /^[a-z_]+\(\) \{/ { name = $1; sub(/\(\).*/, "", name); inside = (name in want) }
    inside { print }
    inside && /^\}/ { inside = 0 }
  ' "$ROOT/scripts/ops/rolling-replace.sh"
}

# shellcheck disable=SC2016
eval "$(cat <<'PRELUDE'
KCTL=(kubectl)
info() { printf '▶ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*"; }
ok_()  { printf '✓ %s\n' "$*"; }
PRELUDE
)"
eval "$(extract 'cnpg_pod_state,cnpg_deadlocked,cnpg_installed')"

plan() { STUB_PLAN="$STUB_DIR/plan"; export STUB_PLAN; printf '%b' "$1" >"$STUB_PLAN"; }

echo "=== cnpg_pod_state: an unanswered query is not an absent pod ==="

plan 'get pod alive\t0\tTrue\n'
[ "$(cnpg_pod_state ns alive)" = ready ] && ok "a Ready pod reads ready" || bad "expected ready, got $(cnpg_pod_state ns alive)"

plan 'get pod slow\t0\tFalse\n'
[ "$(cnpg_pod_state ns slow)" = notready ] && ok "an unready pod reads notready" || bad "expected notready"

plan 'get pod gone\t1\tError from server (NotFound): pods "gone" not found\n'
[ "$(cnpg_pod_state ns gone)" = absent ] && ok "NotFound reads absent" || bad "expected absent"

plan 'get pod flaky\t1\tThe connection to the server was refused\n'
[ "$(cnpg_pod_state ns flaky)" = unknown ] && ok "an API error reads unknown, NOT absent" || bad "an API error read as absent — the defect this test exists for"

echo
echo "=== cnpg_deadlocked: fires on the measured shape and nothing else ==="

# The real deadlock: currentPrimary gone, target exists but unready, a third ready.
DEADLOCK='get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db zitadel-db-1 zitadel-db-2\n'
plan "${DEADLOCK}get pod zitadel-db-1\t1\tError from server (NotFound): pods \"zitadel-db-1\" not found\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-3 \n"
[ "$(cnpg_deadlocked)" = "foundation-databases zitadel-db zitadel-db-2" ] \
  && ok "the measured deadlock is detected, naming the target to delete" \
  || bad "deadlock not detected: got '$(cnpg_deadlocked)'"

# Healthy: no switchover pending.
plan 'get clusters.postgresql.cnpg.io -A\t0\tfoundation-databases zitadel-db zitadel-db-1 zitadel-db-1\n'
[ -z "$(cnpg_deadlocked)" ] && ok "no switchover pending → does not fire" || bad "fired on a healthy cluster"

# Switchover pending but the primary pod still exists — a NORMAL election.
plan "${DEADLOCK}get pod zitadel-db-1\t0\tTrue\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-3 \n"
[ -z "$(cnpg_deadlocked)" ] && ok "a normal election in progress → does not fire" || bad "fired during a healthy switchover"

# The API is flaky: currentPrimary reads unknown, not absent. Must NOT fire.
plan "${DEADLOCK}get pod zitadel-db-1\t1\tThe connection to the server was refused\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\tzitadel-db-3 \n"
[ -z "$(cnpg_deadlocked)" ] && ok "an unreachable API → does not fire (would delete a live primary's target)" || bad "fired on an API error"

# Nothing else is ready: deleting the target would only make it worse.
plan "${DEADLOCK}get pod zitadel-db-1\t1\tError from server (NotFound): pods \"zitadel-db-1\" not found\nget pod zitadel-db-2\t0\tFalse\nget pods -l cnpg.io/cluster=zitadel-db\t0\t\n"
[ -z "$(cnpg_deadlocked)" ] && ok "no healthy instance to elect → does not fire" || bad "fired with nothing to elect"

echo
echo "=== cnpg_installed ==="
plan 'get crd clusters.postgresql.cnpg.io\t0\tclusters.postgresql.cnpg.io\n'
cnpg_installed && ok "CRD present → installed" || bad "expected installed"
plan 'get crd clusters.postgresql.cnpg.io\t1\tError from server (NotFound)\n'
cnpg_installed && bad "expected not installed" || ok "CRD absent → not installed"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
