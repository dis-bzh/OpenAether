#!/usr/bin/env bash
# Wait until Talos API port 50000/TCP is reachable on the given endpoint.
# Usage: ENDPOINT=<host[:port]> [MAX_WAIT_SECONDS=900] ./wait-talos-port.sh
set -euo pipefail

HOST="${ENDPOINT%%:*}"
if [[ "$HOST" == "$ENDPOINT" ]]; then
  PORT=50000
else
  PORT="${ENDPOINT##*:}"
fi

# Bounded, not infinite: a node that never boots (bad image, stuck cloud-init,
# wrong security group...) must fail loudly within the apply's own 15m
# timeout, not hang the whole `tofu apply`/CI job indefinitely.
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
ELAPSED=0

echo "Waiting for Talos API on ${HOST}:${PORT} (up to ${MAX_WAIT_SECONDS}s)..."
until timeout 5 bash -c ">/dev/tcp/${HOST}/${PORT}" 2>/dev/null; do
  if [[ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]]; then
    echo "✗ ${HOST}:${PORT} still unreachable after ${MAX_WAIT_SECONDS}s — giving up." >&2
    exit 1
  fi
  echo "  not ready, retrying in 5s... (${ELAPSED}/${MAX_WAIT_SECONDS}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo "Talos API reachable on ${HOST}:${PORT}"
