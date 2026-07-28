#!/usr/bin/env bash
# ==============================================================================
# OpenAether — wrapper CRON du snapshot etcd
#
# POURQUOI CE WRAPPER
#   `task etcd-snapshot` works fine by hand, but not as-is in a crontab.
#   Four reasons, all of them classics of the genre:
#
#   1. **PATH** — cron starts with a minimal PATH (often /usr/bin:/bin), while
#      the tools are scattered: task and talosctl in /usr/local/bin, tofu and
#      aws in /snap/bin. Without this: "command not found", and the snapshot
#      never runs even though the crontab looks correct.
#   2. **Credentials** — the task reads environment variables (S3, provider,
#      encryption passphrase) that cron does not inherit from a login shell.
#   3. **Unclosed SSH tunnels** — `task etcd-snapshot` OPENS the tunnels and
#      never closes them (deliberate interactively, where you chain commands).
#      Under cron they would pile up on every run. This wrapper always closes
#      them, including on failure (trap EXIT).
#   4. **Overlap** — a slow snapshot would meet the next one. flock prevents it.
#
# USAGE
#   ./scripts/ops/etcd-snapshot-cron.sh <provider> [ssh-key]
#
#   Crontab example (03:40 daily) — note the ABSOLUTE path and the redirection:
#   cron mails the output, which acts as a poor man's alerting.
#     40 3 * * * /home/vde/repos/DIS/OpenAether/OpenAether-infra/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/id_ed25519-ovh-openaether-dev >> /var/log/openaether-etcd-snapshot.log 2>&1
#
# VARIABLES
#   OPENAETHER_ENV_FILE  environment file to source (default: <repo>/.env.sh)
#   KEEP                 retention, as a number of snapshots (default: 30)
#
# ⚠️ This snapshot is an RTO SHORTCUT, not the reference backup: cluster content
# is rebuilt by Flux. It covers what lives ONLY in etcd (Secrets written by
# Jobs, PVC bindings…).
# ==============================================================================
set -euo pipefail

PROVIDER="${1:?usage: etcd-snapshot-cron.sh <scaleway|ovh|outscale|proxmox> [clé-ssh]}"
SSH_KEY="${2:-$HOME/.ssh/id_ed25519}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${OPENAETHER_ENV_FILE:-$ROOT/.env.sh}"
KEEP="${KEEP:-30}"

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# 1. PATH complet — cf. raison 1 ci-dessus.
export PATH="/usr/local/bin:/snap/bin:$HOME/.local/bin:$PATH"

# 2. Environnement (credentials S3/provider + TF_VAR_encryption_passphrase).
if [ -r "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  log "✗ fichier d'environnement introuvable : $ENV_FILE"
  log "  (le définir via OPENAETHER_ENV_FILE si le dépôt n'est pas au même endroit)"
  exit 1
fi

for bin in task tofu talosctl aws gpg; do
  command -v "$bin" >/dev/null 2>&1 || { log "✗ outil absent du PATH : $bin"; exit 1; }
done

# 3. Close the tunnels whatever happens.
cleanup() {
  local rc=$?
  "$ROOT/scripts/bootstrap/talos-tunnels.sh" close "$ROOT/infrastructure/opentofu/cluster" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then log "✓ snapshot etcd terminé ($PROVIDER)"; else log "✗ échec (code $rc) — snapshot etcd $PROVIDER"; fi
  exit "$rc"
}
trap cleanup EXIT

# 4. Lock: never two runs in parallel.
LOCK="/tmp/openaether-etcd-snapshot-${PROVIDER}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "⚠ une exécution est déjà en cours ($LOCK) — abandon"
  exit 0
fi

log "▶ snapshot etcd — provider=$PROVIDER keep=$KEEP"
cd "$ROOT"
KEEP="$KEEP" task etcd-snapshot PROVIDER="$PROVIDER" KEY="$SSH_KEY"
