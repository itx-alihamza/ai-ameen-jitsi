#!/usr/bin/env bash
#
# Start the Jitsi stack with the profiles this deployment's .env actually asks for.
#
# WHY THIS EXISTS: `jigasi` (the live-transcription bridge) sits behind
# `profiles: ['transcription']` in docker-compose.yml, which is the right default
# — it is an opt-in service that joins conferences and streams audio, so it must
# not start just because someone ran `docker compose up`.
#
# But the consequence is a silent failure mode that has already bitten this
# deployment once: a bare `docker compose up -d` starts web/prosody/jicofo/jvb
# and skips jigasi, Jicofo then reports `transcriber_count: 0`, and every
# transcription request fails with "no instances available" — with nothing in
# jigasi's logs (it isn't running), nothing in Jicofo's (a zero count is not an
# error), and nothing in Ameen's (the lease arms fine; no audio ever arrives).
# The stack looks completely healthy while the feature is dead.
#
# The fix is to make the profile follow the configuration rather than the
# operator's memory: if ENABLE_TRANSCRIPTIONS=1 in .env, the transcription
# profile is included. One switch, one place.
#
# Everything else is passed straight through, so `./up.sh --force-recreate` and
# friends work exactly as they would with `docker compose up -d`.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "error: no .env here. Run ./setup-local.sh first." >&2
  exit 1
fi

# Read the flag without sourcing .env — that file holds secrets, and sourcing it
# would export every one of them into this shell and its children.
ENABLE_TRANSCRIPTIONS="$(grep -E '^ENABLE_TRANSCRIPTIONS=' .env | tail -1 | cut -d= -f2- | tr -d '"'\''[:space:]')"

PROFILES=()
if [[ "${ENABLE_TRANSCRIPTIONS:-0}" == "1" ]]; then
  PROFILES=(--profile transcription)
  echo "ENABLE_TRANSCRIPTIONS=1 → including the transcription profile (jigasi + autoheal)"
else
  echo "ENABLE_TRANSCRIPTIONS is not 1 → transcription bridge will NOT start"
fi

docker compose "${PROFILES[@]}" up -d "$@"

echo
docker compose "${PROFILES[@]}" ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

if [[ ${#PROFILES[@]} -gt 0 ]]; then
  echo
  echo "Transcription is enabled. Confirm Jicofo can actually see the bridge:"
  echo "    ./verify-transcription.sh"
fi
