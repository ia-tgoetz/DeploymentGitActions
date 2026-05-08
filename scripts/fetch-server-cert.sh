#!/usr/bin/env bash
# Fetch a server's public TLS certificate and save it as PEM into
# services/pki/trusted/clients/. Uses openssl s_client.
#
# Usage:
#   bash scripts/fetch-server-cert.sh                                      # defaults: engine-demo.chariot.io:8060
#   bash scripts/fetch-server-cert.sh my-hub.example.com                   # custom host, default port 8060
#   bash scripts/fetch-server-cert.sh my-hub.example.com 8060              # explicit host + port
#
# Output: services/pki/trusted/clients/<hostname>.crt
# Drop into the repo with `git add` and commit; public certs aren't sensitive.

set -euo pipefail

HOSTNAME="${1:-engine-demo.chariot.io}"
PORT="${2:-8060}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="$REPO_ROOT/services/pki/trusted/clients/${HOSTNAME}.crt"

mkdir -p "$(dirname "$OUT_FILE")"

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl required (apt install -y openssl)" >&2
  exit 1
fi

echo "Connecting to ${HOSTNAME}:${PORT}..."
echo \
  | openssl s_client -connect "${HOSTNAME}:${PORT}" -servername "$HOSTNAME" 2>/dev/null \
  | openssl x509 -outform PEM > "$OUT_FILE"

if [[ ! -s "$OUT_FILE" ]]; then
  echo "ERROR: extracted cert is empty — connection or handshake failed" >&2
  rm -f "$OUT_FILE"
  exit 1
fi

echo
echo "Wrote $OUT_FILE"
echo
openssl x509 -in "$OUT_FILE" -noout -subject -issuer -dates -fingerprint -sha256

# Warn if expired
not_after=$(openssl x509 -in "$OUT_FILE" -noout -enddate | sed 's/notAfter=//')
not_after_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$not_after" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
if [[ "$not_after_epoch" -gt 0 && "$not_after_epoch" -lt "$now_epoch" ]]; then
  echo
  echo "WARNING: this cert has EXPIRED. The remote host needs to renew before it's worth trusting." >&2
fi

echo
echo "Next: git add \"$OUT_FILE\" && git commit -m \"Pre-trust $HOSTNAME GAN cert\" && git push"
