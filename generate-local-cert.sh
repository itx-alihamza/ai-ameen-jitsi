#!/usr/bin/env bash
#
# Generates the TLS certificate the local Jitsi stack serves.
#
# WHY THIS EXISTS: Jitsi is unusable over plain HTTP. Browsers expose
# `getUserMedia` (microphone, camera) and `getDisplayMedia` (screen share) only in
# a *secure context*, so on HTTP the call appears to connect and then carries no
# media — a failure that looks like a Jitsi bug but is the absence of TLS. And the
# Ameen page is itself HTTPS, so it cannot load `external_api.js` from an HTTP
# origin (mixed content) either.
#
# WHY NOT THE IMAGE'S BUILT-IN CERT: the jitsi/web image generates a fallback
# self-signed certificate when Let's Encrypt is disabled, but its subject does not
# cover `localhost`. Chrome and Safari then fail with
# ERR_CERT_COMMON_NAME_INVALID and give the user no "proceed anyway" option for a
# subresource — the Live Meeting tab just stays blank forever. A certificate whose
# SANs actually include `localhost` and `127.0.0.1` is what makes the
# accept-the-warning-once workflow work.
#
# Prefers mkcert (produces a cert your OS and browsers already trust, so there is
# no warning at all). Falls back to openssl, which works everywhere but requires
# accepting the warning once per browser — see README §Local HTTPS.
#
# Usage:
#   ./generate-local-cert.sh                 # localhost + 127.0.0.1 + LAN IP
#   ./generate-local-cert.sh meet.ameen.local
#
# Output: ./certs/cert.crt and ./certs/cert.key — the filenames the jitsi/web
# image looks for in /config/keys.

set -euo pipefail
cd "$(dirname "$0")"

PRIMARY="${1:-localhost}"
CERT_DIR="./certs"
mkdir -p "$CERT_DIR"

# The LAN address matters: a second device joining the call reaches the
# videobridge at DOCKER_HOST_ADDRESS, and if that is an IP the certificate does
# not cover, the browser rejects the connection.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"

SANS=("DNS:$PRIMARY")
# Deduplicated: when PRIMARY is already `localhost`, emitting it twice produces a
# valid but confusing certificate.
[[ "$PRIMARY" != "localhost" ]] && SANS+=("DNS:localhost")
SANS+=("IP:127.0.0.1" "IP:::1")
if [[ -n "$LAN_IP" && "$LAN_IP" != "127.0.0.1" ]]; then
  SANS+=("IP:$LAN_IP")
fi
SAN_STRING="$(IFS=,; echo "${SANS[*]}")"

echo "Generating a local TLS certificate"
echo "  primary name : $PRIMARY"
echo "  SANs         : $SAN_STRING"
echo

if command -v mkcert >/dev/null 2>&1; then
  echo "Using mkcert — the result will be trusted by your OS and browsers, with no warning."
  MKCERT_NAMES=("$PRIMARY" localhost 127.0.0.1 ::1)
  [[ -n "$LAN_IP" && "$LAN_IP" != "127.0.0.1" ]] && MKCERT_NAMES+=("$LAN_IP")
  mkcert -install >/dev/null 2>&1 || true
  mkcert -cert-file "$CERT_DIR/cert.crt" -key-file "$CERT_DIR/cert.key" "${MKCERT_NAMES[@]}"
  TRUSTED=1
else
  echo "mkcert not found — falling back to openssl (self-signed)."
  echo "Install mkcert to avoid the browser warning entirely:  brew install mkcert"
  echo
  # -nodes: the key must be readable by nginx inside the container without a
  # passphrase prompt, which there would be nobody to answer.
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/cert.key" \
    -out "$CERT_DIR/cert.crt" \
    -days 825 \
    -subj "/C=SA/O=Ameen Local Development/CN=$PRIMARY" \
    -addext "subjectAltName=$SAN_STRING" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    2>/dev/null
  TRUSTED=0
fi

# nginx in the container runs unprivileged; 644 on the cert and 600 on the key is
# the usual split. The key must not be world-readable.
chmod 644 "$CERT_DIR/cert.crt"
chmod 600 "$CERT_DIR/cert.key"

echo
echo "Written:"
echo "  $CERT_DIR/cert.crt"
echo "  $CERT_DIR/cert.key"
echo
openssl x509 -in "$CERT_DIR/cert.crt" -noout -subject -dates 2>/dev/null | sed 's/^/  /'
openssl x509 -in "$CERT_DIR/cert.crt" -noout -ext subjectAltName 2>/dev/null | sed 's/^/  /'

if [[ "$TRUSTED" -eq 0 ]]; then
  cat <<'NOTE'

  ── One manual step is required (self-signed certificate) ──────────────────

  Before opening the Live Meeting tab, visit the Jitsi URL directly ONCE and
  accept the browser warning:

      https://localhost:8443

  This is not optional. A browser will not load a subresource
  (`external_api.js`) from an origin whose certificate it has not accepted, and
  it gives no prompt when the request comes from a script — so the Live Meeting
  tab would simply stay blank with no visible reason.

  Repeat once per browser and once per browser profile.

NOTE
else
  cat <<'NOTE'

  mkcert certificate installed — no browser warning to accept.
  If a browser was already open, restart it so it picks up the local CA.

NOTE
fi

echo "Next:  docker compose up -d"
