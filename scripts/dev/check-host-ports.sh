#!/usr/bin/env bash
# Preflight the local cluster's host ports against the Hyper-V reservations.
#
# On Windows/WSL2 those reserved blocks MOVE across reboots and are not confined
# to the dynamic range (40625-41224 was reserved on 2026-07-29). Docker Desktop
# reports a collision as a bare "/forwards/expose returned unexpected status:
# 500", then the apply burns 5 retries and a 90s timeout per node before dying
# on something unrelated-looking. Failing here names the actual range.
#
# No-op off WSL2 (netsh.exe absent) and non-fatal if the exclusions are
# unreadable: this guards a known trap, it must never block a working setup.
#
# Usage: check-host-ports.sh [talos-base] [k8s-port]   (defaults: the variable defaults)
set -uo pipefail

BASE="${1:-45000}"
# Both defaults mirror infrastructure/opentofu-local/variables.tf. The Kubernetes
# port used to be a literal here, which was fine while it was a literal there too
# — and wrong the moment it became movable, because this guard would have kept
# checking 6443 while the apply published something else.
K8S="${2:-6443}"
# cp_i → base+i (3), worker_i → base+10+i (3), plus the Kubernetes API.
PORTS=("$((BASE))" "$((BASE + 1))" "$((BASE + 2))" "$((BASE + 10))" "$((BASE + 11))" "$((BASE + 12))" "$K8S")

command -v netsh.exe >/dev/null 2>&1 || exit 0

RANGES="$(netsh.exe int ipv4 show excludedportrange protocol=tcp 2>/dev/null \
  | tr -d '\r' | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1, $2}')"
[ -n "$RANGES" ] || exit 0

conflict=0
for p in "${PORTS[@]}"; do
  while read -r start end; do
    if [ "$p" -ge "$start" ] && [ "$p" -le "$end" ]; then
      echo "✗ host port $p is inside the Hyper-V reserved range ${start}-${end}" >&2
      conflict=1
    fi
  done <<< "$RANGES"
done

if [ "$conflict" -ne 0 ]; then
  cat >&2 <<EOT

  Docker Desktop cannot publish these ports; the apply would fail on an opaque
  500 and then on "Talos API not ready after 90s".

  Both are movable, and the message above says which one collided:
      task local-up TALOS_API_PORT_BASE=<base>   # Talos, needs base..base+12 clear
      task local-up K8S_API_PORT=<port>          # the Kubernetes API, one port
  Current reservations:
$(printf '%s\n' "$RANGES" | sed 's/^/      /')
EOT
  exit 1
fi

echo "✓ host ports free (Talos base $BASE, Kubernetes $K8S)"
