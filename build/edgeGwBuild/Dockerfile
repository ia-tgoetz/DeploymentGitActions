# Edge gateway image with Cirrus Link MQTT Transmission baked in.
#
# Builds a derived image from the official IA Ignition Edge base and copies
# the Cirrus Link MQTT Transmission .modl into user-lib/modules so it loads
# automatically on every gateway start (no install pipeline required).
#
# Build:
#   1. Place MQTT-Transmission-signed.modl alongside this Dockerfile
#   2. From the repo root:
#        docker build \
#          -t edge-with-transmission:8.3.6 \
#          --build-arg IGNITION_VERSION=8.3.6 \
#          ./build/edgeGwBuild
#   3. Push to GHCR via scripts/push-image-to-ghcr.sh (see README)

ARG IGNITION_VERSION
FROM inductiveautomation/ignition:${IGNITION_VERSION}

COPY --chown=ignition:ignition ./MQTT-Transmission-signed.modl /usr/local/bin/ignition/user-lib/modules/
