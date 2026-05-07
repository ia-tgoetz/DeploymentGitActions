#!/usr/bin/env bash
set -euo pipefail

URL="http://localhost:${IGN_PORT:-8088}/StatusPing"
MAX_RETRIES="${HEALTH_MAX_RETRIES:-60}"   # 60 × 10s = 10 min default (first boot is slow)
INTERVAL="${HEALTH_INTERVAL:-10}"

echo "Polling $URL (max ${MAX_RETRIES}x every ${INTERVAL}s = $((MAX_RETRIES * INTERVAL))s total)..."

for i in $(seq 1 "$MAX_RETRIES"); do
  if curl -sf "$URL" 2>/dev/null | grep -q "RUNNING"; then
    echo "Ignition is RUNNING."
    exit 0
  fi
  echo "[$i/$MAX_RETRIES] Not ready, retrying in ${INTERVAL}s..."
  sleep "$INTERVAL"
done

echo "ERROR: Ignition did not reach RUNNING state within $((MAX_RETRIES * INTERVAL))s" >&2

# Find the actual Ignition container by image name and dump its logs
CONTAINER=$(docker ps -a --filter "ancestor=$(docker compose config --images 2>/dev/null | head -1)" --format '{{.Names}}' | head -1)
if [[ -z "$CONTAINER" ]]; then
  CONTAINER=$(docker ps -a --filter "label=com.docker.compose.service=ignition-edge" --format '{{.Names}}' | head -1)
fi

if [[ -n "$CONTAINER" ]]; then
  echo "--- Last 100 log lines from $CONTAINER ---" >&2
  docker logs "$CONTAINER" --tail 100 >&2 || true
else
  echo "Could not auto-detect Ignition container. Available containers:" >&2
  docker ps -a >&2
fi

exit 1
