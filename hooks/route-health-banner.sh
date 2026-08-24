#!/usr/bin/env bash
# route-health-banner — SessionStart hook. Three cheap checks, always exit 0:
#
# 1. Never runs tests; only reads the cached result that tests/routecheck.sh
#    wrote to ~/.claude/route-health.txt (format: "<YYYY-MM-DD> <ok|FAIL>
#    [details]"). Warns when routing is broken or the last check is stale (>14d).
# 2. CLI change: compares bin/cli-fingerprint.sh (path+size+mtime of claude /
#    codex / cursor-agent — no process spawned) against
#    ~/.claude/route-health-tools.txt, which routecheck wrote at its last full
#    run. Any changed tool -> one line naming old -> new version and asking for
#    a re-run of routecheck + the orchestration smoke workflows. This is the
#    "test after every Claude Code / Cursor CLI / Codex update" trigger.
# 3. Catalog drift: runs bin/catalog-drift.sh --cached (Cursor `--list-models`
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

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# --- CLI changed since last routecheck (see header) ---
FP="$REPO/bin/cli-fingerprint.sh"; TOOLS="${ROUTE_HEALTH_TOOLS:-$HOME/.claude/route-health-tools.txt}"
if [ -x "$FP" ] && [ -f "$TOOLS" ]; then
  changed=""
  while IFS=$'\t' read -r tool fp; do
    [ -n "$tool" ] || continue
    old_fp=$(awk -F'\t' -v t="$tool" '$1==t{print $2; exit}' "$TOOLS")
    old_ver=$(awk -F'\t' -v t="$tool" '$1==t{print $3; exit}' "$TOOLS")
    [ -n "$old_fp" ] || continue          # tool wasn't installed at last routecheck; nothing to compare
    [ "$fp" = "$old_fp" ] && continue
    new_ver=$(timeout 20 "$tool" --version 2>/dev/null | head -1)
    [ -n "$new_ver" ] && [ "$new_ver" = "$old_ver" ] && continue   # same version reinstalled — nothing to re-test
    changed="${changed:+$changed; }$tool ${old_ver:-?} -> ${new_ver:-?}"
  done < <(bash "$FP" 2>/dev/null)
  [ -n "$changed" ] && echo "[route-health] CLI changed since last routecheck ($(cut -d' ' -f1 "$HOME/.claude/route-health.txt" 2>/dev/null)): $changed — run 'routecheck', then the orchestration smoke workflows (tests/workflows/) to re-verify delegation."
fi

# --- catalog drift (see header) ---
DRIFT="$REPO/bin/catalog-drift.sh"
[ -x "$DRIFT" ] || exit 0
out=$(bash "$DRIFT" --cached </dev/null 2>/dev/null)
drift=$(printf '%s\n' "$out" | awk -F'\t' '$1=="newer"||$1=="vanished"{print $2}' | paste -sd';' - | sed 's/;/; /g')
unavail=$(printf '%s\n' "$out" | awk -F'\t' '$1=="unavailable"{print $2}' | paste -sd';' - | sed 's/;/; /g')
[ -n "$drift" ]   && echo "[route-health] $drift — run 'routecheck' / update bin/routes.tsv (then model-selection.md + model-usage.md)."
[ -n "$unavail" ] && echo "[route-health] catalog drift check skipped — $unavail"
exit 0
