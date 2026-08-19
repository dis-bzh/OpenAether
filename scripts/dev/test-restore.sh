#!/usr/bin/env bash
# The backup path had no inverse. Until 2026-08-17 this repository could encrypt
# a kubeconfig and a talosconfig to two object stores and had no way to read them
# back: no script, no documented command, and the nearest thing
# — stands up a NEW cluster rather than recovering access to the one you have.
#
# A backup nobody has restored is a hypothesis. This is the round trip, offline:
# the exact `enc()` from backup-artifacts.sh, the exact `dec()` from
# restore-artifacts.sh, no S3 and no cluster. What it does NOT prove is the
# transport — that a real object exists in a real bucket is a cloud-run claim,
# and infra-verify.sh owns it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

command -v gpg >/dev/null 2>&1 || { echo "↷ gpg absent — the round trip cannot be tested here"; exit 0; }

WORK="$(mktemp -d)"
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
trap 'rm -rf "$WORK" "$GNUPGHOME"' EXIT

# Extracted from the two scripts rather than retyped, so a change to either side
# is exercised here. If the awk range misses, the functions are undefined and
# every check below would score a pass from "command not found" — hence the
# assertion right after.
eval "$(awk '/^enc\(\) \{/,/^\}/' "$ROOT/scripts/ops/backup-artifacts.sh")"
eval "$(awk '/^dec\(\) \{/,/^\}/' "$ROOT/scripts/ops/restore-artifacts.sh")"
if ! declare -F enc >/dev/null || ! declare -F dec >/dev/null; then
  echo "✗ enc()/dec() could not be extracted — every check below would have passed on rc 127" >&2
  exit 1
fi

echo "=== the round trip: what is encrypted comes back byte for byte ==="

PASSPHRASE="a-passphrase-long-enough-to-be-accepted-32+"
PAYLOAD='apiVersion: v1
kind: Config
clusters:
- cluster: {server: "https://10.0.0.1:6443"}
  name: openaether'
printf '%s' "$PAYLOAD" >"$WORK/original"

# `base64 -w0 <<<"$PAYLOAD"` would encode a trailing newline the here-string adds
# and the original file does not have, and the comparison below would fail on one
# byte for a reason that has nothing to do with the scripts.
enc "$(printf '%s' "$PAYLOAD" | base64 -w0)" "$WORK/sealed.gpg"
[ -s "$WORK/sealed.gpg" ] && ok "enc() produced a file" || bad "enc() produced nothing"

# The whole point of client-side encryption: what leaves the machine must not be
# the payload. Checked, not assumed — this is the one claim the repository makes
# about the backups that nothing else verifies.
if grep -q 'apiVersion' "$WORK/sealed.gpg" 2>/dev/null; then
  bad "the sealed file still contains the plaintext — it is not encrypted"
else
  ok "the sealed file is not the plaintext"
fi

if dec "$WORK/sealed.gpg" "$WORK/restored" 2>/dev/null; then
  ok "dec() accepted the file written by enc()"
else
  bad "dec() could not read what enc() wrote — the two are not inverses"
fi
if cmp -s "$WORK/original" "$WORK/restored"; then
  ok "restored byte for byte"
else
  bad "the restored file differs from the original"
fi

echo "=== a wrong passphrase must FAIL, not return something ==="
# The failure that matters: a silent partial success would write a corrupt
# kubeconfig over a working one.
( PASSPHRASE="the-wrong-passphrase-entirely-and-long-enough"
  if dec "$WORK/sealed.gpg" "$WORK/wrong" 2>/dev/null; then
    printf 'BAD\n'
  else
    printf 'GOOD\n'
  fi ) | grep -q GOOD \
  && ok "the wrong passphrase is refused" \
  || bad "the wrong passphrase decrypted the object"

echo "=== restore-artifacts.sh refuses to start without the passphrase ==="
# It is the ONLY thing that can decrypt; discovering it is unset after the
# download turns a missing key into what looks like a corrupt backup.
out="$(env -u TF_VAR_encryption_passphrase "$ROOT/scripts/ops/restore-artifacts.sh" scaleway 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'TF_VAR_encryption_passphrase' <<<"$out"; then
  ok "it stops early and names the missing passphrase"
else
  bad "it did not refuse a run with no passphrase (rc=${rc})"
fi

echo "=== --from replica reads the -backup bucket, with BACKUP credentials ==="
# The cross-provider copy is the one that answers when the cluster's own cloud
# does not, and reading it with the primary keys fails exactly then.
if grep -q 'BUCKET="${BUCKET}-backup"' "$ROOT/scripts/ops/restore-artifacts.sh" &&
   grep -qE 'resolve-s3-cred\.sh" "\$PROVIDER" (ak|sk) "\$KIND"' "$ROOT/scripts/ops/restore-artifacts.sh"; then
  ok "the replica path targets -backup and resolves credentials by store kind"
else
  bad "the replica path does not switch bucket AND credentials"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
