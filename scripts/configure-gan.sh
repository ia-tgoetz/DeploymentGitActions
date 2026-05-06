#!/usr/bin/env bash
# One-time script to configure the outgoing GAN connection from Ignition Edge
# to the central gateway. Re-run if the central gateway address ever changes.
#
# Usage: bash scripts/configure-gan.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load central gateway config
CONFIG="$REPO_ROOT/config/central-gateway.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found." >&2
  exit 1
fi
# shellcheck source=../config/central-gateway.env
source "$CONFIG"

if [[ -z "${CENTRAL_GW_HOST:-}" ]]; then
  echo "ERROR: CENTRAL_GW_HOST is not set in $CONFIG" >&2
  exit 1
fi

GATEWAY_URL="http://localhost:${HTTP_PORT:-8088}"
ADMIN_USER="${GATEWAY_ADMIN_USERNAME:?Set GATEWAY_ADMIN_USERNAME in docker/.env}"
ADMIN_PASS="${GATEWAY_ADMIN_PASSWORD:?Set GATEWAY_ADMIN_PASSWORD in docker/.env}"

echo "Configuring GAN: '${CENTRAL_GW_CONNECTION_NAME}' -> ${CENTRAL_GW_HOST}:${CENTRAL_GW_PORT}"

curl -sf -u "$ADMIN_USER:$ADMIN_PASS" \
  -X POST "$GATEWAY_URL/data/gateway-network/outgoing" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\":    \"${CENTRAL_GW_CONNECTION_NAME}\",
    \"host\":    \"${CENTRAL_GW_HOST}\",
    \"port\":    ${CENTRAL_GW_PORT},
    \"enabled\": true
  }"

echo "Done. Verify at: $GATEWAY_URL/web/config/networking.ganconfig"
