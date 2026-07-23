#!/usr/bin/env bash
# route-health-banner — SessionStart hook. Never runs tests; only reads the
# cached result that tests/routecheck.sh wrote to ~/.claude/route-health.txt
# (format: "<YYYY-MM-DD> <ok|FAIL> [details]"). Emits a warning into session
# context only when routing is broken or the last check is stale (>14d).
set -u
f="$HOME/.claude/route-health.txt"
[ -f "$f" ] || { echo "[route-health] routecheck has never run — run 'routecheck' once to verify model routes."; exit 0; }
d=$(cut -d' ' -f1 "$f"); s=$(cut -d' ' -f2 "$f")
now=$(date +%s); then_=$(date -d "$d" +%s 2>/dev/null || echo "$now")
age=$(( (now - then_) / 86400 ))
if [ "$s" != "ok" ]; then
  echo "[route-health] MODEL ROUTING BROKEN (routecheck $d): $(cat "$f"). Run 'routecheck', then fix or remove the failing entry in ~/.claude/model-usage.md / model-selection.md before delegating to that route."
elif [ "$age" -gt 14 ]; then
  echo "[route-health] last routecheck was $d (${age}d ago) — model ids may have drifted; run 'routecheck'."
fi
exit 0
