#!/usr/bin/env bash
set -euo pipefail

URL="http://localhost:${HTTP_PORT:-8088}/StatusPing"
MAX_RETRIES=30
INTERVAL=10

echo "Polling $URL (max ${MAX_RETRIES}x every ${INTERVAL}s)..."

for i in $(seq 1 "$MAX_RETRIES"); do
  if curl -sf "$URL" | grep -q "RUNNING"; then
    echo "Ignition is RUNNING."
    exit 0
  fi
  echo "[$i/$MAX_RETRIES] Not ready, retrying in ${INTERVAL}s..."
  sleep "$INTERVAL"
done

echo "ERROR: Ignition did not reach RUNNING state within $((MAX_RETRIES * INTERVAL))s" >&2
docker logs ignition-edge --tail 80 >&2
exit 1
