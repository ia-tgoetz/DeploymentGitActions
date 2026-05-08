# Derived Ignition image for Edge IPC deployment.
#
# Extends the private GHCR-mirrored base and bakes any third-party .modl files
# from services/modules/ into Ignition's user-lib/modules directory. Modules
# placed there are loaded automatically on every gateway start and cannot be
# uninstalled from the web UI (which is what we want for fleet-managed sites).
#
# This is the IA-recommended pattern for 8.3 — see
# https://www.docs.inductiveautomation.com/docs/8.3/platform/docker-image/docker-image-examples
#
# Build:
#   docker compose build
# (deploy.yml does this automatically before `compose up -d`.)

ARG BASE_IMAGE=ghcr.io/ia-tgoetz/ignition
ARG IGN_RELEASE=8.3.6

FROM ${BASE_IMAGE}:${IGN_RELEASE}

# Copy every file in services/modules/ into Ignition's module directory.
# Includes .gitkeep (harmless). If services/modules/ contains no .modl files,
# the result is a no-op — base image behavior is preserved.
COPY services/modules/ /usr/local/bin/ignition/user-lib/modules/
