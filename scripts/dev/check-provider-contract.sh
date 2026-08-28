#!/usr/bin/env bash
# provider-contract.md is the authority CLAUDE.md and the provider-module skill
# both point at — and nothing read it. It had drifted: it required a variable
# named `bastion_ssh_key` of type `string`, while all four modules declare
# `bastion_ssh_keys` as `list(string)`. A grep for the contract's name found one
# hit in the whole repository: the contract's own line. Zero implementers, and
# the document that says what a fifth provider must build was the wrong one.
#
# So the tables become executable. The document stays the source; this compares
# every module against it, by NAME and by TYPE.
#
# Optional outputs are checked only where declared — that is what optional
# means — but a module declaring one with the wrong type is still refused.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

CONTRACT=infrastructure/opentofu/modules/providers/provider-contract.md
MODULES=(scw ovh outscale proxmox)

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

[ -f "$CONTRACT" ] || { echo "✗ no $CONTRACT" >&2; exit 1; }

# Rows of `| \`name\` | \`type\` | description |` under a given "## Required X"
# or "## Optional X" heading. Anything else in the file is prose.
rows() { # <heading regex>
  awk -v h="$1" '
    $0 ~ "^## " h { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^\| `/ {
      gsub(/`/, "")
      split($0, f, "|")
      gsub(/^[ \t]+|[ \t]+$/, "", f[2]); gsub(/^[ \t]+|[ \t]+$/, "", f[3])
      if (f[2] != "" && f[2] !~ /^-+$/ && f[2] != "Variable" && f[2] != "Output")
        print f[2] "\t" f[3]
    }' "$CONTRACT"
}

# The declared type of a variable/output in a module, or empty when absent.
declared_type() { # <module> <block: variable|output> <name>
  awk -v want="$3" -v kind="$2" '
    $0 ~ "^" kind " \"" want "\" \\{" { inside = 1; next }
    inside && /^}/ { exit }
    inside && /^[ \t]*type[ \t]*=/ {
      sub(/^[ \t]*type[ \t]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
    }' "infrastructure/opentofu/modules/providers/$1"/*.tf
}

exists() { # <module> <kind> <name>
  grep -qE "^$2 \"$3\" \{" "infrastructure/opentofu/modules/providers/$1"/*.tf
}

check() { # <kind> <heading regex> <required|optional>
  local kind="$1" heading="$2" mode="$3" name type m have
  while IFS=$'\t' read -r name type; do
    [ -n "$name" ] || continue
    for m in "${MODULES[@]}"; do
      if ! exists "$m" "$kind" "$name"; then
        if [ "$mode" = required ]; then
          bad "$m: $kind \"$name\" is required by the contract and not declared"
        fi
        continue
      fi
      have="$(declared_type "$m" "$kind" "$name")"
      # An output has no `type`; only its presence is contractual.
      if [ "$kind" = output ] || [ -z "$type" ]; then ok "$m: $kind $name"; continue; fi
      if [ "$have" = "$type" ]; then
        ok "$m: $kind $name ($type)"
      else
        bad "$m: $kind \"$name\" is ${have:-untyped}, the contract says $type"
      fi
    done
  done < <(rows "$heading")
}

echo "=== Required Variables ==="; check variable "Required Variables" required
echo "=== Required Outputs ===";   check output   "Required Outputs"   required
echo "=== Optional Outputs (checked where declared) ==="; check output "Optional Outputs" optional

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
# A floor: an awk that stops matching would report "0 failed" and mean nothing.
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
