#!/usr/bin/env bash
# One-time mirror: pull Ignition's official image from Docker Hub and push
# it to your private GHCR. Run from a workstation with internet access,
# NOT from the IPC. Re-run whenever you bump IGN_RELEASE.
#
# Prerequisites:
#   1. A GitHub PAT with `write:packages` and `read:packages` scopes
#      stored in the GHCR_PAT env var.
#   2. Logged-in Docker.
#
# Usage:
#   GHCR_OWNER=ia-tgoetz IGN_RELEASE=8.3.6 GHCR_PAT=<token> \
#     bash scripts/mirror-to-ghcr.sh

set -euo pipefail

OWNER="${GHCR_OWNER:?GHCR_OWNER is required (e.g. ia-tgoetz)}"
RELEASE="${IGN_RELEASE:-8.3.6}"
PAT="${GHCR_PAT:?GHCR_PAT is required}"

SOURCE="inductiveautomation/ignition:${RELEASE}"
TARGET="ghcr.io/${OWNER}/ignition:${RELEASE}"

echo "Logging in to ghcr.io..."
echo "$PAT" | docker login ghcr.io -u "$OWNER" --password-stdin

echo "Pulling $SOURCE..."
docker pull "$SOURCE"

echo "Tagging as $TARGET..."
docker tag "$SOURCE" "$TARGET"

echo "Pushing to GHCR..."
docker push "$TARGET"

echo "Done. Image available at: $TARGET"
echo "Make the package private in GitHub UI: https://github.com/users/$OWNER/packages/container/ignition/settings"
