#!/usr/bin/env bash
set -euo pipefail

IMAGE="inductiveautomation/ignition:${IGNITION_VERSION:-8.3.6}"
TAR="${IMAGE_TAR_PATH:-/opt/ignition-images/ignition-${IGNITION_VERSION:-8.3.6}.tar}"

if docker image inspect "$IMAGE" &>/dev/null; then
  echo "Image $IMAGE already loaded, skipping."
  exit 0
fi

if [[ ! -f "$TAR" ]]; then
  echo "ERROR: Image not in Docker and tar not found at: $TAR" >&2
  echo "To pre-stage: docker pull $IMAGE && docker save $IMAGE -o $TAR" >&2
  exit 1
fi

echo "Loading $IMAGE from $TAR..."
docker load -i "$TAR"
echo "Image loaded."
