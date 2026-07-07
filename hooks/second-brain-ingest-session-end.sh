#!/usr/bin/env bash
#
# SessionEnd hook: trigger a second-brain quick ingest.
#
# When a Claude Code session ends, POST to the local second-brain service
# so the just-ended session becomes searchable within seconds instead of
# waiting for the next scheduled ingest.
#
# Reads the service port and auth token from ~/.second-brain/config.json
# (jq if available, python3 otherwise). If the config is missing or the
# service is down, exits silently — this hook must NEVER make session
# exit noisy or slow. Always exits 0.

CONFIG="$HOME/.second-brain/config.json"

# No second-brain on this machine — nothing to do
[ -f "$CONFIG" ] || exit 0

# Consume hook JSON on stdin (unused, but keeps the pipe clean)
cat > /dev/null

if command -v jq >/dev/null 2>&1; then
  PORT=$(jq -r '.port // empty' "$CONFIG" 2>/dev/null)
  TOKEN=$(jq -r '.token // empty' "$CONFIG" 2>/dev/null)
else
  PORT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('port',''))" "$CONFIG" 2>/dev/null)
  TOKEN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('token',''))" "$CONFIG" 2>/dev/null)
fi

[ -n "$PORT" ] && [ -n "$TOKEN" ] || exit 0

curl -s -m 5 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/api/ingest" > /dev/null 2>&1

exit 0
