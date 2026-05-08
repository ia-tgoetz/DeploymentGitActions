#!/usr/bin/env bash
# Sets edgeNodeId in every Cirrus Link transmitter config under
# services/config/resources/.../transmitter/<name>/config.json to the
# IPC's hostname (or an explicit override). Run from the repo root
# before `docker compose up`, so the bind-mounted config is current
# when Ignition reads it on first boot.
#
# Why: Cirrus Link's MQTT Transmission identifies an edge gateway via
# the (groupId, edgeNodeId, deviceId) triple. groupId and deviceId are
# typically project-wide constants; edgeNodeId should be unique per
# physical edge site. Tying it to the IPC's hostname means each IPC
# auto-identifies itself in the broker namespace without per-site
# config sprawl.
#
# Usage:
#   bash scripts/configure-transmitter.sh                       # uses hostname
#   bash scripts/configure-transmitter.sh edge-site-dallas      # explicit override
#   IGN_NAME=edge-site-dallas bash scripts/configure-transmitter.sh

set -euo pipefail

TRANSMITTER_BASE="services/config/resources/core/com.cirruslink.mqtt.transmission.gateway/transmitter"
EDGE_NODE_ID="${1:-${IGN_NAME:-$(hostname | tr '[:upper:]' '[:lower:]')}}"

if [[ ! -d "$TRANSMITTER_BASE" ]]; then
  echo "No transmitter directory at $TRANSMITTER_BASE — nothing to update."
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt-get install -y jq" >&2
  exit 1
fi

count=0
while IFS= read -r -d '' config; do
  tmp=$(mktemp)
  jq --arg id "$EDGE_NODE_ID" '.edgeNodeId = $id' "$config" > "$tmp" && mv "$tmp" "$config"
  echo "  Updated: $config"
  count=$((count + 1))
done < <(find "$TRANSMITTER_BASE" -name 'config.json' -print0)

if (( count == 0 )); then
  echo "No transmitter config.json files found under $TRANSMITTER_BASE."
else
  echo
  echo "Set edgeNodeId='$EDGE_NODE_ID' in $count transmitter config file(s)."
fi
