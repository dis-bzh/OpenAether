#!/usr/bin/env bash
# ==============================================================================
# OpenAether — Talos API SSH tunnels (Phase 2 bootstrap)
#
# Opens one SSH tunnel per node to its Talos API (50000/TCP) THROUGH the bastion,
# reading the node IPs from the current tofu state. Control planes map to
# localhost 50000+i, workers to 50100+i — matching control_plane_endpoints /
# worker_endpoints in the talos module (cloud cluster).
#
# Local Docker cluster uses 52000+ to avoid port conflicts.
#
# Talos nodes have no SSH, so the bastion relays the TCP (ssh -L ...:node:50000).
# Tunnels are detached (nohup) so they survive the task and the `tofu apply` that
# follows; their PIDs are tracked for clean teardown.
#
# Usage:
#   SSH_KEY=~/.ssh/mykey ./scripts/talos-tunnels.sh open [tofu_dir]
#   ./scripts/talos-tunnels.sh close [tofu_dir]
# ==============================================================================
set -euo pipefail

ACTION="${1:-open}"
TOFU_DIR="${2:-infrastructure/opentofu/cluster}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KEY="${KEY/#\~/$HOME}"
PIDFILE="${TOFU_DIR}/.talos-tunnels.pids"

close_tunnels() {
  # Primary: kill tracked PIDs from pidfile
  if [[ -f "$PIDFILE" ]]; then
    while read -r pid; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done <"$PIDFILE"
    rm -f "$PIDFILE"
  fi
  # Fallback: kill any SSH process forwarding port 50000+ to a remote :50000
  # (catches orphaned tunnels from failed/interrupted runs)
  pkill -f "ssh.*-L 5[01][0-9][0-9][0-9]:.*:50000" 2>/dev/null || true
  # Same, for the private k8s API tunnel opened in k8s_lb_mode = "vip".
  pkill -f "ssh.*-L 6443:.*:6443" 2>/dev/null || true
}

# RFC1918 check (k8s_lb_mode = "vip": k8s_lb_ip is a private address instead of
# a public managed LB, so the API needs its own tunnel through the bastion).
is_private_ip() {
  [[ "$1" =~ ^10\. ]] && return 0
  [[ "$1" =~ ^192\.168\. ]] && return 0
  [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

if [[ "$ACTION" == "close" ]]; then
  close_tunnels
  echo "✓ Talos tunnels closed"
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "✗ jq is required"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "✗ nc is required"; exit 1; }
[[ -f "$KEY" ]] || { echo "✗ SSH key not found: $KEY (set SSH_KEY=/path/to/key)"; exit 1; }

cd "$TOFU_DIR"

# Read all outputs once and parse with jq, so an empty state (infra not deployed)
# fails clearly instead of capturing tofu's "No outputs found" warning.
OUTPUTS="$(tofu output -json 2>/dev/null || echo '{}')"
BASTION="$(jq -r '.bastion_ip.value // empty' <<<"$OUTPUTS")"
if [[ -z "$BASTION" || "$BASTION" == "<bastion-ip>" ]]; then
  echo "✗ No bastion_ip in the state — deploy the infrastructure first:"
  echo "    task infra-management            (or: task infra-workload PROVIDER=...)"
  exit 1
fi
BUSER="$(jq -r '.bastion_user.value // "root"' <<<"$OUTPUTS")"
mapfile -t CPS < <(jq -r '.control_plane_private_ips.value[]? // empty' <<<"$OUTPUTS")
mapfile -t WKS < <(jq -r '.worker_private_ips.value[]? // empty' <<<"$OUTPUTS")
K8S_LB_IP="$(jq -r '.k8s_lb_ip.value // empty' <<<"$OUTPUTS")"

close_tunnels # drop any stale tunnels (old IPs) before reopening
: >"$PIDFILE"

# The bastion is re-created by `tofu apply` (its EIP/public IP is stable), so a
# changed host key on the same IP is expected after a redeploy — not an attack.
# Drop any stale known_hosts entry so accept-new re-pins it, instead of SSH
# refusing every tunnel with a host-key mismatch (which shows up as 0/N up).
ssh-keygen -R "$BASTION" >/dev/null 2>&1 || true

open_one() { # localport nodeip
  nohup ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o TCPKeepAlive=yes \
    -i "$KEY" -N -L "$1:$2:50000" "${BUSER}@${BASTION}" \
    >/dev/null 2>&1 &
  echo $! >>"$PIDFILE"
}

echo "▶ Opening tunnels via ${BUSER}@${BASTION} (key: $KEY)"
i=0; for ip in "${CPS[@]}"; do open_one "$((50000 + i))" "$ip"; i=$((i + 1)); done
i=0; for ip in "${WKS[@]}"; do open_one "$((50100 + i))" "$ip"; i=$((i + 1)); done

# k8s_lb_mode = "vip": k8s_lb_ip is a private Talos VIP, not a public managed
# LB — open a dedicated tunnel to reach the API from the operator's machine.
K8S_API_TUNNELED=false
if [[ -n "$K8S_LB_IP" ]] && is_private_ip "$K8S_LB_IP"; then
  nohup ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=20 -o TCPKeepAlive=yes \
    -i "$KEY" -N -L "6443:${K8S_LB_IP}:6443" "${BUSER}@${BASTION}" \
    >/dev/null 2>&1 &
  echo $! >>"$PIDFILE"
  K8S_API_TUNNELED=true
fi

# Give SSH a moment to establish the forwards, then verify.
sleep 4
ports=()
for j in "${!CPS[@]}"; do ports+=("$((50000 + j))"); done
for j in "${!WKS[@]}"; do ports+=("$((50100 + j))"); done
[[ "$K8S_API_TUNNELED" == true ]] && ports+=("6443")
ok=0
for p in "${ports[@]}"; do nc -z 127.0.0.1 "$p" 2>/dev/null && ok=$((ok + 1)); done

echo "✓ ${ok}/${#ports[@]} tunnels up — CPs on 50000+i, workers on 50100+i"
if [[ "$K8S_API_TUNNELED" == true ]]; then
  echo "  k8s_lb_mode=vip: API tunneled — kubectl --server https://127.0.0.1:6443 get nodes"
fi
if [[ "$ok" -ne "${#ports[@]}" ]]; then
  echo "⚠ some tunnels failed. Check: SSH_KEY is correct, the bastion is reachable"
  echo "  (ssh -i $KEY ${BUSER}@${BASTION}), and its routing fix has converged."
  exit 1
fi
