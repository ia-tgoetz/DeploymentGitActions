#!/usr/bin/env bash
# Generate a self-signed fleet identity cert + PKCS12 keystore.
#
# Outputs (in build/edgeGwBuild/):
#   fleet-cert.crt       — public cert. Give to the Hub admin to approve once.
#                          Safe to commit.
#   fleet-keystore.p12   — PKCS12 with cert + private key. Baked into the
#                          Edge image. NEVER commit. Distribute via image
#                          push to private GHCR.
#
# Usage:
#   bash scripts/generate-fleet-cert.sh
#   FLEET_SUBJECT="/CN=chevron-edge-fleet" bash scripts/generate-fleet-cert.sh
#   FLEET_PASSWORD=mypass FLEET_VALID_DAYS=3650 bash scripts/generate-fleet-cert.sh

set -euo pipefail

SUBJECT="${FLEET_SUBJECT:-/CN=edge-fleet}"
PASSWORD="${FLEET_PASSWORD:-changeit}"
VALID_DAYS="${FLEET_VALID_DAYS:-1825}"
ALIAS="${FLEET_ALIAS:-edge-fleet}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/edgeGwBuild"
CRT_FILE="$BUILD_DIR/fleet-cert.crt"
P12_FILE="$BUILD_DIR/fleet-keystore.p12"
KEY_TMP="$(mktemp -d)/fleet.key"

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "ERROR: Build directory not found: $BUILD_DIR" >&2
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is required (apt install -y openssl)" >&2
  exit 1
fi

echo "Generating fleet identity cert..."
echo "  Subject:  $SUBJECT"
echo "  Alias:    $ALIAS"
echo "  Validity: $VALID_DAYS days"
echo

# Generate self-signed cert + private key in one shot
openssl req -x509 \
  -newkey rsa:2048 \
  -keyout "$KEY_TMP" \
  -out "$CRT_FILE" \
  -sha256 \
  -days "$VALID_DAYS" \
  -nodes \
  -subj "$SUBJECT"

# Combine cert + key into PKCS12 with the right alias
openssl pkcs12 -export \
  -in "$CRT_FILE" \
  -inkey "$KEY_TMP" \
  -out "$P12_FILE" \
  -name "$ALIAS" \
  -passout "pass:$PASSWORD"

# Wipe the unprotected private key from temp (it's now in the .p12)
shred -u "$KEY_TMP" 2>/dev/null || rm -f "$KEY_TMP"
rmdir "$(dirname "$KEY_TMP")" 2>/dev/null || true

echo
echo "Done."
echo
echo "  Public cert (give to Hub admin):"
echo "    $CRT_FILE"
echo
echo "  Keystore (gets baked into image, NEVER commit):"
echo "    $P12_FILE"
echo "  Keystore password: $PASSWORD"
echo "  Keystore alias:    $ALIAS"
echo
echo "Next steps:"
echo "  1. Send fleet-cert.crt to whoever runs the Hub."
echo "  2. Set IGN_FLEET_KEYSTORE_PASSWORD=$PASSWORD in your .env"
echo "  3. Local build:  bash run-build-edge.sh   then   bash run-push-edge.sh"
echo "  4. CI build:     base64-encode the .p12 and store as the"
echo "                   FLEET_KEYSTORE_BASE64 repo Secret."
echo
echo "  base64 for the Secret:  base64 -w0 \"$P12_FILE\""
