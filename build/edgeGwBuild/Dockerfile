# Edge gateway image — bakes in third-party modules and (optionally) a
# shared fleet identity keystore.
#
# Modules: any *.modl in this directory at build time gets loaded by
#   Ignition at boot from /usr/local/bin/ignition/user-lib/modules/.
#   See modules.txt + .github/workflows/build-image.yml for how CI fetches
#   them; locally, run-build-edge does the same via scripts/.
#
# Fleet keystore: an optional fleet-keystore.p12 baked at
#   /usr/local/bin/ignition/etc/. When present, docker-compose.yml's JVM
#   args point Ignition at it via gateway.metroKeystore* properties so
#   every Edge in the fleet shares one TLS identity. The Hub admin
#   approves that one cert and trusts the entire fleet. Generate with
#   scripts/generate-fleet-cert.{ps1,sh}. The .p12 contains the private
#   key — never commit; distribute via private GHCR or the
#   FLEET_KEYSTORE_BASE64 GitHub Secret.
#
# When fleet-keystore.p12 is absent, Ignition falls back to its
# auto-generated metro keystore (per-IPC unique cert) and the Hub admin
# approves each one individually.

ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Stage the entire build context, then conditionally install pieces.
# This pattern lets the build succeed whether or not optional inputs
# (modules, fleet keystore) are present — strict glob COPY would error
# on missing files.
COPY . /tmp/build-ctx/

RUN set -e; \
    mkdir -p /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/etc; \
    if ls /tmp/build-ctx/*.modl >/dev/null 2>&1; then \
      cp /tmp/build-ctx/*.modl /usr/local/bin/ignition/user-lib/modules/; \
      echo "Baked modules:"; ls -lh /usr/local/bin/ignition/user-lib/modules/*.modl; \
    else \
      echo "No .modl files in build context — image will run with stock IA modules only"; \
    fi; \
    if [ -f /tmp/build-ctx/fleet-keystore.p12 ]; then \
      cp /tmp/build-ctx/fleet-keystore.p12 /usr/local/bin/ignition/etc/; \
      echo "Baked fleet keystore: /usr/local/bin/ignition/etc/fleet-keystore.p12"; \
    else \
      echo "No fleet-keystore.p12 — Ignition will use its auto-generated metro keystore"; \
    fi; \
    chown -R ignition:ignition /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/etc; \
    rm -rf /tmp/build-ctx
