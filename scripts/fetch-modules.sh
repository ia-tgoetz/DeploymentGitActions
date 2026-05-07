#!/usr/bin/env bash
# Fetch third-party Ignition modules into services/modules/.
# Run once on the IPC (or on a workstation, then scp the .modl files over).
# The .modl files are gitignored — they live alongside the repo, not inside it.
#
# Usage: bash scripts/fetch-modules.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/services/modules"
mkdir -p "$DEST"

# --- Modules to fetch ---
# Format: "filename|url"
MODULES=(
  "MQTT-Transmission-signed.modl|https://files.inductiveautomation.com/third-party/cirrus-link/5.0.3/MQTT-Transmission-signed.modl"
)

for entry in "${MODULES[@]}"; do
  filename="${entry%%|*}"
  url="${entry##*|}"
  target="$DEST/$filename"

  if [[ -f "$target" ]]; then
    echo "Already present: $filename — skipping."
    continue
  fi

  echo "Downloading $filename..."
  curl -fL --output "$target" "$url"
  echo "Saved: $target"
done

echo
echo "Done. Modules in $DEST:"
ls -lh "$DEST"/*.modl
