#!/usr/bin/env bash
# Assert that .gitleaks-envdata.toml catches what it claims to, and stays quiet
# about the rest.
#
# Twice now a rule in that file was "verified" against a shape this repository
# never writes, and passed while matching nothing: the separator span was {1,4}
# when `tofu fmt` aligns `=` nine columns out, and the version allowlist used
# \bversion\b when every key here is `chart_version` — `_` is a word character,
# so the boundary never held. Both bugs are invisible from a green run; only a
# value that SHOULD be caught and is not reveals them.
#
# Runs against a throwaway repository, never this one.
set -euo pipefail

cd "$(dirname "$0")/../.."
CONFIG="$PWD/.gitleaks-envdata.toml"
command -v gitleaks >/dev/null || { echo "✗ gitleaks not on PATH" >&2; exit 1; }

# One case per line, in order; the line number is what the report is matched on.
CATCH=(
  'admin_ip        = ["51.68.44.219/32"]'
  'account_id      = "123456789012"'
  'project_id      = "7f3a91c2-4d5e-4b8a-9c1d-2e6f8a0b3c5d"'
  'organization_id = "7f3a91c2-4d5e-4b8a-9c1d-2e6f8a0b3c5d"'
  'token           = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"'
  's3_bucket       = "s3-acme-scaleway-tfstate-prod"'
)
PASS=(
  'dns_nameservers = ["1.1.1.1", "8.8.8.8"]'
  'doc_example     = "203.0.113.10"'
  'private_net     = "10.42.0.7"'
  'loopback        = "127.0.0.1"'
  'chart_version   = "1.13.7.0"'
  'talosVersion    = "1.13.7.0"'
  'emulated_proj   = "11111111-1111-1111-1111-111111111111"'
  's3_bucket       = "s3-YOUR-PROJECT-scaleway-tfstate-prod"'
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp"
cp "$CONFIG" "$tmp/.gitleaks-envdata.toml"
git -C "$tmp" add -A
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m base

printf '%s\n' "${CATCH[@]}" "${PASS[@]}" > "$tmp/probe.tf"
git -C "$tmp" add -A
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m probe

# Non-zero exit just means findings, which is the expected case here.
(cd "$tmp" && gitleaks git -c .gitleaks-envdata.toml --log-opts="HEAD~1..HEAD" \
   --report-format json --report-path out.json >/dev/null 2>&1) || true

NCATCH=${#CATCH[@]} NPASS=${#PASS[@]} REPORT="$tmp/out.json" \
python3 - "$tmp/probe.tf" <<'PY'
import json, os, sys

lines = open(sys.argv[1]).read().splitlines()
ncatch, npass = int(os.environ["NCATCH"]), int(os.environ["NPASS"])
flagged = {f["StartLine"] for f in json.load(open(os.environ["REPORT"]))}

bad = 0
for i, line in enumerate(lines, start=1):
    want = "CATCH" if i <= ncatch else "PASS"
    got = "CATCH" if i in flagged else "PASS"
    if got != want:
        print(f"✗ want {want:<5} got {got:<5}  {line.strip()}")
        bad += 1

if bad:
    sys.exit(1)
print(f"✓ gitleaks env-data rules: {ncatch} caught, {npass} ignored, as specified")
PY
