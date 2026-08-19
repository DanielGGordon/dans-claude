#!/usr/bin/env bash
# route-health-banner — SessionStart hook. Two cheap checks, always exit 0:
#
# 1. Never runs tests; only reads the cached result that tests/routecheck.sh
#    wrote to ~/.claude/route-health.txt (format: "<YYYY-MM-DD> <ok|FAIL>
#    [details]"). Warns when routing is broken or the last check is stale (>14d).
# 2. Catalog drift: runs bin/catalog-drift.sh --cached (Cursor `--list-models`
#    + Codex `debug models` vs bin/routes.tsv; catalogs cached 24h in
#    ~/.claude/catalog-<backend>.txt, failed fetches remembered 1h) and prints
#    ONE line if a routed family has a newer version in a catalog (e.g.
#    cursor-grok-4.7-* while routes.tsv stops at 4.6) or a routed id vanished.
#    Fail-open: a missing/slow/unauthenticated CLI gets one line, never a block.
set -u
f="$HOME/.claude/route-health.txt"
if [ -f "$f" ]; then
  d=$(cut -d' ' -f1 "$f"); s=$(cut -d' ' -f2 "$f")
  now=$(date +%s); then_=$(date -d "$d" +%s 2>/dev/null || echo "$now")
  age=$(( (now - then_) / 86400 ))
  if [ "$s" != "ok" ]; then
    echo "[route-health] MODEL ROUTING BROKEN (routecheck $d): $(cat "$f"). Run 'routecheck', then fix or remove the failing entry in ~/.claude/model-usage.md / model-selection.md before delegating to that route."
  elif [ "$age" -gt 14 ]; then
    echo "[route-health] last routecheck was $d (${age}d ago) — model ids may have drifted; run 'routecheck'."
  fi
else
  echo "[route-health] routecheck has never run — run 'routecheck' once to verify model routes."
fi

# --- catalog drift (see header) ---
DRIFT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/bin/catalog-drift.sh"
[ -x "$DRIFT" ] || exit 0
out=$(bash "$DRIFT" --cached </dev/null 2>/dev/null)
drift=$(printf '%s\n' "$out" | awk -F'\t' '$1=="newer"||$1=="vanished"{print $2}' | paste -sd';' - | sed 's/;/; /g')
unavail=$(printf '%s\n' "$out" | awk -F'\t' '$1=="unavailable"{print $2}' | paste -sd';' - | sed 's/;/; /g')
[ -n "$drift" ]   && echo "[route-health] $drift — run 'routecheck' / update bin/routes.tsv (then model-selection.md + model-usage.md)."
[ -n "$unavail" ] && echo "[route-health] catalog drift check skipped — $unavail"
exit 0
