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
#   The Hub admin approves that one cert and trusts the entire fleet.
#   Generate with scripts/generate-fleet-cert.{ps1,sh}. Contains the
#   private key — never commit; distribute via private GHCR or the
#   FLEET_KEYSTORE_BASE64 GitHub Secret.
#
# When metro-keystore is absent, Ignition auto-generates one on first
# boot (per-IPC unique cert) and the Hub admin approves each one
# individually.

ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

# Stage the entire build context, then conditionally install pieces.
# This pattern lets the build succeed whether or not optional inputs
# (modules, fleet keystore) are present — strict glob COPY would error
# on missing files.
COPY . /tmp/build-ctx/

RUN set -e; \
    mkdir -p /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/webserver; \
    if ls /tmp/build-ctx/*.modl >/dev/null 2>&1; then \
      cp /tmp/build-ctx/*.modl /usr/local/bin/ignition/user-lib/modules/; \
      echo "Baked modules:"; ls -lh /usr/local/bin/ignition/user-lib/modules/*.modl; \
    else \
      echo "No .modl files in build context — image will run with stock IA modules only"; \
    fi; \
    if [ -f /tmp/build-ctx/metro-keystore ]; then \
      cp /tmp/build-ctx/metro-keystore /usr/local/bin/ignition/webserver/metro-keystore; \
      echo "Baked metro-keystore at /usr/local/bin/ignition/webserver/metro-keystore"; \
    else \
      echo "No metro-keystore in build context — Ignition will auto-generate one on first boot"; \
    fi; \
    chown -R ignition:ignition /usr/local/bin/ignition/user-lib/modules /usr/local/bin/ignition/webserver; \
    rm -rf /tmp/build-ctx
