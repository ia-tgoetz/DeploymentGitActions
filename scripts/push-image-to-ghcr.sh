#!/usr/bin/env bash
# Push a locally-built Docker image to the project's private GHCR.
# Use for derived images that bake modules into user-lib/modules at build time
# (e.g., the Edge image with Cirrus Link MQTT Transmission).
#
# Source can be either a tar file (will be docker load'd first) or a local
# image reference that's already in Docker.
#
# Usage:
#   GHCR_OWNER=ia-tgoetz GHCR_PAT=<token> \
#     bash scripts/push-image-to-ghcr.sh <source> <dest-package:tag>
#
# Examples:
#   # Push the tar that was built outside the repo
#   GHCR_OWNER=ia-tgoetz GHCR_PAT=ghp_... \
#     bash scripts/push-image-to-ghcr.sh /tmp/edgeWithTransmission.tar ignition-edge:8.3.6
#
#   # Push an image already in local Docker
#   GHCR_OWNER=ia-tgoetz GHCR_PAT=ghp_... \
#     bash scripts/push-image-to-ghcr.sh edge-with-transmission:8.3.6 ignition-edge:8.3.6

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <source-tar-or-image> <dest-package:tag>" >&2
  echo "  e.g.  $0 edgeWithTransmission.tar ignition-edge:8.3.6" >&2
  exit 1
fi

SOURCE="$1"
DEST_TAG="$2"
OWNER="${GHCR_OWNER:?GHCR_OWNER required (e.g. ia-tgoetz)}"
PAT="${GHCR_PAT:?GHCR_PAT required (Personal Access Token with write:packages)}"

REMOTE="ghcr.io/${OWNER,,}/${DEST_TAG}"   # owner lowercased per GHCR rules

echo "==> Logging in to ghcr.io..."
echo "$PAT" | docker login ghcr.io -u "$OWNER" --password-stdin

if [[ -f "$SOURCE" ]]; then
  echo "==> Loading image from tar: $SOURCE"
  LOAD_OUTPUT=$(docker load -i "$SOURCE")
  echo "$LOAD_OUTPUT"
  LOCAL_IMAGE=$(echo "$LOAD_OUTPUT" | sed -nE 's/Loaded image: (.+)/\1/p' | tail -1)
  if [[ -z "$LOCAL_IMAGE" ]]; then
    echo "ERROR: Could not determine loaded image tag from docker load output" >&2
    exit 1
  fi
  echo "==> Loaded as: $LOCAL_IMAGE"
else
  LOCAL_IMAGE="$SOURCE"
  if ! docker image inspect "$LOCAL_IMAGE" &>/dev/null; then
    echo "ERROR: '$LOCAL_IMAGE' is not a tar file and is not a local image" >&2
    exit 1
  fi
fi

echo "==> Tagging $LOCAL_IMAGE -> $REMOTE"
docker tag "$LOCAL_IMAGE" "$REMOTE"

echo "==> Pushing to GHCR (this can take a few minutes for the first push of a new package)..."
docker push "$REMOTE"

PACKAGE_NAME="${DEST_TAG%%:*}"
echo
echo "Done. Image available at: $REMOTE"
echo
echo "First-time setup for this package (do once after first push):"
echo "  1. Mark private: https://github.com/users/${OWNER,,}/packages/container/${PACKAGE_NAME}/settings"
echo "     -> 'Change visibility' -> Private"
echo "  2. Grant the repo access: same page -> 'Manage Actions access'"
echo "     -> Add 'DeploymentGitActions' (or whichever repo deploys this image)"
echo "     -> Role: Read"
echo "  3. Update docker-compose.yml's image: line if it doesn't already point at: $REMOTE"
