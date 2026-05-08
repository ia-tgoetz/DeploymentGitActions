# syntax=docker/dockerfile:1.6
#
# Edge gateway image — bakes in third-party modules and (optionally) a
# shared fleet identity keystore.
#
# Modules: any *.modl in this directory at build time gets loaded by
#   Ignition at boot from /usr/local/bin/ignition/user-lib/modules/.
#   See modules.txt + .github/workflows/build-image.yml for how CI fetches
#   them; locally, run-build-edge does the same via scripts/.
#
# Fleet keystore: an optional metro-keystore (PKCS12, alias 'metro-key')
#   baked at /usr/local/bin/ignition/webserver/metro-keystore — the
#   conventional location Ignition reads on boot. When present, every
#   Edge in the fleet identifies as the same TLS endpoint to the Hub,
#   and the keystore password is supplied via the JVM property
#   -Dmetro.keystore.password (set in docker-compose.yml's command).
#   Generate with scripts/generate-fleet-cert.{ps1,sh}. Contains the
#   private key — never commit; distribute via private GHCR or the
#   FLEET_KEYSTORE_BASE64 GitHub Secret.
#
# When metro-keystore is absent, Ignition auto-generates one on first
# boot (per-IPC unique cert) and the Hub admin approves each one
# individually.

ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Use BuildKit's --mount=type=bind to read the build context inline,
# without copying it into a layer. This avoids:
#   - Bloated layers when stale tarballs (e.g. edgeWithTransmission.tar)
#     sit alongside the Dockerfile, AND
#   - 'rm: Permission denied' errors during cleanup when Docker Desktop
#     on Windows produces COPY'd files that resist deletion even as root.
# The mount disappears at end of RUN — no leftover staged files to clean.
RUN --mount=type=bind,target=/build-ctx,readonly \
    set -e; \
    mkdir -p /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/webserver; \
    if ls /build-ctx/*.modl >/dev/null 2>&1; then \
      cp /build-ctx/*.modl /usr/local/bin/ignition/user-lib/modules/; \
      echo "Baked modules:"; \
      ls -lh /usr/local/bin/ignition/user-lib/modules/*.modl | awk '{print $9, $5}'; \
    else \
      echo "No .modl files in build context — image will run with stock IA modules only"; \
    fi; \
    if [ -f /build-ctx/metro-keystore ]; then \
      cp /build-ctx/metro-keystore /usr/local/bin/ignition/webserver/metro-keystore; \
      echo "Baked metro-keystore at /usr/local/bin/ignition/webserver/metro-keystore"; \
    else \
      echo "No metro-keystore in build context — Ignition will auto-generate one on first boot"; \
    fi; \
    chown -R ignition:ignition /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/webserver
