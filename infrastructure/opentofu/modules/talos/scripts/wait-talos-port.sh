#!/usr/bin/env bash
# Wait until the Talos API ANSWERS on the given endpoint.
# Usage: ENDPOINT=<host[:port]> [NODE=<ip>] [MAX_WAIT_SECONDS=900] ./wait-talos-port.sh
#
# It used to open a TCP connection and call that ready. On cloud the endpoint is
# an SSH tunnel on 127.0.0.1, and `ssh -L` accepts locally whatever the far end
# is doing — so the check returned "reachable" in 4ms against a node that was not
# running at all (measured 2026-08-12). Everything downstream then fired into the
# void: the machine config applied in 0s to nobody, and the health gate spent 600s
# waiting for a kubelet that had never been configured to start.
#
# So probe the protocol, not the socket. A node answers `version` either in
# maintenance mode (self-signed, hence --insecure) or once configured (with the
# client certificate) — both mean the API is up and will take a config.
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
    talosctl -e "$ENDPOINT" -n "$NODE" --insecure version >/dev/null 2>&1 \
      || talosctl -e "$ENDPOINT" -n "$NODE" version >/dev/null 2>&1
  }
  WHAT="Talos API"
else
  # No talosctl: fall back to the old socket check and say what it cannot see,
  # rather than pretending the weaker check is the same thing.
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
