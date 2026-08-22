#!/usr/bin/env bash
#
# Fills the four password fields in ./.env with fresh random values.
#
# WHY A SCRIPT: the upstream docker-jitsi-meet `gen-passwords.sh` generates
# passwords for services this deployment does not run (jibri, jigasi), and does
# not know about JWT_APP_SECRET, which is the one that actually gates access to
# Ameen board meetings. This generates exactly the four this stack needs.
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
set_value JWT_APP_SECRET        "$(random_hex 32)"
set_value JICOFO_AUTH_PASSWORD  "$(random_hex 24)"
set_value JVB_AUTH_PASSWORD     "$(random_hex 24)"

chmod 600 .env

cat <<'NOTE'

Done. Two follow-up steps, both required:

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

NOTE
