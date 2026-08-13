#!/usr/bin/env bash
# Wait until the Talos API ANSWERS on the given endpoint.
# Usage: ENDPOINT=<host[:port]> [NODE=<ip>] [MAX_WAIT_SECONDS=900] ./wait-talos-port.sh
#
# Two ways to get this wrong, both met on 2026-08-12/13:
#
#  1. A bare TCP connect. On cloud the endpoint is an SSH tunnel on 127.0.0.1 and
#     `ssh -L` accepts locally whatever the far end is doing, so it returned
#     "reachable" in 4ms against a node that was not running. Everything
#     downstream then fired into the void: the machine config applied in 0s to
#     nobody and the health gate waited 600s for a kubelet nobody had configured.
#
#  2. `talosctl version`. It prints a "Server:" block with a Tag and exits 0 even
#     when nothing answers, so neither its status nor its output separates a live
#     node from a closed port. Replacing (1) with it turned the guard into one
#     that could never succeed and cost a full deployment.
#
# What does separate them is the transport error of a real API call. A node in
# maintenance mode answers the TLS handshake with a self-signed certificate —
# x509 error, but an ANSWER. A dead endpoint refuses the connection or times out.
# A configured node answers properly. So: anything but a transport failure means
# the API is up and will take a config.
set -euo pipefail

HOST="${ENDPOINT%%:*}"
if [[ "$HOST" == "$ENDPOINT" ]]; then
  PORT=50000
else
  PORT="${ENDPOINT##*:}"
fi
NODE="${NODE:-$HOST}"

# Bounded, not infinite: a node that never boots (bad image, stuck cloud-init,
# wrong security group...) must fail loudly within the apply's own 15m
# timeout, not hang the whole `tofu apply`/CI job indefinitely.
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
ELAPSED=0

if command -v talosctl >/dev/null 2>&1; then
  probe() {
    local out
    out="$(talosctl get machinestatus -e "$ENDPOINT" -n "$NODE" 2>&1)" || true
    # Only a transport failure means "not there yet". A certificate complaint is
    # the node answering from maintenance mode, which is exactly what we wait for.
    ! grep -qE 'connection refused|no route to host|i/o timeout|context deadline exceeded|transport: Error while dialing|EOF' <<<"$out"
  }
  WHAT="Talos API"
else
  # No talosctl: fall back to the socket test and say what it cannot see, rather
  # than passing the weaker check off as the same thing.
  probe() { timeout 5 bash -c ">/dev/tcp/${HOST}/${PORT}" 2>/dev/null; }
  WHAT="TCP ${HOST}:${PORT} (talosctl absent — blind to a tunnel with a dead far end)"
fi

echo "Waiting for ${WHAT} on ${ENDPOINT} (node ${NODE}, up to ${MAX_WAIT_SECONDS}s)..."
until probe; do
  if [[ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]]; then
    echo "✗ ${ENDPOINT} still not answering after ${MAX_WAIT_SECONDS}s — giving up." >&2
    exit 1
  fi
  echo "  not ready, retrying in 5s... (${ELAPSED}/${MAX_WAIT_SECONDS}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "Talos API answering on ${ENDPOINT}"
