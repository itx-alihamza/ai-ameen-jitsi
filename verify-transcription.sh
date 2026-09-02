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

# ── 0. The media address JVB advertises ──────────────────────────────────────
# Checked FIRST because when it is wrong, everything downstream still looks
# perfectly healthy: jigasi runs, registers, is invited, and joins the room —
# then receives no audio at all, because ICE cannot complete for ANY
# participant. The symptom is a transcript stuck on "Processing" forever, and
# the cause is invisible unless you happen to compare two numbers.
#
# This bites on any laptop that moves between networks, since DOCKER_HOST_ADDRESS
# is a fixed value in .env while the machine's LAN address is not.
HOST_IP="$(ifconfig 2>/dev/null | grep -E '^[[:space:]]*inet ' | grep -v 127.0.0.1 | awk '{print $2}' | head -1)"
ADVERTISED="$(grep -E '^DOCKER_HOST_ADDRESS=' .env | tail -1 | cut -d= -f2- | tr -d '"'\''[:space:]')"
if [[ -z "$HOST_IP" ]]; then
  ok "skipping media-address check (no LAN address detected)"
elif [[ "$ADVERTISED" == "$HOST_IP" ]]; then
  ok "JVB advertises this machine's current LAN address (${HOST_IP})"
else
  bad "JVB advertises ${ADVERTISED:-<unset>}, but this machine is ${HOST_IP}" \
      "Media cannot reach the bridge, so jigasi receives no audio and the transcript never fills. Set DOCKER_HOST_ADDRESS=${HOST_IP} and JVB_ADVERTISE_IPS=172.20.0.3,${HOST_IP} in .env, then: docker compose up -d --force-recreate jvb"
fi

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
# ── 5a. Reachability FROM INSIDE the container ───────────────────────────────
# Checked from jigasi's own network namespace, not from the host, because those
# are different paths and only this one is real. Testing from the host by
# rewriting host.docker.internal → 127.0.0.1 (which this script used to do)
# passes on a deployment where jigasi cannot reach the backend at all: on Docker
# Desktop for Mac `host-gateway` resolves to an IPv6 address with no IPv4-listening
# process behind it, and jigasi's Jetty client — unlike curl — does not fall back.
if [[ -n "$INGEST_URL" ]]; then
  INGEST_HOST="$(sed -E 's|^wss?://([^:/]+).*|\1|' <<<"$INGEST_URL")"
  INGEST_PORT="$(sed -E 's|^wss?://[^:/]+:([0-9]+).*|\1|' <<<"$INGEST_URL")"
  CODE="$(docker compose exec -T jigasi sh -c \
    "timeout 6 curl -sS -o /dev/null -w '%{http_code}' http://${INGEST_HOST}:${INGEST_PORT:-3001}/health 2>/dev/null" 2>/dev/null | tr -dc '0-9')"
  if [[ "$CODE" == "200" ]]; then
    ok "jigasi can reach the backend at ${INGEST_HOST} (from inside the container)"
  else
    RESOLVED="$(docker compose exec -T jigasi sh -c "getent hosts ${INGEST_HOST}" 2>/dev/null | awk '{print $1}' | head -1)"
    bad "jigasi cannot reach the backend at ${INGEST_HOST} (HTTP ${CODE:-000}); it resolves to ${RESOLVED:-nothing}" \
        "If that is an IPv6 address, set HOST_GATEWAY_IP in .env to an IPv4 the container can reach (Docker Desktop for Mac: 192.168.65.254), then: docker compose --profile transcription up -d --force-recreate jigasi"
  fi
fi

# ── 6. Token accepted, and the stream not immediately refused ────────────────
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
