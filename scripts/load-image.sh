#!/usr/bin/env bash
# Ensure the Ignition image is available locally on the IPC.
# Order of preference:
#   1. Already loaded -> done
#   2. Pull from GHCR (uses Docker login configured by deploy.yml)
#   3. Fall back to a pre-staged tar at IMAGE_TAR_PATH (air-gapped sites)

set -euo pipefail

IMAGE="${IGNITION_IMAGE:-ghcr.io/ia-tgoetz/ignition:${IGN_RELEASE:-8.3.6}}"
TAR="${IMAGE_TAR_PATH:-/opt/ignition-images/ignition-${IGN_RELEASE:-8.3.6}.tar}"

if docker image inspect "$IMAGE" &>/dev/null; then
  echo "Image $IMAGE already loaded, skipping."
  exit 0
fi

echo "Pulling $IMAGE from GHCR..."
if docker pull "$IMAGE"; then
  echo "Pulled $IMAGE."
  exit 0
fi

echo "GHCR pull failed; falling back to tar at $TAR..."
if [[ -f "$TAR" ]]; then
  docker load -i "$TAR"
  echo "Loaded image from $TAR."
  exit 0
fi

echo "ERROR: Could not pull $IMAGE and no tar found at $TAR." >&2
echo "Either ensure the runner is logged in to ghcr.io or pre-stage a tar:" >&2
echo "  docker save $IMAGE -o $TAR" >&2
exit 1
