#!/usr/bin/env bash
# Does Talos actually ENFORCE the roles in a talosconfig?
#
# The answer decides whether scoping the day-to-day credential is worth
# anything, and it was unknown here until 2026-08-24: `machine.features.rbac`
# appears nowhere in this repository, and the assumption was that it would have
# to be added. It does not — RBAC is on without it.
#
# The control matters as much as the denials: the SAME command with the admin
# config must succeed. Without it a broken command reads as a refused one, and
# the harness would pass on a cluster where nothing is enforced at all.
#
# Runs against the Docker lane, which needs no cloud account: task local-up
# Usage: test-talos-rbac.sh [provider|local]
set -uo pipefail

LANE="${1:-local}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$LANE" = local ] && CLUSTER_DIR="$ROOT/infrastructure/opentofu-local" \
                    || CLUSTER_DIR="$ROOT/infrastructure/opentofu/cluster"
ADMIN="${TALOSCONFIG:-$CLUSTER_DIR/talosconfig}"
READER="$(mktemp -u)/reader.talosconfig"
mkdir -p "$(dirname "$READER")"
trap 'rm -rf "$(dirname "$READER")"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

# No cluster is not a failure, it is a missing prerequisite — and saying so is
# the point. Its sibling test-talos-local.sh hangs here instead (backlog).
if [ ! -s "$ADMIN" ] || ! TALOSCONFIG="$ADMIN" talosctl config info >/dev/null 2>&1; then
  echo "✗ no cluster to ask: $ADMIN is empty or has no context." >&2
  [ "$LANE" = local ] && echo "  task local-up" >&2 || echo "  task cluster-up PROVIDER=$LANE" >&2
  exit 1
fi

NODE="$(tofu -chdir="$CLUSTER_DIR" output -json control_plane_ips 2>/dev/null |
        sed -nE 's/^\["([^"]+)".*/\1/p')"
if [ -z "$NODE" ]; then
  echo "✗ could not read a control-plane IP from $CLUSTER_DIR" >&2
  exit 1
fi

echo "--- what the cluster grants, asked of the cluster ---"

TALOSCONFIG="$ADMIN" talosctl -n "$NODE" version 2>/dev/null | grep -q 'Enabled:.*RBAC' \
  && ok "the node reports RBAC enabled — with no machine.features.rbac in this repo" \
  || bad "the node does not report RBAC: a scoped talosconfig would be decoration"

ADMIN_ROLES="$(TALOSCONFIG="$ADMIN" talosctl config info 2>/dev/null | sed -nE 's/^Roles:[[:space:]]+//p')"
[ "$ADMIN_ROLES" = "os:admin" ] \
  && ok "the config this repository issues is os:admin (the starting point, not the target)" \
  || bad "expected os:admin from the deploy, got '${ADMIN_ROLES:-nothing}'"

"$ROOT/scripts/ops/talosconfig-new.sh" "$LANE" --roles os:reader --ttl 8h --out "$READER" --node "$NODE" >/dev/null 2>&1
READER_ROLES="$(TALOSCONFIG="$READER" talosctl config info 2>/dev/null | sed -nE 's/^Roles:[[:space:]]+//p')"
[ "$READER_ROLES" = "os:reader" ] \
  && ok "talosconfig-new.sh issued an os:reader config" \
  || { bad "talosconfig-new.sh did not produce an os:reader config (got '${READER_ROLES:-nothing}')"; \
       printf '\n\033[31m✗ %s passed, %s FAILED\033[0m\n' "$PASS" "$((FAIL + 1))" >&2; exit 1; }

TALOSCONFIG="$READER" talosctl config info 2>/dev/null | grep -qE 'Certificate expires:[[:space:]]+[0-9]+ hours? from now' \
  && ok "and it expires in hours, not the admin config's year" \
  || bad "the reader config does not expire within hours — the TTL did not take"

echo "--- the denials, each with the admin control beside it ---"

TALOSCONFIG="$READER" talosctl -n "$NODE" read /etc/hosts >/dev/null 2>&1
[ $? -ne 0 ] \
  && ok "os:reader is REFUSED reading a host file (rc≠0)" \
  || bad "os:reader read a host file: the role is not enforced"

TALOSCONFIG="$ADMIN" talosctl -n "$NODE" read /etc/hosts >/dev/null 2>&1
[ $? -eq 0 ] \
  && ok "…and os:admin reads the same file (rc=0) — so the refusal is the ROLE, not the command" \
  || bad "os:admin cannot read it either: this harness proves nothing about roles"

ESC="$(dirname "$READER")/escalated.talosconfig"
rm -f "$ESC"
TALOSCONFIG="$READER" talosctl -n "$NODE" config new "$ESC" --roles os:admin >/dev/null 2>&1
{ [ $? -ne 0 ] && [ ! -f "$ESC" ]; } \
  && ok "os:reader cannot mint itself an os:admin config — scoping does not escalate back" \
  || bad "os:reader minted an os:admin config: the scoped credential is worthless"

if [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; then
  printf '\n\033[32m✓ %s assertions passed — roles are enforced on %s\033[0m\n' "$PASS" "$LANE"
else
  printf '\n\033[31m✗ %s passed, %s FAILED\033[0m\n' "$PASS" "$FAIL" >&2
  exit 1
fi
