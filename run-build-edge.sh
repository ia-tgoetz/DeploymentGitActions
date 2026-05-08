#!/usr/bin/env bash
# Build the derived Edge image from the repo root.
#
# Reads .env for IGN_RELEASE, downloads any .modl files listed in
# build/edgeGwBuild/modules.txt that aren't already staged, runs
# docker build, and saves the result as
# build/edgeGwBuild/edgeWithTransmission.tar so run-push-edge.sh
# can ship it to GHCR.
#
# Prerequisites:
#   - Docker running
#   - .env exists (only IGN_RELEASE is used by this script; defaults to 8.3.6)
#   - Internet access for any .modl URL in modules.txt that isn't already on disk
#
# Usage:
#   bash run-build-edge.sh

set -euo pipefail

if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    echo "Variables loaded from .env"
fi

RELEASE="${IGN_RELEASE:-8.3.6}"
BUILD_DIR="build/edgeGwBuild"
IMAGE_TAG="edge-with-transmission:${RELEASE}"
TAR_PATH="${BUILD_DIR}/edgeWithTransmission.tar"
MANIFEST="${BUILD_DIR}/modules.txt"

if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: build directory not found: $BUILD_DIR" >&2
    exit 1
fi

if [ -f "$MANIFEST" ]; then
    echo
    echo "==> Staging .modl files from modules.txt..."
    while IFS= read -r line; do
        url="${line%%#*}"                              # strip inline comments
        url="$(echo -n "$url" | xargs || true)"        # trim whitespace
        [ -z "$url" ] && continue
        filename="$(basename "$url")"
        target="${BUILD_DIR}/${filename}"
        if [ -f "$target" ]; then
            echo "  Already present: $filename"
        else
            echo "  Downloading: $url"
            curl -fL -o "$target" "$url"
        fi
    done < "$MANIFEST"
else
    echo "No modules.txt found — building with whatever .modl files are already in $BUILD_DIR"
fi

echo
echo "==> Building $IMAGE_TAG..."
docker build \
    -t "$IMAGE_TAG" \
    --build-arg "IGNITION_VERSION=$RELEASE" \
    "$BUILD_DIR"

echo
echo "==> Saving to $TAR_PATH..."
docker save "$IMAGE_TAG" -o "$TAR_PATH"

echo
echo "Done."
echo "  Image: $IMAGE_TAG"
echo "  Tar:   $TAR_PATH"
echo
echo "Next: bash run-push-edge.sh   # to upload to GHCR"
