#!/usr/bin/env bash
# ==============================================================================
# OpenAether — encrypted backup of cluster access artifacts (talosconfig/kubeconfig)
#
# Called by infrastructure/opentofu/backup.tf (local-exec) during a Phase-2 apply.
# CLIENT-side encrypts each artifact with gpg (symmetric AES-256, authenticated)
# using the SAME passphrase as the tfstate, then uploads the ciphertext to TWO
# object stores — PRIMARY (the cluster's own provider) and REPLICA (in prod a
# different provider) — with S3 SSE (server-side) layered on top.
#
# Inputs (env):
#   TALOSCONFIG_B64, KUBECONFIG_B64                base64 of the artifacts
#   PASSPHRASE                                     client-encryption passphrase (>=32)
#   PRIMARY_BUCKET / PRIMARY_EP / PRIMARY_REGION
#   REPLICA_BUCKET / REPLICA_EP / REPLICA_REGION
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY                 primary store creds
#   BACKUP_AWS_ACCESS_KEY_ID / BACKUP_AWS_SECRET_ACCESS_KEY   replica store creds
#                                                            (default: primary creds)
#
# Restore (DR): see infrastructure/opentofu/README.md → "Restore a backup".
# ==============================================================================
set -euo pipefail

command -v aws >/dev/null 2>&1 || { echo "✗ aws CLI required for backups (or set backup_enabled=false)"; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "✗ gpg required for client-side encryption (or set backup_enabled=false)"; exit 1; }

# Replica creds default to the primary creds (dev: same provider as the cluster).
BACKUP_AWS_ACCESS_KEY_ID="${BACKUP_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
BACKUP_AWS_SECRET_ACCESS_KEY="${BACKUP_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"

# Isolated GnuPG home (symmetric mode uses no keyring, but keep ~/.gnupg untouched).
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
WORK="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME" "$WORK"' EXIT

# Client-side encrypt: AES-256, authenticated (MDC, or OCB AEAD on gpg >=2.3),
# key derived from the passphrase with hardened S2K (max iterations + SHA-512) —
# stronger and integrity-checked, unlike openssl enc CBC. Passphrase via fd 3 so
# it never appears in argv.
enc() { # base64-content  out-file
  printf '%s' "$1" | base64 -d | \
    gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 3 \
        --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
        --symmetric --cipher-algo AES256 -o "$2" 3< <(printf '%s' "$PASSPHRASE")
}

put() { # file  bucket  endpoint  region  access_key  secret_key
  AWS_ACCESS_KEY_ID="$5" AWS_SECRET_ACCESS_KEY="$6" \
    aws s3 cp "$1" "s3://$2/backups/$(basename "$1")" \
      --endpoint-url "$3" --region "$4" --sse AES256 >/dev/null
}

enc "$TALOSCONFIG_B64" "$WORK/talosconfig.gpg"
enc "$KUBECONFIG_B64"  "$WORK/kubeconfig.gpg"

for f in "$WORK/talosconfig.gpg" "$WORK/kubeconfig.gpg"; do
  put "$f" "$PRIMARY_BUCKET" "$PRIMARY_EP" "$PRIMARY_REGION" "${AWS_ACCESS_KEY_ID:-}" "${AWS_SECRET_ACCESS_KEY:-}"
  put "$f" "$REPLICA_BUCKET" "$REPLICA_EP" "$REPLICA_REGION" "$BACKUP_AWS_ACCESS_KEY_ID" "$BACKUP_AWS_SECRET_ACCESS_KEY"
done

echo "✓ Encrypted talosconfig + kubeconfig → s3://$PRIMARY_BUCKET/backups/ + s3://$REPLICA_BUCKET/backups/"
