#!/usr/bin/env bash
# ==============================================================================
# OpenAether — wrapper CRON du snapshot etcd
#
# POURQUOI CE WRAPPER
#   `task etcd-snapshot` marche très bien à la main, mais pas tel quel dans une
#   crontab. Quatre raisons, toutes vécues comme des classiques du genre :
#
#   1. **PATH** — cron démarre avec un PATH minimal (souvent /usr/bin:/bin).
#      Or les outils sont éparpillés : task et talosctl dans /usr/local/bin,
#      tofu et aws dans /snap/bin. Sans ça : "command not found", et le snapshot
#      ne tourne jamais alors que la crontab semble correcte.
#   2. **Credentials** — la task lit des variables d'environnement (S3, provider,
#      passphrase de chiffrement) que cron n'hérite pas d'un shell interactif.
#   3. **Tunnels SSH non fermés** — `task etcd-snapshot` OUVRE les tunnels et ne
#      les referme pas (c'est voulu en usage interactif, on enchaîne souvent).
#      En cron, ils s'accumuleraient à chaque exécution. Ce wrapper les ferme
#      systématiquement, y compris en cas d'échec (trap EXIT).
#   4. **Recouvrement** — un snapshot lent croiserait le suivant. flock l'évite.
#
# USAGE
#   ./scripts/ops/etcd-snapshot-cron.sh <provider> [clé-ssh]
#
#   Exemple de crontab (03:40 chaque jour) — noter le chemin ABSOLU et la
#   redirection : cron envoie la sortie par mail, ce qui sert d'alerting pauvre.
#     40 3 * * * /home/vde/repos/DIS/OpenAether/OpenAether-infra/scripts/ops/etcd-snapshot-cron.sh ovh ~/.ssh/id_ed25519-ovh-openaether-dev >> /var/log/openaether-etcd-snapshot.log 2>&1
#
# VARIABLES
#   OPENAETHER_ENV_FILE  fichier d'environnement à sourcer (défaut : <repo>/.env.sh)
#   KEEP                 rétention, en nombre de snapshots (défaut : 30)
#
# ⚠️ Ce snapshot est un RACCOURCI de RTO, pas la sauvegarde de référence : le
# contenu du cluster est reconstruit par Flux. Il couvre ce qui ne vit QUE dans
# etcd (Secrets écrits par des Jobs, bindings de PVC…).
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

# 3. Fermeture des tunnels quoi qu'il arrive.
cleanup() {
  local rc=$?
  "$ROOT/scripts/bootstrap/talos-tunnels.sh" close "$ROOT/infrastructure/opentofu/cluster" >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then log "✓ snapshot etcd terminé ($PROVIDER)"; else log "✗ échec (code $rc) — snapshot etcd $PROVIDER"; fi
  exit "$rc"
}
trap cleanup EXIT

# 4. Verrou : pas deux exécutions en parallèle.
LOCK="/tmp/openaether-etcd-snapshot-${PROVIDER}.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "⚠ une exécution est déjà en cours ($LOCK) — abandon"
  exit 0
fi

log "▶ snapshot etcd — provider=$PROVIDER keep=$KEEP"
cd "$ROOT"
KEEP="$KEEP" task etcd-snapshot PROVIDER="$PROVIDER" KEY="$SSH_KEY"
