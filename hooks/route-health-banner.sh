#!/usr/bin/env bash
# route-health-banner — SessionStart hook. Four cheap checks, always exit 0:
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
#    `unrouted` ids (catalog ids no routes.tsv row accounts for — hundreds until
#    triaged) are the daily model scout's input, so they're NOT shown while its
#    cron line is installed; without the scout they get a one-line count.
#    Fail-open: a missing/slow/unauthenticated CLI gets one line, never a block.
# 4. Model scout: reads ~/.claude/model-scout/last-run.json (written by the
#    daily bin/model-scout.sh cron job) and prints ONE [model-scout] line only
#    when it's actionable: the last run failed, a scout PR is waiting for
#    review (`open_pr`, kept across later no-change runs), or the last run is
#    >36h old while the cron line is installed (so opting out with
#    MODEL_SCOUT_CRON=0 doesn't nag forever) — including a cron job that has
#    never managed to write last-run.json at all. No network calls.
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

# Is the daily model scout scheduled? (checks 3 and 4; local crontab read only)
cron_on=0
crontab -l 2>/dev/null | grep -qE '(^|[[:space:]])# claude-model-scout[[:space:]]*$' && cron_on=1

# --- catalog drift (see header) ---
DRIFT="$REPO/bin/catalog-drift.sh"
if [ -x "$DRIFT" ]; then
  out=$(bash "$DRIFT" --cached </dev/null 2>/dev/null)
  drift=$(printf '%s\n' "$out" | awk -F'\t' '$1=="newer"||$1=="vanished"{print $2}' | paste -sd';' - | sed 's/;/; /g')
  unavail=$(printf '%s\n' "$out" | awk -F'\t' '$1=="unavailable"{print $2}' | paste -sd';' - | sed 's/;/; /g')
  [ -n "$drift" ]   && echo "[route-health] $drift — run 'routecheck' / update bin/routes.tsv (then model-selection.md + model-usage.md)."
  [ -n "$unavail" ] && echo "[route-health] catalog drift check skipped — $unavail"
  if [ "$cron_on" = 0 ]; then
    unr=$(printf '%s\n' "$out" | awk -F'\t' '$1=="unrouted"{split($2, a, " unrouted id"); n=a[1]; sub(/.* /, "", n); t+=n} END {if (t) print t}')
    [ -n "$unr" ] && echo "[route-health] $unr catalog id(s) are neither routed nor ignored in bin/routes.tsv (the daily model scout is not scheduled) — list: bin/catalog-drift.sh --unrouted --cached"
  fi
fi

# --- model scout (see header) ---
SCOUT_DIR="${MODEL_SCOUT_HOME:-$HOME/.claude/model-scout}"
SCOUT_STATE="$SCOUT_DIR/last-run.json"
if [ ! -f "$SCOUT_STATE" ] && [ "$cron_on" = 1 ] && [ -d "$SCOUT_DIR" ]; then
  # install.sh made the dir when it scheduled the job; >36h later with no state
  # file, the job has never completed a run (wrong checkout, dies before its trap…).
  since_h=$(( ($(date +%s) - $(stat -c %Y "$SCOUT_DIR")) / 3600 ))
  [ "$since_h" -gt 36 ] && echo "[model-scout] the daily cron job is installed but has never recorded a run (${since_h}h) — see $SCOUT_DIR/cron.log"
fi
if [ -f "$SCOUT_STATE" ]; then
  python3 - "$SCOUT_STATE" "$cron_on" <<'PY' 2>/dev/null
import json, sys, time
d = json.load(open(sys.argv[1])); cron_on = sys.argv[2] == "1"
parts = []
status, date, summary = d.get("status"), d.get("date", "?"), (d.get("summary") or "")[:160]
open_pr = d.get("open_pr") or (d.get("pr_url") if status == "pr" else None)
if status == "failed":
    parts.append(f"last run FAILED ({date}): {summary} — log {d.get('log', '?')}")
if open_pr:
    parts.append(f"routing PR awaiting review: {open_pr}" + (f" — {summary}" if status == "pr" else ""))
age_h = (time.time() - (d.get("finished_at") or 0)) / 3600
if cron_on and age_h > 36:
    parts.append(f"last run was {date} ({age_h:.0f}h ago) — the daily cron job isn't running; see ~/.claude/model-scout/cron.log")
if parts:
    print("[model-scout] " + "; ".join(parts))
PY
fi
exit 0
