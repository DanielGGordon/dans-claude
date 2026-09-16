#!/usr/bin/env bash
# system-map-banner — SessionStart hook. Prints the compact [alfred] block:
# which of Alfred's units are up, the two loopback health checks, and a pointer
# at ~/.claude/system-map.md (the canonical map of repos/ports/units/edges that
# every multi-component task must read, and update when it changes).
#
# Modelled on route-health-banner.sh: it never probes anything itself — it
# prints a cache that bin/system-map-probe.sh writes, refreshing that cache at
# most every SYSTEM_MAP_MAX_AGE seconds (default 600). Fail-open, always exit 0,
# never more than 8 lines.
set -u

STATE="${SYSTEM_MAP_STATE:-$HOME/.claude/system-map.state}"
MAX_AGE="${SYSTEM_MAP_MAX_AGE:-600}"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PROBE="$REPO/bin/system-map-probe.sh"

stale=1
if [ -f "$STATE" ]; then
  mt=$(stat -c %Y "$STATE" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - mt )) -lt "$MAX_AGE" ] && stale=0
fi

if [ "$stale" = 1 ] && [ -f "$PROBE" ]; then
  timeout 10 bash "$PROBE" </dev/null >/dev/null 2>&1 || true
fi

[ -f "$STATE" ] || exit 0
grep -v '^#' "$STATE" 2>/dev/null | head -8
exit 0
