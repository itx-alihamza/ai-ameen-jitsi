#!/usr/bin/env bash
#
# Fills the password/secret fields in ./.env with fresh random values: the four
# core Jitsi ones, plus the three live-transcription ones (jigasi is behind a
# compose profile and off unless explicitly started — see README §"Live
# transcription" — but its secrets are still generated here so `docker compose
# --profile transcription up -d` has something valid to read).
#
# WHY A SCRIPT: the upstream docker-jitsi-meet `gen-passwords.sh` generates
# passwords for jibri (a service this deployment does not run at all) and does
# not know about JWT_APP_SECRET or the transcription secrets, which are Ameen's
# own. This generates exactly what this stack needs.
#
# SAFETY: refuses to overwrite a value that is already set, so re-running it
# after adding one service cannot silently rotate the others and lock the running
# stack out of its own Prosody. Rotate deliberately with --force.
#
# Usage:
#   ./generate-secrets.sh              # fill only empty values
#   ./generate-secrets.sh --force      # rotate every value (see README §Rotation)

set -euo pipefail

cd "$(dirname "$0")"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ ! -f .env ]]; then
  echo "No .env found. Create it first:  cp .env.example .env" >&2
  exit 1
fi

# `openssl rand -hex` rather than $RANDOM or a date-seeded value: these are
# credentials, and a predictable generator here is the same weakness as a weak
# password.
random_hex() { openssl rand -hex "$1"; }

# JWT_APP_SECRET gets 32 bytes (256 bits) because it signs HS256 join tokens —
# the recommended key length for that algorithm. The internal service passwords
# get 24 bytes, which is far beyond what an XMPP component password needs.
set_value() {
  local key="$1" value="$2"
  local current
  current="$(grep -E "^${key}=" .env | head -1 | cut -d= -f2- || true)"

  if [[ -n "$current" && $FORCE -eq 0 ]]; then
    echo "  ${key}: already set, leaving it (use --force to rotate)"
    return
  fi

  if grep -qE "^${key}=" .env; then
    # A portable in-place edit: BSD sed (macOS) and GNU sed disagree on -i.
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" -F= '
      $1 == k { print k "=" v; next }
      { print }
    ' .env > "$tmp"
    mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
  echo "  ${key}: generated"
}

echo "Generating secrets in $(pwd)/.env"
set_value JWT_APP_SECRET             "$(random_hex 32)"
set_value JICOFO_AUTH_PASSWORD       "$(random_hex 24)"
set_value JVB_AUTH_PASSWORD          "$(random_hex 24)"
set_value JIGASI_XMPP_PASSWORD       "$(random_hex 24)"
set_value JIGASI_TRANSCRIBER_PASSWORD "$(random_hex 24)"
set_value TRANSCRIPTION_INGEST_SECRET "$(random_hex 32)"

chmod 600 .env

cat <<'NOTE'

Done. Follow-up steps:

  1. Copy JWT_APP_SECRET and JWT_APP_ID into the Ameen backend's .env as
     JITSI_JWT_APP_SECRET and JITSI_JWT_APP_ID. They must match exactly, or
     every join is rejected with an authentication failure.

  2. If this stack was already running with different internal passwords, the
     Prosody volume still holds the old registrations:

       docker compose down
       docker volume rm jitsi_jitsi-prosody-config
       docker compose up -d

     Rotating JICOFO_AUTH_PASSWORD or JVB_AUTH_PASSWORD without clearing that
     volume leaves jicofo and jvb unable to authenticate, which presents as
     conferences that never connect.

  3. Only if you intend to turn on live transcription (see README §"Live
     transcription" first — it changes a privacy guarantee this stack
     otherwise makes): copy the just-generated TRANSCRIPTION_INGEST_SECRET
     into the Ameen backend's .env too (same key name, same value), then set
     TRANSCRIPTION_WEBSOCKET_URL here using the token this secret derives —
     print it with:

       node -e "console.log(require('crypto').createHmac('sha256', process.env.TRANSCRIPTION_INGEST_SECRET).update('live-transcription-ingest').digest('hex'))"

     run from a shell that has TRANSCRIPTION_INGEST_SECRET exported.

NOTE
