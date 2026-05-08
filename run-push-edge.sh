#!/usr/bin/env bash
# Loads .env and pushes the prebuilt Edge image tar
# (build/edgeGwBuild/edgeWithTransmission.tar) to GHCR as
# ghcr.io/<GHCR_OWNER>/ignition-edge:<IGN_RELEASE>.
#
# Prerequisites:
#   - Docker running
#   - .env exists and contains GHCR_OWNER and GHCR_PAT
#     (IGN_RELEASE is optional; defaults to 8.3.6)
#   - The tar already exists at build/edgeGwBuild/edgeWithTransmission.tar
#
# Usage:
#   bash run-push-edge.sh

set -euo pipefail

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    echo "Variables loaded from .env"
else
    echo "Error: .env file not found!" >&2
    exit 1
fi

TAR="build/edgeGwBuild/edgeWithTransmission.tar"
RELEASE="${IGN_RELEASE:-8.3.6}"
DEST_TAG="ignition-edge:${RELEASE}"

if [ ! -f "$TAR" ]; then
    echo "Error: tar file not found: $TAR" >&2
    exit 1
fi

echo "Pushing $TAR -> ghcr.io/${GHCR_OWNER}/${DEST_TAG}"
bash scripts/push-image-to-ghcr.sh "$TAR" "$DEST_TAG"
