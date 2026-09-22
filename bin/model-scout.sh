#!/usr/bin/env bash
# model-scout — the DAILY unattended model-routing maintainer (cron, installed
# by install.sh). Exists because every model bump so far was noticed by hand,
# late: grok-4.7 (2026-09-21) was only routed the next day because
# catalog-drift happened to flag it, and on 2026-09-22 Claude Opus 5.5, GPT-6
# Sol and GPT-6 Luna all shipped the same day — a new GPT-6 *tier* and a new
# Claude family that catalog-drift's version-max logic cannot see at all.
#
#   bash ~/dotfiles/claude/bin/model-scout.sh [--base <ref>] [--no-pr] [--repo <dir>] [--dry-run]
#
#   --base <ref>  base the scout worktree on <ref> (default: origin/master after
#                 fetch, or the branch of an already-open claude/model-scout-* PR)
#   --no-pr       commit on a local branch only (printed); never push / open a PR
#   --repo <dir>  repo to work from (default ~/dotfiles/claude)
#   --dry-run     run the zero-token pre-steps + cleanup only; skip the agentic
#                 step, commit and push
#
# One run:
#  1. flock single-instance; log to ~/.claude/model-scout/logs/<YYYY-MM-DD>.log
#     (30 days kept, plus <date>.report.md / .grok.md / .review.md / .patch).
#  2. A throwaway git worktree of --repo in ~/.cache/model-scout/wt-<date>,
#     detached at the base — the live ~/dotfiles/claude checkout is never touched.
#  3. Deterministic pre-steps (zero model tokens except routecheck's ~100/route),
#     captured as "signals": CLI versions (cli-fingerprint.sh), tests/routecheck.sh,
#     catalog-drift.sh live + --unrouted.
#  4. Agentic step: headless `claude -p --no-session-persistence` (opus, high
#     effort, bypassPermissions — unattended, confined to the worktree by the
#     prompt AND by --disallowedTools deny rules + refusing git commit/push
#     hooks: no commit, push, gh pr write, crontab or install.sh) running
#     scout/prompt.md + the signals, hard timeout
#     MODEL_SCOUT_TIMEOUT (5400s). It researches (grok recency FIRST, then
#     Claude WebSearch, then the live catalogs), edits the routing table/docs,
#     re-runs routecheck, gets a gpt-6-astra second review and writes
#     scout/last-report.md. It must write a status line and the grok output to
#     files this script checks — a run that skipped (or failed) the mandatory
#     grok pass fails; one whose grok reported no X search is published but
#     recorded failed. Every routecheck in the run writes its verdict to the
#     artifacts dir (ROUTE_HEALTH_FILE/_TOOLS), never the live banner's files,
#     except the pre-run one on an unmodified origin/master.
#  5. Gate + publish: only files on an allowlist may change (anything else is
#     reverted and logged); `routecheck --no-live` must pass; then commit on
#     claude/model-scout-<date> (or the open scout PR's branch — at most ONE
#     open scout PR: a failed `gh pr list` aborts rather than risk a second;
#     the PR's state is re-checked right before pushing — MERGED replays the
#     commit onto origin/master, CLOSED/unknown keeps it on a local branch and
#     fails), push, and `gh pr create` against master with
#     scout/last-report.md as the body. Never pushes to master.
#  6. ALWAYS (EXIT trap): retry any queued failed cleanups, then
#     bin/test-chat-cleanup.sh for this run's marker + workdirs and
#     bin/t3-purge-test-threads.sh --apply (a failure is queued in
#     ~/.claude/model-scout/pending-cleanup.tsv and marks the run failed),
#     remove the worktree and temp dirs, then write last-run.json.
#
# No test chat may survive a run: every model call runs with
# MODEL_RUN_EPHEMERAL=1 (codex --ephemeral), in a mktemp workdir (cursor has no
# ephemeral flag — its chats are keyed by cwd), with a per-run marker
# MODEL-SCOUT-<date>-<rand> in the prompt (ROUTECHECK_MARKER shares it with
# routecheck); claude runs with --no-session-persistence. The cleanup scripts
# are the backstop, and they are run from THIS script's directory (the checked
# out master), never from the worktree the agent was allowed to edit.
#
# State ~/.claude/model-scout/last-run.json (read by hooks/route-health-banner.sh):
#   {date, status: "no-change"|"pr"|"failed", pr_url, summary, log,
#    finished_at, started_at, last_success, marker, branch, cleanup, open_pr}
# open_pr = a scout PR known to be open, kept across no-change runs. "failed"
# also covers runs that worked but left something actionable (DEGRADED:
# cleanup incomplete, live routecheck still failing, grok without X search);
# last_success follows the research outcome, not those.
# Exit: 0 no-change / pr / dry-run · 1 failed · 0 (silently) when another run
# holds the lock. Auth/quota errors (model-run exit 75, claude login/usage
# limits) fail loudly into last-run.json — never substituted.
#
# Env: MODEL_SCOUT_HOME (~/.claude/model-scout) · MODEL_SCOUT_CACHE
# (~/.cache/model-scout) · MODEL_SCOUT_TIMEOUT (5400) · MODEL_SCOUT_MODEL (opus)
# · MODEL_SCOUT_EFFORT (high) · MODEL_SCOUT_ROUTECHECK=live|free|skip (live;
# free = `--no-live`) · MODEL_SCOUT_BUDGET_USD (unset = no --max-budget-usd cap)
# · MODEL_SCOUT_PROMPT (default: the base's scout/prompt.md).
set -u

# ---------- environment (cron gives us almost nothing) ----------
# The cron line sources ~/.profile; belt and braces for manual/systemd runs:
# claude lives in ~/.local/bin, codex (node) behind mise shims.
for p in "$HOME/.local/share/mise/shims" "$HOME/.local/bin" /usr/local/bin; do
  case ":$PATH:" in *":$p:"*) ;; *) [ -d "$p" ] && PATH="$p:$PATH" ;; esac
done
export PATH

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$HOME/dotfiles/claude"
BASE=""
NO_PR=0
DRY_RUN=0
usage() { sed -n '9,17p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    BASE="${2:-}"; [ -n "$BASE" ] || { usage >&2; exit 64; }; shift 2 ;;
    --repo)    REPO="${2:-}"; [ -n "$REPO" ] || { usage >&2; exit 64; }; shift 2 ;;
    --no-pr)   NO_PR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "model-scout: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || { echo "model-scout: --repo not found" >&2; exit 64; }

SCOUT_HOME="${MODEL_SCOUT_HOME:-$HOME/.claude/model-scout}"
CACHE="${MODEL_SCOUT_CACHE:-$HOME/.cache/model-scout}"
TIMEOUT="${MODEL_SCOUT_TIMEOUT:-5400}"
AGENT_MODEL="${MODEL_SCOUT_MODEL:-opus}"
AGENT_EFFORT="${MODEL_SCOUT_EFFORT:-high}"
ROUTECHECK_MODE="${MODEL_SCOUT_ROUTECHECK:-live}"
DATE=$(date +%F)
LOGDIR="$SCOUT_HOME/logs"
LOG="$LOGDIR/$DATE.log"
STATE="$SCOUT_HOME/last-run.json"
mkdir -p "$LOGDIR" "$CACHE" || { echo "model-scout: cannot create $LOGDIR / $CACHE" >&2; exit 1; }

# ---------- single instance ----------
exec 9>"$SCOUT_HOME/lock"
if ! flock -n 9; then
  echo "model-scout: another run holds $SCOUT_HOME/lock — exiting" >&2
  exit 0
fi

# ---------- logging ----------
# fd 3 = the caller's stdout (cron.log): one line at start and one at the end.
# Everything else goes to the dated log (tee'd to the terminal when interactive).
exec 3>&1
echo "model-scout: $(date -Is) start — log $LOG" >&3
if [ -t 1 ]; then exec > >(tee -a "$LOG") 2>&1; else exec >>"$LOG" 2>&1; fi
log() { echo "[$(date +%T)] $*"; }
section() { echo; echo "===== $* ====="; }

RUN_START=$(date +%s)
MARKER="MODEL-SCOUT-$DATE-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
section "model-scout run $MARKER ($(date -Is))"
log "repo=$REPO base=${BASE:-auto} no_pr=$NO_PR dry_run=$DRY_RUN routecheck=$ROUTECHECK_MODE"

# Previous state: carry last_success forward and derive the research window.
# last_success is always written (null until a real, non-dry run succeeds); a
# dry run records status no-change, so never fall back to its date.
PREV_SUCCESS=$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
print(d["last_success"] or "" if "last_success" in d else (d.get("date") if d.get("status") in ("no-change","pr") else "") or "")' "$STATE" 2>/dev/null)
SINCE="${PREV_SUCCESS:-$(date -d '14 days ago' +%F)}"

STATUS=failed          # pessimistic until the run proves otherwise
SUMMARY="run died before finishing (see log)"
PR_URL=""
OPEN_PR_URL=""         # a scout PR known to be open (kept in state across no-change runs)
BRANCH=""
CLEANUP_NOTE="not run"
DEGRADED=()            # reasons a run that otherwise worked must still be recorded "failed"
WT=""
SCRATCH=$(mktemp -d /tmp/model-scout.XXXXXX)
WORK_ROOT="$SCRATCH/work"            # the agent's throwaway model-call workdirs live here
ARTIFACTS="$SCRATCH/artifacts"       # grok output, second review, status line, signals
REGISTRY="$SCRATCH/workdirs.txt"     # workdirs the agent registered (validated at cleanup)
mkdir -p "$WORK_ROOT" "$ARTIFACTS"; : >"$REGISTRY"

fail() { STATUS=failed; SUMMARY="$*"; log "FAILED: $*"; exit 1; }

# JSON state, written atomically (the SessionStart hook reads it).
write_state() {  # $1 = the status the research itself ended with (before DEGRADED)
  local last_success="$PREV_SUCCESS"
  # A dry run did no research, so it must not shrink the next run's window.
  [ "${1:-$STATUS}" = failed ] || [ "$DRY_RUN" -eq 1 ] || last_success="$DATE"
  python3 - "$STATE" "$DATE" "$STATUS" "$SUMMARY" "$PR_URL" "$LOG" "$RUN_START" \
    "$last_success" "$MARKER" "$BRANCH" "$CLEANUP_NOTE" "$OPEN_PR_URL" <<'PY'
import json, os, sys, time
(p, date, status, summary, pr, log, start, last_ok, marker, branch, cleanup, open_pr) = sys.argv[1:]
d = {"date": date, "status": status, "pr_url": pr or None, "summary": summary,
     "log": log, "finished_at": int(time.time()), "started_at": int(start),
     "last_success": last_ok or None, "marker": marker, "branch": branch or None,
     "cleanup": cleanup, "open_pr": open_pr or None}
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp, p)
PY
}

# ---------- cleanup: ALWAYS runs (EXIT trap) ----------
# Order matters: delete CLI-side test sessions first (so a leaked claude
# transcript is gone before the next 15-min T3 import tick), then T3 threads
# that were already imported, then the worktree/temp dirs, then the state file
# (so last-run.json records what cleanup did).
finish() {
  trap - EXIT INT TERM
  set +e
  section "cleanup"
  local notes=() dirs=() d

  # Save anything uncommitted for the audit trail before the worktree goes.
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    git -C "$WT" add -A >/dev/null 2>&1
    if ! git -C "$WT" diff --cached --quiet 2>/dev/null; then
      git -C "$WT" diff --cached >"$LOGDIR/$DATE.patch" 2>/dev/null
      log "uncommitted worktree changes saved to $LOGDIR/$DATE.patch"
    fi
  fi
  for a in grok-research.md second-review.md; do
    [ -s "$ARTIFACTS/$a" ] && cp "$ARTIFACTS/$a" "$LOGDIR/$DATE.${a%%-*}.md"
  done

  # Workdirs this run owned: the scout worktree (the agent's own cwd — a bare
  # `model-run.sh` call defaults to it), every dir under WORK_ROOT, and the
  # registry entries that really are under WORK_ROOT. Anything else in the
  # registry is ignored: never widen the cleanup blast radius on the agent's say-so.
  [ -n "$WT" ] && dirs+=("$WT")
  while IFS= read -r d; do dirs+=("$d"); done < <(find "$WORK_ROOT" -mindepth 1 -maxdepth 3 -type d 2>/dev/null)
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in
      "$WORK_ROOT"/*) printf '%s\n' "${dirs[@]}" | grep -qxF "$d" || dirs+=("$d") ;;
      *) log "ignoring registered workdir outside $WORK_ROOT: $d" ;;
    esac
  done <"$REGISTRY"
  # A failed sweep is queued in $PENDING (since, marker, workdirs — matching is
  # by cwd string, so the dirs needn't exist any more) and retried first thing
  # in every later run's cleanup until it succeeds: otherwise a thread the
  # importer grabbed while t3code was down stays visible forever, outside every
  # later run's marker/window (review findings 2026-09-22).
  sweep() {  # sweep <since> <marker> [workdir...] -> 0 only if both sweeps succeeded
    local since=$1 marker=$2 wd=() w c t; shift 2
    for w in "$@"; do wd+=(--workdir "$w"); done
    if [ -f "$SELF_DIR/test-chat-cleanup.sh" ]; then
      log "test-chat-cleanup --since $since --marker $marker ($# workdirs)"
      bash "$SELF_DIR/test-chat-cleanup.sh" --since "$since" --marker "$marker" "${wd[@]}" 2>&1 | sed 's/^/  /'
      c=${PIPESTATUS[0]}
    else
      log "WARN: $SELF_DIR/test-chat-cleanup.sh missing — CLI test sessions NOT cleaned"; c=missing
    fi
    if [ -f "$SELF_DIR/t3-purge-test-threads.sh" ]; then
      log "t3-purge-test-threads --since $since --marker $marker --apply"
      bash "$SELF_DIR/t3-purge-test-threads.sh" --since "$since" --marker "$marker" --apply 2>&1 | sed 's/^/  /'
      t=${PIPESTATUS[0]}
    else
      log "WARN: $SELF_DIR/t3-purge-test-threads.sh missing — T3 threads NOT checked"; t=missing
    fi
    SWEEP_NOTE="test-chat-cleanup exit $c; t3-purge exit $t$([ "$t" = 3 ] && echo ' (T3 server down)')"
    [ "$c" = 0 ] && [ "$t" = 0 ]
  }
  local PENDING="$SCOUT_HOME/pending-cleanup.tsv" p_since p_marker p_rest p_wds still=0
  if [ -s "$PENDING" ]; then
    : >"$PENDING.new"
    while IFS=$'\t' read -r p_since p_marker p_rest; do
      [[ "$p_since" =~ ^[0-9]+$ ]] && [ -n "$p_marker" ] || continue
      if [ $(( $(date +%s) - p_since )) -gt $(( 30 * 86400 )) ]; then
        log "dropping queued cleanup $p_marker (>30 days old)"; notes+=("dropped stale queued cleanup $p_marker"); continue
      fi
      IFS=$'\t' read -r -a p_wds <<<"$p_rest"
      if sweep "$p_since" "$p_marker" "${p_wds[@]}"; then
        log "queued cleanup $p_marker done"; notes+=("queued cleanup $p_marker done")
      else
        printf '%s\t%s\t%s\n' "$p_since" "$p_marker" "$p_rest" >>"$PENDING.new"; still=$((still + 1))
        notes+=("queued cleanup $p_marker still failing ($SWEEP_NOTE)")
      fi
    done <"$PENDING"
    mv -f "$PENDING.new" "$PENDING"
  fi

  if sweep "$RUN_START" "$MARKER" "${dirs[@]}"; then
    notes+=("$SWEEP_NOTE")
  else
    notes+=("$SWEEP_NOTE — queued for retry")
    (IFS=$'\t'; printf '%s\t%s\t%s\n' "$RUN_START" "$MARKER" "${dirs[*]}") >>"$PENDING"
    DEGRADED+=("cleanup incomplete ($SWEEP_NOTE) — test chats may be visible; queued in $PENDING")
  fi
  [ "$still" -gt 0 ] && DEGRADED+=("$still earlier cleanup(s) still failing (see $PENDING)")
  [ -s "$PENDING" ] || rm -f "$PENDING"

  # The headless session (cwd = worktree) creates ~/.claude/projects/<enc>/
  # holding only an auto-memory dir even with --no-session-persistence. The
  # path is unique to this run's dated worktree, so drop it unless a transcript
  # somehow landed there (test-chat-cleanup decides about transcripts, not us).
  if [ -n "$WT" ]; then
    local enc; enc="$HOME/.claude/projects/$(printf %s "$WT" | sed 's#[^A-Za-z0-9-]#-#g')"
    if [ -d "$enc" ] && [ -z "$(find "$enc" -name '*.jsonl' -print -quit 2>/dev/null)" ]; then
      rm -rf "$enc" && log "removed transcript-less $enc"
    fi
  fi

  cd / || true   # we're usually sitting in the worktree we're about to delete
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git -C "$REPO" worktree prune >/dev/null 2>&1
    [ -d "$WT" ] && notes+=("worktree NOT removed: $WT") || log "removed worktree $WT"
  fi
  rm -rf "$SCRATCH" && log "removed $SCRATCH"

  find "$LOGDIR" -type f -mtime +30 -delete 2>/dev/null
  CLEANUP_NOTE=$(IFS='|'; echo "${notes[*]}" | sed 's/|/; /g')
  log "cleanup: $CLEANUP_NOTE"
  # The research outcome decides the next run's window; DEGRADED reasons (a
  # failing sweep, routes still broken, grok without X) only make the run
  # visible as failed — an open PR is still recorded in open_pr.
  local research_status="$STATUS" why
  if [ "${#DEGRADED[@]}" -gt 0 ]; then
    why=$(IFS='|'; echo "${DEGRADED[*]}" | sed 's/|/; /g')
    log "DEGRADED: $why"
    if [ "$STATUS" = failed ]; then SUMMARY="$SUMMARY; $why"; else STATUS=failed; SUMMARY="$why — $SUMMARY"; fi
  fi
  write_state "$research_status"
  log "state: $STATUS — $SUMMARY${PR_URL:+ ($PR_URL)}"
  echo "model-scout: $(date -Is) $STATUS — $SUMMARY${PR_URL:+ $PR_URL}${BRANCH:+ [branch $BRANCH]}" >&3
  [ "$STATUS" = failed ] && exit 1
  exit 0
}
trap finish EXIT
trap 'SUMMARY="interrupted by signal"; exit 1' INT TERM

# ---------- preflight ----------
section "preflight"
for t in git python3 flock; do command -v "$t" >/dev/null 2>&1 || fail "required tool missing: $t"; done
if [ "$DRY_RUN" -eq 0 ]; then
  command -v claude >/dev/null 2>&1 || fail "claude CLI not on PATH ($PATH)"
  [ "$NO_PR" -eq 1 ] || command -v gh >/dev/null 2>&1 || fail "gh CLI not on PATH (needed to open the PR; use --no-pr)"
fi
bash "$SELF_DIR/cli-fingerprint.sh" --versions 2>&1 | cut -f1,3 | sed 's/^/  /'

# ---------- base selection ----------
# At most ONE open scout PR: if one exists, today's run stacks on its branch
# and pushes to it, instead of opening a competing PR.
section "base"
REUSE_BRANCH=""; REUSE_URL=""
if command -v gh >/dev/null 2>&1; then
  # A FAILED lookup is not "no open PR": treating it so (API blip, rate limit,
  # timeout) opened a second, conflicting scout PR next to the open one
  # (review finding 2026-09-22). Parse errors count as failures too.
  gh_rc=0
  prs_json=$(cd "$REPO" && timeout 60 gh pr list --state open --limit 100 --json headRefName,url 2>"$ARTIFACTS/gh.err") || gh_rc=$?
  [ "$gh_rc" -eq 0 ] && { open_pr=$(printf '%s' "$prs_json" | python3 -c 'import json,sys
prs=[p for p in json.load(sys.stdin) if p["headRefName"].startswith("claude/model-scout-")]
prs.sort(key=lambda p: p["headRefName"])
print("%s\t%s" % (prs[-1]["headRefName"], prs[-1]["url"]) if prs else "")' 2>>"$ARTIFACTS/gh.err") || gh_rc=97; }
  if [ "$gh_rc" -ne 0 ]; then
    msg="gh pr list failed (exit $gh_rc: $(head -c 200 "$ARTIFACTS/gh.err" | tr '\n' ' ')) — cannot enforce one open scout PR"
    if [ "$DRY_RUN" -eq 1 ] || [ "$NO_PR" -eq 1 ]; then log "WARN: $msg"
    elif [ -n "$BASE" ]; then log "WARN: $msg — explicit --base: committing locally only"; NO_PR=1
    else fail "$msg"; fi
  elif [ -n "$open_pr" ]; then
    IFS=$'\t' read -r REUSE_BRANCH REUSE_URL <<<"$open_pr"
    OPEN_PR_URL="$REUSE_URL"
    log "open scout PR: $REUSE_URL ($REUSE_BRANCH)"
  else
    log "no open scout PR"
  fi
else
  log "gh missing — cannot check for an open scout PR"
fi

if [ -n "$BASE" ]; then
  # An explicit base is a manual/test run: don't stack on the open PR, and
  # don't open a second one next to it either (publish falls back to --no-pr).
  if [ -n "$REUSE_BRANCH" ] && [ "$NO_PR" -eq 0 ]; then
    log "explicit --base with an open scout PR — will commit locally only (no second PR)"
    NO_PR=1
  fi
  REUSE_BRANCH=""; REUSE_URL=""
elif [ -n "$REUSE_BRANCH" ]; then
  timeout 120 git -C "$REPO" fetch --quiet origin "$REUSE_BRANCH" || fail "git fetch of open scout branch $REUSE_BRANCH failed"
  BASE="origin/$REUSE_BRANCH"
else
  timeout 120 git -C "$REPO" fetch --quiet origin master || fail "git fetch origin master failed"
  BASE="origin/master"
fi
BASE_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$BASE^{commit}") || fail "base ref not found: $BASE"
log "base $BASE = $BASE_SHA"

# ---------- worktree ----------
WT="$CACHE/wt-$DATE"
if [ -e "$WT" ]; then   # leftover from a crashed run (the lock guarantees it isn't live)
  log "removing stale worktree $WT"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  git -C "$REPO" worktree prune >/dev/null 2>&1
fi
git -C "$REPO" worktree add --quiet --detach "$WT" "$BASE_SHA" || { WT=""; fail "git worktree add failed"; }
log "worktree $WT (detached at ${BASE_SHA:0:12})"
cd "$WT" || fail "cannot cd to worktree"

# Every model call from here on: codex without session files, routecheck and
# the agent share this run's marker so cleanup can find whatever slipped through.
export MODEL_RUN_EPHEMERAL=1 ROUTECHECK_MARKER="$MARKER"
# Every routecheck here (ours and the agent's) tests an UNDEPLOYED tree, so its
# verdict goes to the artifacts dir, not the live banner's files: a worktree
# that dropped a broken route would otherwise silence [route-health] while the
# live table is still broken (review finding 2026-09-22). The pre-run result is
# published to ~/.claude below only when the tree is exactly origin/master.
LIVE_HEALTH="${ROUTE_HEALTH_FILE:-$HOME/.claude/route-health.txt}"
LIVE_TOOLS="${ROUTE_HEALTH_TOOLS:-$HOME/.claude/route-health-tools.txt}"
export ROUTE_HEALTH_FILE="$ARTIFACTS/route-health.txt" ROUTE_HEALTH_TOOLS="$ARTIFACTS/route-health-tools.txt"
export MODEL_SCOUT_MARKER="$MARKER" MODEL_SCOUT_TMP="$WORK_ROOT" MODEL_SCOUT_WORKDIRS="$REGISTRY"
export MODEL_SCOUT_ARTIFACTS="$ARTIFACTS" MODEL_SCOUT_DATE="$DATE" MODEL_SCOUT_SINCE="$SINCE"

# ---------- deterministic pre-steps → signals ----------
section "signals"
SIG="$ARTIFACTS/signals.md"
fence() { echo '```'; cat; echo '```'; }
{
  echo "## Run context (written by bin/model-scout.sh — values are literal, use them as-is)"
  echo
  echo "- Today: **$DATE**. Research window: **$SINCE → $DATE** (last successful scout run: ${PREV_SUCCESS:-none — first run, window is 14 days})."
  echo "- Worktree (your cwd; edit ONLY here): \`$WT\`"
  echo "- Base: \`$BASE\` (\`${BASE_SHA:0:12}\`)${REUSE_URL:+ — this stacks on the still-open scout PR $REUSE_URL: its changes are already in the tree; extend its scout/last-report.md (new dated section on top) rather than replacing it}."
  echo "- Run marker: \`$MARKER\` — must appear in EVERY prompt you send to any model."
  echo "- Throwaway workdir root: \`$WORK_ROOT\` — make each workdir with \`w=\$(mktemp -d $WORK_ROOT/w.XXXXXX) && echo \"\$w\" >> $REGISTRY\`."
  echo "- Artifacts dir: \`$ARTIFACTS\` — write \`grok-research.md\`, \`second-review.md\` and \`status\` here."
  echo "- Env already exported for every command you run: MODEL_RUN_EPHEMERAL=1, ROUTECHECK_MARKER=$MARKER, MODEL_SCOUT_* (same values as above)."
  echo
  echo "### CLI versions now (bin/cli-fingerprint.sh --versions)"
  bash bin/cli-fingerprint.sh --versions 2>&1 | cut -f1,3 | fence
  echo
  echo "### CLI versions at the previous full routecheck (~/.claude/route-health-tools.txt)"
  cut -f1,3 "$LIVE_TOOLS" 2>/dev/null | fence
} >"$SIG"

# routecheck FIRST: its live codex call refreshes Codex's models cache, which
# catalog-drift reads. A routecheck that predates ROUTECHECK_MARKER support
# would leave an untagged haiku transcript behind — run only its free tiers.
RC_OUT="$ARTIFACTS/routecheck-pre.txt"
rc_args=()
case "$ROUTECHECK_MODE" in
  free) rc_args=(--no-live) ;;
  skip) ;;
  *) if ! grep -q ROUTECHECK_MARKER tests/routecheck.sh; then
       log "WARN: tests/routecheck.sh on this base doesn't honour ROUTECHECK_MARKER — free tiers only"
       rc_args=(--no-live)
     fi ;;
esac
if [ "$ROUTECHECK_MODE" = skip ]; then
  echo "(routecheck skipped: MODEL_SCOUT_ROUTECHECK=skip)" >"$RC_OUT"; RC_RC=skip
else
  log "routecheck ${rc_args[*]:-(live)}"
  timeout 2400 bash tests/routecheck.sh "${rc_args[@]}" >"$RC_OUT" 2>&1 9>&-
  RC_RC=$?
fi
log "routecheck exit $RC_RC"; sed 's/^/  /' "$RC_OUT"
if [ "$BASE" = origin/master ] && [ -s "$ROUTE_HEALTH_FILE" ]; then
  cp -f "$ROUTE_HEALTH_FILE" "$LIVE_HEALTH" && cp -f "$ROUTE_HEALTH_TOOLS" "$LIVE_TOOLS" &&
    log "published the live routecheck verdict to $LIVE_HEALTH (tree = origin/master, unmodified)"
fi

# The latest LIVE routecheck on this tree (the pre-run one, or the agent's
# re-run after its edits) still failing is actionable even on a no-change run —
# e.g. codex auth lapsed and the agent, rightly, changed nothing.
check_route_health() {
  [ -s "$ROUTE_HEALTH_FILE" ] || return 0
  grep -qE '^[0-9-]+ ok' "$ROUTE_HEALTH_FILE" && return 0
  local auth=""
  grep -qsF 'AUTH/QUOTA' "$RC_OUT" "$WORK_ROOT"/*/routecheck.txt && auth=" (AUTH/QUOTA errors: codex login / cursor-agent login)"
  DEGRADED+=("live routecheck still FAILS: $(cut -d' ' -f3- "$ROUTE_HEALTH_FILE" | head -c 200)$auth")
}

DRIFT_OUT=$(timeout 180 bash bin/catalog-drift.sh 2>&1); DRIFT_RC=$?
# --unrouted prints ids on stdout and stale/unavailable notes on stderr; keep
# them apart or a note line is counted (and pasted to grok) as an "id".
UNR_OUT=$(timeout 180 bash bin/catalog-drift.sh --unrouted 2>"$ARTIFACTS/unrouted.err"); UNR_RC=$?
# --unrouted: 0 = none, 1 = some; anything else (e.g. 64 on an old catalog-drift)
# means the listing itself is unavailable — don't count its error text as ids.
UNR_N=$(printf '%s\n' "$UNR_OUT" | grep -c .)
case "$UNR_RC" in 0|1) ;; *) UNR_N="?" ;; esac
log "catalog-drift exit $DRIFT_RC; --unrouted exit $UNR_RC ($UNR_N unrouted)"
[ -n "$DRIFT_OUT" ] && printf '%s\n' "$DRIFT_OUT" | sed 's/^/  drift: /'
{
  echo
  echo "### tests/routecheck.sh ${rc_args[*]:-(live)} — exit $RC_RC (full output: \`$RC_OUT\`)"
  { grep -E '^(FAIL|WARN) ' "$RC_OUT"; tail -n 8 "$RC_OUT"; } | fence
  echo
  echo "### bin/catalog-drift.sh (live) — exit $DRIFT_RC"
  printf '%s\n' "${DRIFT_OUT:-(no drift)}" | fence
  echo
  echo "### bin/catalog-drift.sh --unrouted — exit $UNR_RC (catalog ids that are neither routed, retired, nor ignored)"
  printf '%s\n' "${UNR_OUT:-(none)}" | fence
  if [ -s "$ARTIFACTS/unrouted.err" ]; then
    echo
    echo "catalog-drift --unrouted notes (stale/unavailable catalogs — NOT ids):"
    fence <"$ARTIFACTS/unrouted.err"
  fi
} >>"$SIG"

if [ "$DRY_RUN" -eq 1 ]; then
  section "dry run"
  log "--dry-run: skipping the agentic step, commit and push. Signals:"
  sed 's/^/  | /' "$SIG"
  STATUS=no-change
  SUMMARY="dry run: routecheck exit $RC_RC, catalog-drift exit $DRIFT_RC, $UNR_N unrouted id(s)"
  check_route_health
  exit 0
fi

# ---------- agentic step ----------
section "agent ($AGENT_MODEL, effort $AGENT_EFFORT, timeout ${TIMEOUT}s)"
# The prompt comes from the base (so a merged prompt change takes effect next
# run); MODEL_SCOUT_PROMPT overrides it for testing an unmerged prompt.
SCOUT_PROMPT="${MODEL_SCOUT_PROMPT:-$WT/scout/prompt.md}"
[ -s "$SCOUT_PROMPT" ] || fail "scout prompt missing: $SCOUT_PROMPT"
PROMPT="$ARTIFACTS/prompt.md"
{ cat "$SCOUT_PROMPT"; echo; cat "$SIG"; } >"$PROMPT"
AGENT_JSON="$ARTIFACTS/agent.json"
agent_args=(-p --no-session-persistence --model "$AGENT_MODEL" --effort "$AGENT_EFFORT"
            --permission-mode bypassPermissions --output-format json)
[ -n "${MODEL_SCOUT_BUDGET_USD:-}" ] && agent_args+=(--max-budget-usd "$MODEL_SCOUT_BUDGET_USD")
# bypassPermissions + live SSH/gh credentials: the prompt's "never commit /
# push / open a PR / run install.sh" must not be the only thing holding —
# the global CLAUDE.md the session also loads says the opposite. Deny rules
# still apply in bypass mode (review finding 2026-09-22). Variadic flag: keep LAST.
agent_args+=(--disallowedTools 'Bash(git push*)' 'Bash(git * push*)' 'Bash(git commit*)' 'Bash(git * commit*)'
             'Bash(gh pr create*)' 'Bash(gh pr merge*)' 'Bash(gh pr edit*)' 'Bash(gh pr close*)'
             'Bash(gh pr comment*)' 'Bash(gh pr review*)' 'Bash(crontab*)' 'Bash(*install.sh*)')
# Belt and braces for git itself, in the agent's environment only: commit and
# push hooks that refuse, and an unusable push URL for origin.
AGENT_HOOKS="$SCRATCH/agent-git-hooks"; mkdir -p "$AGENT_HOOKS"
for h in pre-commit pre-push; do
  printf '#!/bin/sh\necho "model-scout: %s is the wrapper'"'"'s job, not the agent'"'"'s" >&2\nexit 1\n' "$h" >"$AGENT_HOOKS/$h"
  chmod +x "$AGENT_HOOKS/$h"
done
# BASH_MAX_TIMEOUT_MS: the Bash tool caps a command at 10 min by default — the
# same as model-run's own 600s timeout, so a slow grok / astra call was killed
# by the tool before model-run could report exit 124 (review finding 2026-09-22).
timeout --kill-after=60 "$TIMEOUT" env BASH_MAX_TIMEOUT_MS=1800000 \
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$AGENT_HOOKS" \
  GIT_CONFIG_KEY_1=remote.origin.pushurl GIT_CONFIG_VALUE_1=/dev/null/model-scout-agent-may-not-push \
  claude "${agent_args[@]}" <"$PROMPT" >"$AGENT_JSON" 2>"$ARTIFACTS/agent.stderr" 9>&-
AGENT_RC=$?
sed 's/^/  stderr: /' "$ARTIFACTS/agent.stderr"
# Pull result / cost / model out of the single JSON result object.
eval "$(python3 - "$AGENT_JSON" <<'PY'
import json, re, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
usage = d.get("modelUsage") or {}
top = max(usage, key=lambda k: usage[k].get("costUSD", 0), default="")
m = re.match(r"claude-([a-z]+)-(\d+(?:-\d{1,2})*)", top)
pretty = ("Claude %s %s" % (m.group(1).capitalize(), m.group(2).replace("-", "."))) if m else "Claude"
for k, v in {"A_ERR": str(bool(d.get("is_error", not d))).lower(), "A_SUBTYPE": d.get("subtype", "none"),
             "A_RESULT": (d.get("result") or "")[-2000:], "A_COST": "%.2f" % (d.get("total_cost_usd") or 0),
             "A_TURNS": str(d.get("num_turns", 0)), "A_MODEL": top or "unknown", "A_PRETTY": pretty}.items():
    print("%s=%s" % (k, shlex.quote(v)))
PY
)"
log "agent exit $AGENT_RC, subtype $A_SUBTYPE, error $A_ERR, turns $A_TURNS, \$$A_COST, model $A_MODEL"
printf '%s\n' "$A_RESULT" | sed 's/^/  agent: /'

AUTH_RE='authentication|not logged in|/login|invalid api key|credit balance|usage limit|rate limit|quota|oauth'
if [ "$AGENT_RC" -eq 124 ] || [ "$AGENT_RC" -eq 137 ]; then
  fail "agent timed out after ${TIMEOUT}s (any partial diff is in logs/$DATE.patch)"
fi
if [ "$A_ERR" = true ] || [ "$AGENT_RC" -ne 0 ]; then
  if printf '%s\n%s' "$A_RESULT" "$(cat "$ARTIFACTS/agent.stderr")" | grep -qiE "$AUTH_RE"; then
    fail "claude auth/quota error — headless scout could not run: $(printf '%s' "$A_RESULT" | head -c 200)"
  fi
  fail "agent failed (exit $AGENT_RC, $A_SUBTYPE): $(printf '%s' "$A_RESULT" | head -c 200)"
fi

AGENT_STATUS=$(head -n1 "$ARTIFACTS/status" 2>/dev/null | tr -d '\r')
log "agent status: ${AGENT_STATUS:-<none>}"
[ -n "$AGENT_STATUS" ] || fail "agent finished without writing $ARTIFACTS/status (any partial diff is in logs/$DATE.patch)"
BLOCKED=""
case "$AGENT_STATUS" in
  ok*) ;;
  blocked*) BLOCKED="${AGENT_STATUS#blocked}"; BLOCKED="${BLOCKED# }" ;;
  *) fail "agent wrote an unrecognised status line: $AGENT_STATUS" ;;
esac
# The grok recency pass is mandatory — no grok output means the research
# never cross-checked X/web in real time; don't let a skipped step pass as "ok".
# The file must be real model-run --task-type recency output (its stderr
# `-> grok-` line), and not a failed call the agent copied and then ignored.
GROK="$ARTIFACTS/grok-research.md"
if [ -z "$BLOCKED" ]; then
  if [ ! -s "$GROK" ]; then
    BLOCKED="agent skipped the mandatory grok recency pass (no grok-research.md)"
  elif g_err=$(grep -m1 -oE '^model-run: (AUTH/QUOTA ERROR|TRANSPORT ERROR|TIMEOUT)' "$GROK"); then
    BLOCKED="grok recency pass failed (${g_err#model-run: }) but the agent reported ok"
  elif ! grep -qE '^model-run: --task-type recency -> grok-' "$GROK"; then
    BLOCKED="grok-research.md is not bin/model-run.sh --task-type recency output"
  fi
fi
# Web + X search is the point of the grok pass: the prompt makes grok end with
# a `SEARCH-TOOLS-USED: web=<yes|no> x=<yes|no>` line. A pass without X (or
# without the line) still yields verified edits — publish them — but the run
# is recorded failed so the gap is visible, never silently accepted.
if [ -z "$BLOCKED" ]; then
  prov=$(grep -E 'SEARCH-TOOLS-USED' "$GROK" | tail -1)
  case "$prov" in
    "") DEGRADED+=("grok gave no SEARCH-TOOLS-USED line — its web/X search is unverified") ;;
    *) printf '%s' "$prov" | grep -qiE 'x *= *yes' || DEGRADED+=("grok reported no X search ($(printf '%s' "$prov" | tr -d '*`' | head -c 80))")
       printf '%s' "$prov" | grep -qiE 'web *= *yes' || DEGRADED+=("grok reported no web search") ;;
  esac
fi
check_route_health
AGENT_SUMMARY="${AGENT_STATUS#ok}"; AGENT_SUMMARY="${AGENT_SUMMARY#blocked}"; AGENT_SUMMARY="${AGENT_SUMMARY# }"

# ---------- gate ----------
section "gate"
[ -f scout/last-report.md ] && cp scout/last-report.md "$LOGDIR/$DATE.report.md"
# Only routing-layer files may change. Anything else (install.sh, settings,
# this script, the cleanup scripts, the scout prompt, skills) is reverted:
# those are reviewed by hand, never rewritten by the daily job.
ALLOW='^(bin/(routes\.tsv|model-run\.sh|catalog-drift\.sh|cli-fingerprint\.sh)|tests/routecheck\.sh|tests/workflows/[^/]+\.js|hooks/route-guard\.sh|hooks/route-health-banner\.sh|agents/model-runner\.md|model-selection\.md|model-usage\.md|README\.md|system-map\.md|scout/(evaluated\.tsv|last-report\.md))$'
git add -A
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! printf '%s\n' "$f" | grep -qE "$ALLOW"; then
    log "REVERTED out-of-scope change: $f"
    git reset -q -- "$f"
    if git cat-file -e "HEAD:$f" 2>/dev/null; then git checkout -q HEAD -- "$f"; else rm -rf -- "$f"; fi
  fi
done < <(git diff --cached --name-only)
git add -A
MEANINGFUL=$(git diff --cached --name-only | grep -vxF scout/last-report.md)
if [ -z "$MEANINGFUL" ]; then
  git reset -q; git checkout -q -- . 2>/dev/null
  if [ -n "$BLOCKED" ]; then
    STATUS=failed; SUMMARY="BLOCKED: $BLOCKED"
  else
    STATUS=no-change; SUMMARY="no routing change${AGENT_SUMMARY:+: $AGENT_SUMMARY}"
  fi
  exit 0
fi
log "changed files:"; git diff --cached --stat | sed 's/^/  /'
for f in $(git diff --cached --name-only --diff-filter=d -- '*.sh'); do
  bash -n "$f" || fail "syntax error in $f after agent edits"
done
[ -s scout/last-report.md ] || fail "agent changed files but wrote no scout/last-report.md"
timeout 600 bash tests/routecheck.sh --no-live >"$ARTIFACTS/routecheck-gate.txt" 2>&1 9>&-
GATE_RC=$?
grep -E '^FAIL ' "$ARTIFACTS/routecheck-gate.txt" | sed 's/^/  /'
[ "$GATE_RC" -eq 0 ] || fail "routecheck --no-live fails on the agent's diff (exit $GATE_RC) — not publishing"
[ -s "$ARTIFACTS/second-review.md" ] || AGENT_SUMMARY="${AGENT_SUMMARY:+$AGENT_SUMMARY; }NO second review"

# ---------- commit ----------
section "commit"
git add -A
subject="Model scout $DATE: ${AGENT_SUMMARY:-routing update}"
[ -n "$BLOCKED" ] && subject="Model scout $DATE (partial, blocked): ${AGENT_SUMMARY:-see report}"
subject=$(printf '%s' "$subject" | head -c 100)
git -c user.useConfigOnly=true commit -q -F - <<EOF || fail "git commit failed"
$subject

Automated daily model-routing maintenance (bin/model-scout.sh, run marker
$MARKER). Evidence, sources and the second review are in
scout/last-report.md.${BLOCKED:+

BLOCKED: $BLOCKED}

Co-Authored-By: $A_PRETTY <noreply@anthropic.com>
EOF
COMMIT=$(git rev-parse HEAD)
log "committed ${COMMIT:0:12}: $subject"

# ---------- publish ----------
new_branch_name() {
  local b="claude/model-scout-$DATE"
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$b" ||
     git -C "$REPO" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
    b="$b-$(date +%H%M%S)"
  fi
  echo "$b"
}
if [ "$NO_PR" -eq 1 ]; then
  BRANCH=$(new_branch_name)
  git -C "$REPO" branch "$BRANCH" "$COMMIT" || fail "could not create local branch $BRANCH"
  log "--no-pr: committed locally on $BRANCH"
  STATUS=no-change; [ -n "$BLOCKED" ] && STATUS=failed
  SUMMARY="${BLOCKED:+BLOCKED: $BLOCKED; }committed locally on $BRANCH (--no-pr): $AGENT_SUMMARY"
  exit 0
fi

keep_local() {  # keep_local <why>: park today's commit on a local branch, then fail
  local b; b=$(new_branch_name)
  git -C "$REPO" branch -f "$b" "$COMMIT" >/dev/null 2>&1 && BRANCH="$b"
  fail "$1 — NOT published; today's commit ${COMMIT:0:12} kept on local branch ${BRANCH:-?}"
}
BRANCH="${REUSE_BRANCH:-$(new_branch_name)}"
if [ -n "$REUSE_BRANCH" ]; then
  # The user merges quickly: a push to a just-merged branch is silently
  # orphaned. Today's commit sits ON the old scout branch, so only a MERGED PR
  # may be "branched afresh" — by replaying the commit onto origin/master (a
  # plain new branch would re-propose everything if it was squash-merged). A
  # CLOSED-unmerged PR was rejected: a new PR from this commit would bring the
  # rejected changes back. An unknown state (gh failed) proves nothing.
  state=$(cd "$REPO" && timeout 60 gh pr view "$REUSE_URL" --json state -q .state 2>/dev/null) || state=""
  case "$state" in
    OPEN) ;;
    MERGED)
      log "scout PR $REUSE_URL was merged during the run — replaying ${COMMIT:0:12} onto origin/master"
      OPEN_PR_URL=""
      timeout 120 git fetch --quiet origin master || keep_local "git fetch origin master failed after $REUSE_URL merged"
      if git checkout -q --detach origin/master && git -c user.useConfigOnly=true cherry-pick "$COMMIT" >/dev/null 2>&1; then
        COMMIT=$(git rev-parse HEAD)
        REUSE_BRANCH=""; REUSE_URL=""; BRANCH=$(new_branch_name)
      else
        git cherry-pick --abort >/dev/null 2>&1
        keep_local "scout PR $REUSE_URL merged mid-run and today's commit does not replay cleanly onto origin/master"
      fi ;;
    CLOSED) OPEN_PR_URL=""; keep_local "scout PR $REUSE_URL was closed unmerged during the run (today's commit is stacked on its rejected changes)" ;;
    *) keep_local "could not re-check scout PR $REUSE_URL before pushing (gh pr view failed)" ;;
  esac
fi
if ! timeout 180 git push --quiet origin "HEAD:refs/heads/$BRANCH"; then
  # SSH may be unavailable under cron — retry over HTTPS with gh's credentials.
  slug=$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
  [ -n "$slug" ] && timeout 180 git -c credential.helper= -c credential.helper='!gh auth git-credential' \
    push --quiet "https://github.com/$slug.git" "HEAD:refs/heads/$BRANCH" ||
    { git -C "$REPO" branch -f "$BRANCH" "$COMMIT" >/dev/null 2>&1
      fail "git push of $BRANCH failed (commit ${COMMIT:0:12} kept on local branch $BRANCH)"; }
fi
log "pushed $BRANCH"

BODY="$ARTIFACTS/pr-body.md"
{ cat scout/last-report.md; echo; echo "---"; echo "Run marker \`$MARKER\` · log \`$LOG\` · agent $A_MODEL, $A_TURNS turns, \$$A_COST"; echo
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"; } >"$BODY"
if [ -n "$REUSE_BRANCH" ]; then
  (cd "$REPO" && timeout 60 gh pr edit "$REUSE_BRANCH" --body-file "$BODY" >/dev/null) || log "WARN: gh pr edit failed"
  PR_URL="$REUSE_URL"
else
  PR_URL=$(cd "$REPO" && timeout 60 gh pr create --base master --head "$BRANCH" \
    --title "$subject" --body-file "$BODY" 2>&1 | grep -Eo 'https://github\.com/[^ ]+/pull/[0-9]+' | tail -1)
  [ -n "$PR_URL" ] || fail "branch $BRANCH pushed but gh pr create failed"
fi
OPEN_PR_URL="$PR_URL"
log "PR: $PR_URL"
if [ -n "$BLOCKED" ]; then
  STATUS=failed; SUMMARY="BLOCKED: $BLOCKED — partial changes in $PR_URL"
else
  STATUS="pr"; SUMMARY="$AGENT_SUMMARY"
fi
exit 0
