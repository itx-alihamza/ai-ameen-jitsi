#!/usr/bin/env bash
#
# Backs up the Jitsi deployment's CONFIGURATION.
#
# There is no user data in this stack: meetings, minutes, decisions, and
# attendance all live in Ameen's PostgreSQL, and no audio or video exists here at
# all. What this preserves is the state that would otherwise have to be
# regenerated — Prosody's component registrations and the TLS certificate — so a
# rebuild does not mean re-issuing certificates and re-registering services.
#
# The archive contains `.env`, which contains JWT_APP_SECRET. Treat the output
# directory as a secret: store it encrypted and off-host.
#
# Usage:
#   ./backup.sh [destination-directory]     # default: ./backups

set -euo pipefail

cd "$(dirname "$0")"

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-./backups}/jitsi-$STAMP"
mkdir -p "$DEST"

if [[ -f .env ]]; then
  cp .env "$DEST/env.backup"
else
  echo "warning: no .env found — the restore will need one reconstructed by hand" >&2
fi

# Volume names are prefixed with the compose project name, which defaults to the
# directory name (`jitsi`). Resolved rather than assumed so a stack started with an
# explicit -p still backs up correctly.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$(pwd)")}"

for volume in web-config prosody-config prosody-plugins jicofo-config jvb-config; do
  full="${PROJECT}_jitsi-${volume}"
  if ! docker volume inspect "$full" >/dev/null 2>&1; then
    echo "  skipping $full (does not exist)"
    continue
  fi
  # An alpine sidecar rather than `docker cp`: the volume is read straight from
  # the daemon, so the stack does not have to be running.
  docker run --rm \
    -v "${full}:/source:ro" \
    -v "$(cd "$DEST" && pwd):/backup" \
    alpine tar czf "/backup/${volume}.tar.gz" -C /source .
  echo "  backed up $full"
done

chmod -R go-rwx "$DEST"
echo "Backup written to $DEST"
echo "This archive contains JWT_APP_SECRET. Store it encrypted and off-host."
