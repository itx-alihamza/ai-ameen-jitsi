#!/usr/bin/env bash
#
# Verify the live-transcription chain end to end, and name the exact broken link.
#
# WHY EACH STEP IS SEPARATE: every link in this chain fails silently on its own.
# "Transcription doesn't work" has at least five distinct causes that look
# identical from the Ameen UI (the Live Meeting tab just says "waiting" forever),
# so a single pass/fail would send an operator hunting. Each check below fails
# with the one thing to go fix.
#
# The chain:
#   1. jigasi container is running                (profile not started → silent)
#   2. Jicofo counts >= 1 transcriber             (brewery join stale → silent)
#   3. jigasi is in transcriber mode              (JIGASI_MODE unset → silent)
#   4. the ingest URL is rendered into its config (wrong var name → silent)
#   5. the Ameen backend answers on that URL      (backend down → silent)
#   6. the ingest token matches the backend's     (secret drift → 401, silent)
#
# Exits non-zero on the first failure so this is usable as a deployment gate.

set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; echo "    → $2"; FAIL=$((FAIL+1)); }

echo
echo "Live transcription chain"
echo

# ── 1. jigasi running ────────────────────────────────────────────────────────
STATE="$(docker compose --profile transcription ps -a --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="jigasi"{print $2}')"
if [[ "$STATE" == "running" ]]; then
  ok "jigasi container is running"
else
  bad "jigasi is '${STATE:-absent}', not running" \
      "Start it with ./up.sh (a bare 'docker compose up -d' skips the profile)."
  echo; echo "  $PASS passed, $FAIL failed"; exit 1
fi

# ── 2. Jicofo sees a transcriber ─────────────────────────────────────────────
# This is the assertion that actually matters. jigasi can be up, logging nothing
# wrong, while its brewery membership has gone stale and Jicofo has quietly
# stopped routing to it.
COUNT="$(docker compose exec -T jicofo curl -fsS http://localhost:8888/stats 2>/dev/null \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{process.stdout.write(String(JSON.parse(d).jigasi_detector?.transcriber_count??0))}catch{process.stdout.write('0')}})" 2>/dev/null)"
if [[ "${COUNT:-0}" -ge 1 ]]; then
  ok "Jicofo sees ${COUNT} transcriber(s)"
else
  bad "Jicofo reports transcriber_count=0" \
      "jigasi is running but has not registered. Check 'docker compose logs jigasi' for a SASL or DNS failure, then restart it."
fi

# ── 3 & 4. jigasi's own rendered config ──────────────────────────────────────
CFG="$(docker compose exec -T jigasi cat /config/sip-communicator.properties 2>/dev/null)"
if grep -q 'ENABLE_TRANSCRIPTION=true' <<<"$CFG"; then
  ok "jigasi is in transcriber mode"
else
  bad "jigasi is not in transcriber mode" \
      "JIGASI_MODE must be exactly 'transcriber'; otherwise every JIGASI_TRANSCRIBER_* var is ignored."
fi

INGEST_URL="$(grep -E '^org\.jitsi\.jigasi\.transcription\.vosk\.websocket_url=' <<<"$CFG" | cut -d= -f2-)"
if [[ -n "$INGEST_URL" ]]; then
  ok "ingest URL is rendered into jigasi's config"
else
  bad "vosk.websocket_url is empty in the rendered config" \
      "The image reads JIGASI_TRANSCRIBER_VOSK_URL — not ..._VOSK_WEBSOCKET_URL. Check that name in docker-compose.yml."
fi

# ── 5 & 6. the Ameen ingest endpoint ─────────────────────────────────────────
# Reached from the host, so host.docker.internal is rewritten to localhost. This
# checks the backend answers and that the token is accepted — a bad token is
# refused at the HTTP upgrade with a bare 401 and no detail, by design.
if [[ -n "$INGEST_URL" ]]; then
  HOST_URL="${INGEST_URL/host.docker.internal/127.0.0.1}"
  # `ws` is a backend dependency, not a dependency of this directory (which has no
  # package.json at all), so point Node's resolver at the backend's tree.
  export NODE_PATH="$(cd ../ai-ameen-migrated-backend 2>/dev/null && pwd)/node_modules"
  RESULT="$(node -e '
    const WebSocket = require("ws");
    const ws = new WebSocket(process.argv[1], { handshakeTimeout: 5000 });
    const done = (s) => { console.log(s); try { ws.close(); } catch {} process.exit(0); };
    ws.on("open",  () => done("OPEN"));
    ws.on("close", (code) => done("CLOSE:" + code));
    ws.on("unexpected-response", (_, res) => done("HTTP:" + res.statusCode));
    ws.on("error", (e) => done("ERR:" + (e && e.message ? e.message.slice(0, 60) : "unknown")));
    setTimeout(() => done("TIMEOUT"), 8000);
  ' "$HOST_URL" 2>/dev/null)"

  case "$RESULT" in
    OPEN|CLOSE:1008)
      # 1008 = authenticated, but no meeting currently holds the transcription
      # lease. That is the correct resting state when no meeting is live.
      ok "Ameen ingest endpoint reachable and token accepted (${RESULT})" ;;
    HTTP:401)
      bad "ingest endpoint rejected the token (401)" \
          "TRANSCRIPTION_INGEST_SECRET differs between ai-ameen-jitsi/.env and the backend .env. Regenerate the URL after aligning them." ;;
    ERR:*|TIMEOUT)
      bad "could not reach the Ameen ingest endpoint (${RESULT})" \
          "Is the backend running on :3001? Jigasi reaches it via host.docker.internal." ;;
    *)
      bad "unexpected ingest response (${RESULT})" "Inspect the backend log for the upgrade handler." ;;
  esac
fi

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
echo
echo "  Chain is healthy. For a real speech + diarization check, run from the backend:"
echo "    npx tsx scripts/verify-transcription-speech.ts --lang ar --audio <file.wav>"
