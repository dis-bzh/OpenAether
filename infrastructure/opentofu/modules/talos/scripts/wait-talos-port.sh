#!/usr/bin/env bash
# Wait until Talos API port 50000/TCP is reachable on the given endpoint.
# Usage: ENDPOINT=<host[:port]> ./wait-talos-port.sh
set -euo pipefail

HOST="${ENDPOINT%%:*}"
if [[ "$HOST" == "$ENDPOINT" ]]; then
  PORT=50000
else
  PORT="${ENDPOINT##*:}"
fi

echo "Waiting for Talos API on ${HOST}:${PORT}..."
until timeout 5 bash -c ">/dev/tcp/${HOST}/${PORT}" 2>/dev/null; do
  echo "  not ready, retrying in 5s..."
  sleep 5
done
echo "Talos API reachable on ${HOST}:${PORT}"
