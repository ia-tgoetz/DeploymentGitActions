# syntax=docker/dockerfile:1.6
#
# Edge gateway image — bakes in third-party modules.
#
# Modules: any *.modl in this directory at build time gets loaded by
#   Ignition at boot from /usr/local/bin/ignition/user-lib/modules/.
#   See modules.txt + .github/workflows/build-image.yml for how CI fetches
#   them; locally, run-build-edge does the same via scripts/.
#
# Each Edge auto-generates its own metro keystore for GAN identity on
# first boot, and Hub admin approves per-IPC. The pipeline used to
# bake a shared fleet keystore here; see git tag
# archive/fleet-cert-stack to recover that flow if needed.

ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Use BuildKit's --mount=type=bind to read the build context inline,
# without copying it into a layer. This avoids:
#   - Bloated layers when stale tarballs (e.g. edgeWithTransmission.tar)
#     sit alongside the Dockerfile, AND
#   - 'rm: Permission denied' errors during cleanup when Docker Desktop
#     on Windows produces COPY'd files that resist deletion even as root.
RUN --mount=type=bind,target=/build-ctx,readonly \
    set -e; \
    mkdir -p /usr/local/bin/ignition/user-lib/modules; \
    if ls /build-ctx/*.modl >/dev/null 2>&1; then \
      cp /build-ctx/*.modl /usr/local/bin/ignition/user-lib/modules/; \
      echo "Baked modules:"; \
      ls -lh /usr/local/bin/ignition/user-lib/modules/*.modl | awk '{print $9, $5}'; \
    else \
      echo "No .modl files in build context — image will run with stock IA modules only"; \
    fi; \
    chown -R ignition:ignition /usr/local/bin/ignition/user-lib/modules
