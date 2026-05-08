#!/usr/bin/env bash
# Generate a multi-SAN fleet identity metro-keystore for Ignition GAN.
#
# Follows the workflow documented in
# "Setting Up Your Own Gateway Network Certificate" (IA), adapted for a
# self-signed (no external CA) fleet model where every Edge presents the
# same TLS identity to the Hub.
#
# Reads config/fleet.txt for the hostnames to put in the SAN, and
# optionally takes a comma-separated list of IPs via FLEET_IPS=...
#
# Outputs (in build/edgeGwBuild/):
#   metro-keystore       — PKCS12 keystore. Alias 'metro-key', containing
#                          the cert + private key. Baked into the image at
#                          /usr/local/bin/ignition/webserver/metro-keystore
#                          via the Dockerfile. NEVER commit (private key).
#   fleet-cert.crt       — public cert (PEM). Hand to whoever runs the Hub
#                          so they trust it once for the whole fleet.
#                          Safe to commit.
#
# Usage:
#   bash scripts/generate-fleet-cert.sh
#   FLEET_IPS="192.168.1.10,192.168.1.20" bash scripts/generate-fleet-cert.sh
#   FLEET_PASSWORD="strongerthandefault" bash scripts/generate-fleet-cert.sh
#
# Env overrides:
#   FLEET_PASSWORD     keystore password (>= 6 chars). Default: 'changeit'.
#   FLEET_VALID_DAYS   cert validity. Default: 1825 (5 years).
#   FLEET_SUBJECT      cert subject DN. Default: '/CN=edge-fleet'.
#   FLEET_IPS          extra IP SANs, comma-separated. Default: none.

set -euo pipefail

# Git Bash on Windows mangles arguments that look like POSIX paths
# (e.g. converts -subj "/CN=edge-fleet" to "C:/Program Files/Git/CN=edge-fleet").
# These env vars tell MSYS / MSYS2 not to do that for native commands.
# Harmless no-ops on Linux/macOS.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

PASSWORD="${FLEET_PASSWORD:-changeit}"
VALID_DAYS="${FLEET_VALID_DAYS:-1825}"
SUBJECT="${FLEET_SUBJECT:-/CN=edge-fleet}"
EXTRA_IPS="${FLEET_IPS:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/edgeGwBuild"
FLEET_FILE="$REPO_ROOT/config/fleet.txt"
CRT_FILE="$BUILD_DIR/fleet-cert.crt"
KS_FILE="$BUILD_DIR/metro-keystore"
TMPDIR="$(mktemp -d)"
KEY_TMP="$TMPDIR/fleet.key"
CRT_TMP="$TMPDIR/fleet.crt"

cleanup() {
  shred -u "$KEY_TMP" 2>/dev/null || rm -f "$KEY_TMP"
  rm -f "$CRT_TMP"
  rmdir "$TMPDIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "ERROR: build directory not found: $BUILD_DIR" >&2
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is required (apt install -y openssl)" >&2
  exit 1
fi

# Build the SAN list: every entry in fleet.txt as DNS:<hostname>, plus
# any IPs from FLEET_IPS as IP:<addr>. If both are empty, fall back to
# the CN as a single DNS entry so hostname-verifying peers still match.
SAN_ENTRIES=()
if [[ -f "$FLEET_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo -n "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    SAN_ENTRIES+=("DNS:$line")
  done < "$FLEET_FILE"
fi

if [[ -n "$EXTRA_IPS" ]]; then
  IFS=',' read -ra IP_ARR <<< "$EXTRA_IPS"
  for ip in "${IP_ARR[@]}"; do
    ip="$(echo -n "$ip" | xargs)"
    [[ -z "$ip" ]] && continue
    SAN_ENTRIES+=("IP:$ip")
  done
fi

if [[ ${#SAN_ENTRIES[@]} -eq 0 ]]; then
  echo "WARNING: config/fleet.txt is empty and no FLEET_IPS provided —"
  echo "         falling back to a single DNS:edge-fleet SAN."
  SAN_ENTRIES+=("DNS:edge-fleet")
fi

SAN_STRING=$(IFS=,; echo "${SAN_ENTRIES[*]}")

echo "Generating fleet metro-keystore..."
echo "  Subject:  $SUBJECT"
echo "  Alias:    metro-key  (required by Ignition)"
echo "  Validity: $VALID_DAYS days"
echo "  SAN:      $SAN_STRING"
echo

# 1. Self-signed cert + private key with SAN extension.
#    -nodes leaves the key unencrypted on disk (we wipe it on exit; the
#    PKCS12 in the next step protects it with the keystore password).
openssl req -x509 -nodes \
  -newkey rsa:4096 \
  -keyout "$KEY_TMP" \
  -out "$CRT_TMP" \
  -sha256 \
  -days "$VALID_DAYS" \
  -subj "$SUBJECT" \
  -addext "subjectAltName=$SAN_STRING" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth,clientAuth"

# 2. Combine cert + key into a PKCS12 keystore. Ignition reads the
#    'metro-key' alias by convention from webserver/metro-keystore, so
#    the alias name is fixed (not configurable).
openssl pkcs12 -export \
  -in "$CRT_TMP" \
  -inkey "$KEY_TMP" \
  -out "$KS_FILE" \
  -name "metro-key" \
  -passout "pass:$PASSWORD"

# 3. Save the public cert (no private key) for the Hub admin.
cp "$CRT_TMP" "$CRT_FILE"

echo "Done."
echo
echo "  Public cert (give to Hub admin):"
echo "    $CRT_FILE"
echo
echo "  Keystore (gets baked into the image, NEVER commit):"
echo "    $KS_FILE"
echo "  Keystore password: $PASSWORD"
echo "  Keystore alias:    metro-key"
echo
echo "Verify:"
echo "  openssl x509 -in \"$CRT_FILE\" -noout -subject -ext subjectAltName -dates"
echo
echo "Next steps:"
echo "  1. Hand fleet-cert.crt to whoever runs the Hub (one-time approval)."
echo "  2. Set IGN_FLEET_KEYSTORE_PASSWORD=$PASSWORD in your .env (or repo Secret)."
echo "  3. Local build:  bash run-build-edge.sh   then   bash run-push-edge.sh"
echo "  4. CI build:     base64-encode metro-keystore and set as the"
echo "                   FLEET_KEYSTORE_BASE64 repo Secret."
echo
echo "  base64 for the Secret:  base64 -w0 \"$KS_FILE\""
