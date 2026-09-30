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
#   --base <ref>  base the scout worktree on <ref> (default: a fresh origin/master);
#                 older open scout PRs are left alone, and none is opened next to one
#   --no-pr       commit on a local branch only (printed); never push, open, merge
#                 or close a PR (older scout PRs are only evaluated, logged)
#   --repo <dir>  repo to work from (default ~/dotfiles/claude)
#   --dry-run     run the zero-token pre-steps + cleanup only; skip the agentic
#                 step, commit, push and every PR write
#
# Routing updates 100% automatically: the PR is the audit trail, and the scout
# merges it itself when every gate passes (the one sanctioned exception to
# CLAUDE.md's "a human merges PRs"; it still never pushes to master directly).
#
# One run:
#  1. flock single-instance; log to ~/.claude/model-scout/logs/<YYYY-MM-DD>.log
#     (30 days kept, plus <date>.report.md / .grok.md / .grok-fallback.md /
#     .review.md / .patch).
#  2. Older open claude/model-scout-* PRs (never stacked on any more): each is
#     merged if GitHub says MERGEABLE, its tree passes `routecheck --no-live`
#     and its diff passes the path gate (below, without the CLI-repair
#     allowance); otherwise it is closed with a "superseded" comment (branch
#     kept, so it can be reopened by hand). Then a fresh origin/master is fetched.
#  3. A throwaway git worktree of --repo in ~/.cache/model-scout/wt-<date>,
#     detached at origin/master — the live checkout is only touched in step 8.
#  4. Deterministic pre-steps (zero model tokens except routecheck's ~100/route),
#     captured as "signals": CLI versions (cli-fingerprint.sh), tests/routecheck.sh,
#     catalog-drift.sh live + --unrouted. A pre-run live routecheck that fails
#     on something other than the xai key marks the run a CLI-break REPAIR.
#  5. Agentic step: headless `claude -p --no-session-persistence` (opus, high
#     effort, bypassPermissions — unattended, confined to the worktree by the
#     prompt AND by --disallowedTools deny rules + refusing git commit/push
#     hooks: no commit, push, gh pr write, crontab or install.sh) running
#     scout/prompt.md + the signals, hard timeout
#     MODEL_SCOUT_TIMEOUT (5400s). It researches (grok FIRST via
#     `--task-type x-recency` = the direct xAI API with real web + X search,
#     then Claude WebSearch, then the live catalogs), edits the routing
#     table/docs, re-runs routecheck, gets a gpt-6-astra second review and
#     writes scout/last-report.md. It must write a status line and the grok
#     output to files this script checks. The gate is MEASURED, not
#     self-reported: model-run's `xai-tools x_search=<n>` line. x-recency ok
#     with >=1 x_search call = full research. x-recency failed (exit 75/73/124,
#     or 0 x_search calls) = the agent must fall back to `--task-type recency`
#     (cursor grok, web only) and announce it in the report; the run is then
#     recorded DEGRADED (a 75 is named, e.g. "XAI_API_KEY rejected"). No grok
#     output, output that isn't model-run's, or both passes failing = BLOCKED
#     (failed). Every routecheck in the run writes its verdict to the artifacts
#     dir (ROUTE_HEALTH_FILE/_TOOLS), never the live banner's files, except the
#     pre-run one on an unmodified origin/master and the final one of a tree
#     that was merged and pulled into the live checkout.
#  6. Commit gate: only files on an allowlist may change (anything else is
#     reverted and logged); `routecheck --no-live` must pass (xai key/credit
#     failures only WARN there: ROUTECHECK_XAI_SOFT=1); commit, push
#     claude/model-scout-<date>, `gh pr create` against master with
#     scout/last-report.md as the body.
#  7. Auto-merge gates — ALL must hold, else the PR stays open
#     ("pr-needs-review", with the reason): not BLOCKED; a second review exists;
#     a wrapper-run FINAL live routecheck of the committed tree passes (only
#     xai-key failures tolerated = degraded); `routecheck --no-live` passed;
#     the PR diff touches only routing data (AUTOMERGE_PATHS: routes.tsv, the
#     routing docs, README/system-map, scout/*, the workflow smokes' id lists;
#     hooks/route-guard.sh only inside the RETIRED dict; tests/routecheck.sh
#     only inside its Tier 0.5 mock section, keeping every check; bin/model-run.sh
#     and the rest of routecheck.sh only on a CLI-break repair). Then
#     `gh pr merge --squash --delete-branch --match-head-commit`. Not mergeable
#     because master moved: rebase onto origin/master ONCE, re-run
#     `routecheck --no-live` + the path gate, push --force-with-lease, retry; a
#     conflict leaves the PR open. A degraded run (no X search) still merges.
#  8. After any merge (step 2 or 7): refresh the LIVE checkout
#     (MODEL_SCOUT_LIVE_REPO, ~/dotfiles/claude), whose bin/routes.tsv is read
#     in place. On master: fetch + `merge --ff-only` (= pull --ff-only; dirty
#     files the merge doesn't touch are fine, anything else is left alone —
#     never forced), then `install.sh --cron-only`. On any other branch (or a
#     failed ff): nothing is touched; last-run.json records
#     live_checkout_behind=<branch> and the banner says routing on disk lags.
#  9. ALWAYS (EXIT trap): retry any queued failed cleanups, then
#     bin/test-chat-cleanup.sh for this run's marker + workdirs and
#     bin/t3-purge-test-threads.sh --apply (a failure is queued in
#     ~/.claude/model-scout/pending-cleanup.tsv and marks the run failed),
#     step 8, remove the worktree and temp dirs, then write last-run.json.
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
#   {date, status: "no-change"|"merged"|"pr-needs-review"|"local-commit"|
#    "degraded"|"failed", pr_url, summary, needs_review, degraded, log,
#    finished_at, started_at, last_success, last_x_success, marker, branch,
#    cleanup, open_pr, needs_dan, live_checkout_behind, live_checkout_note,
#    live_target}
# needs_dan = the agent's "Needs Dan" items (artifacts/needs-dan): an auto-merged
# PR's report has no reader, so the banner prints them.
# "merged" = today's PR was auto-merged (pr_url); `degraded` then names why the
# research had no X search (the banner prints one quiet line). "pr-needs-review"
# = today's PR is open, `needs_review` says which gate stopped the merge.
# open_pr = a scout PR still open after this run (the next run merges/closes it).
# live_checkout_behind = the live checkout's branch when it could not be
# fast-forwarded to the merged master (live_target); the banner re-checks.
# "local-commit" = --no-pr (explicit, or forced by --base next to an open scout
# PR) and the agent produced a commit: it sits on the local branch `branch`,
# unpublished.
# "degraded" = a no-change / local-commit run whose research had no X search
# (x-recency failed; the cursor-grok web-only fallback ran), or whose live
# routecheck fails ONLY the xai route (auth:xai / its smoke: a rejected,
# out-of-credit or rate-limited XAI_API_KEY) — the summary says why. "failed"
# also covers runs that worked but left something actionable (cleanup
# incomplete, any other live routecheck failure); it wins over everything
# (a merge that already happened is still in pr_url / the summary).
# last_success follows the research outcome, not those; last_x_success advances
# only on a measured X search (it sets the next x-recency from_date, so a
# degraded run's gap is searched later, ≤30 days).
# Exit: 0 no-change / merged / pr-needs-review / local-commit / degraded / dry-run
# · 1 failed · 0 (silently) when another run holds the lock. Auth/quota errors
# (model-run exit 75, claude login/usage limits) fail loudly into last-run.json
# — never substituted.
#
# Env: MODEL_SCOUT_HOME (~/.claude/model-scout) · MODEL_SCOUT_CACHE
# (~/.cache/model-scout) · MODEL_SCOUT_TIMEOUT (5400) · MODEL_SCOUT_MODEL (opus)
# · MODEL_SCOUT_EFFORT (high) · MODEL_SCOUT_ROUTECHECK=live|free|skip (live;
# free = `--no-live`; anything but live means no final live check = no
# auto-merge) · MODEL_SCOUT_BUDGET_USD (unset = no --max-budget-usd cap)
# · MODEL_SCOUT_PROMPT (default: the base's scout/prompt.md) ·
# MODEL_SCOUT_LIVE_REPO (~/dotfiles/claude: the checkout refreshed after a
# merge) · MODEL_SCOUT_GH_POLL (5: seconds between mergeability polls).
# MODEL_SCOUT_LIB=1 (tests only): define the functions and return — nothing runs.
set -u

# ---------- helpers (defined first so tests can source them: MODEL_SCOUT_LIB=1) ----------
log() { echo "[$(date +%T)] $*"; }
section() { echo; echo "===== $* ====="; }

# Paths an auto-merged scout PR may touch freely: routing DATA — the table, the
# docs that describe it, the scout's own log/report, the workflow smokes' id
# lists. Three more are allowed in part (path_gate): hooks/route-guard.sh inside
# its RETIRED dict; tests/routecheck.sh inside its Tier 0.5 mock section (the
# catalog fixture every route change must update) with no check dropped; and on
# a CLI-break repair, bin/model-run.sh + all of tests/routecheck.sh. Anything
# else the commit gate lets through (catalog-drift.sh, cli-fingerprint.sh, the
# banner) waits for a human.
AUTOMERGE_PATHS='^(bin/routes\.tsv|model-selection\.md|model-usage\.md|agents/model-runner\.md|README\.md|system-map\.md|scout/(evaluated\.tsv|last-report\.md)|tests/workflows/[^/]+\.js)$'

# region_only_changed <gitdir> <old-rev> <new-rev> <path> <label> <start-re> <end-re> [keep-checks]
# 0 iff <path> differs between the two revs only inside the region running from
# the first line matching <start-re> to the next line matching <end-re>
# (inclusive, Python regexes). keep-checks: every `ok "<name>"` check in the old
# region must survive in the new one. Prints the reason on failure.
region_only_changed() {
  local dir=$1 old=$2 new=$3 path=$4 label=$5 a b rc
  a=$(mktemp) b=$(mktemp)
  git -C "$dir" show "$old:$path" >"$a" 2>/dev/null
  git -C "$dir" show "$new:$path" >"$b" 2>/dev/null
  python3 - "$6" "$7" "${8:-}" "$a" "$b" "$label" <<'PY'
import re, sys
start, end, keep, fa, fb, label = sys.argv[1:7]
def split(text):
    lines = text.split("\n")
    s = next((i for i, l in enumerate(lines) if re.search(start, l)), None)
    if s is None:
        return None
    e = next((i for i in range(s, len(lines)) if re.search(end, lines[i])), None)
    if e is None:
        return None
    return lines[:s] + lines[e + 1:], "\n".join(lines[s:e + 1])
old, new = split(open(fa).read()), split(open(fb).read())
if old is None or new is None:
    print(f"{label} not found"); sys.exit(1)
if old[0] != new[0]:
    print(f"changed outside {label}"); sys.exit(1)
if keep:
    checks = lambda t: set(re.findall(r'\bok "([^"$]+)"', t))
    gone = checks(old[1]) - checks(new[1])
    if gone:
        print(f"drops check(s) in {label}: " + ", ".join(sorted(gone))); sys.exit(1)
PY
  rc=$?; rm -f "$a" "$b"; return $rc
}

# path_gate <gitdir> <base> <head> <cli-repair 0|1>: 0 iff the PR diff
# (merge-base(base, head) -> head, what GitHub shows) touches routing data only.
# Otherwise PATH_WHY says what (and the PR waits for a human).
path_gate() {
  local dir=$1 base=$2 head=$3 repair=${4:-0} mb files f why bad=()
  PATH_WHY=""
  mb=$(git -C "$dir" merge-base "$base" "$head" 2>/dev/null) &&
    files=$(git -C "$dir" diff --name-only "$mb" "$head") ||
    { PATH_WHY="path gate: cannot diff $base...$head"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ "$f" =~ $AUTOMERGE_PATHS ]] && continue
    case "$f" in
      hooks/route-guard.sh)
        why=$(region_only_changed "$dir" "$mb" "$head" "$f" "the RETIRED dict" '^RETIRED = \{' '\}\s*$') && continue
        bad+=("$f ($why)") ;;
      tests/routecheck.sh)
        [ "$repair" = 1 ] && continue
        why=$(region_only_changed "$dir" "$mb" "$head" "$f" "the Tier 0.5 mock section" '^# -+ Tier 0\.5:' '^# -+ Tier 1:' keep) && continue
        bad+=("$f ($why; not a CLI-break repair)") ;;
      bin/model-run.sh)
        [ "$repair" = 1 ] && continue
        bad+=("$f (not a CLI-break repair)") ;;
      *) bad+=("$f") ;;
    esac
  done <<<"$files"
  [ "${#bad[@]}" -eq 0 ] && return 0
  PATH_WHY="touches more than routing data: $(printf '%s; ' "${bad[@]}" | sed 's/; $//')"
  return 1
}

# remote_git <dir> <fetch|push> [option...] -- <refspec...>: via origin first;
# if that fails (cron often has no SSH agent), over HTTPS with gh's credentials.
remote_git() {
  local dir=$1 op=$2 opts=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  timeout 180 git -C "$dir" "$op" --quiet "${opts[@]}" origin "$@" && return 0
  [ -n "${SLUG:-}" ] || return 1
  log "git $op via origin failed — retrying over HTTPS with gh's credentials"
  timeout 180 git -C "$dir" -c credential.helper= -c credential.helper='!gh auth git-credential' \
    "$op" --quiet "${opts[@]}" "https://github.com/$SLUG.git" "$@"
}

# gh against the repo by slug, from a non-repo dir: `gh pr merge --delete-branch`
# run inside a checkout also deletes/switches LOCAL branches — never wanted here.
ghr() { (cd "${SCRATCH:-/}" && timeout 120 gh "$@" -R "$SLUG"); }

# pr_mergeable <url>: sets PM_MERGEABLE (MERGEABLE|CONFLICTING|UNKNOWN),
# PM_STATE (mergeStateStatus), PM_OID (head sha), PM_PRSTATE (OPEN|MERGED|CLOSED).
# Polls while GitHub is still computing; 1 = no definite answer.
pr_mergeable() {
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    out=$(ghr pr view "$1" --json mergeable,mergeStateStatus,headRefOid,state \
      -q '[.mergeable,.mergeStateStatus,.headRefOid,.state]|@tsv' 2>>"${ARTIFACTS:-/tmp}/gh.err") || out=""
    PM_MERGEABLE="" PM_STATE="" PM_OID="" PM_PRSTATE=""
    IFS=$'\t' read -r PM_MERGEABLE PM_STATE PM_OID PM_PRSTATE <<<"$out"
    PM_MERGEABLE=${PM_MERGEABLE:-UNKNOWN} PM_STATE=${PM_STATE:-UNKNOWN}
    [ -n "$PM_PRSTATE" ] && [ "$PM_PRSTATE" != OPEN ] && return 0
    [ "$PM_MERGEABLE" != UNKNOWN ] && return 0
    [ "$i" -lt 12 ] && sleep "${MODEL_SCOUT_GH_POLL:-5}"
  done
  return 1
}
pr_is_mergeable() {  # after pr_mergeable: GitHub would merge it as-is
  [ "$PM_PRSTATE" = OPEN ] && [ "$PM_MERGEABLE" = MERGEABLE ] &&
    case "$PM_STATE" in BEHIND|DIRTY|DRAFT) false ;; *) true ;; esac
}

# gh_merge <url> <head-sha>: squash-merge + delete the branch, only if the head
# is still exactly what the gates checked. 0 only once GitHub says MERGED.
gh_merge() {
  local out rc state
  out=$(ghr pr merge "$1" --squash --delete-branch --match-head-commit "$2" 2>&1); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  gh: /'
  state=$(ghr pr view "$1" --json state -q .state 2>/dev/null)
  [ "$state" = MERGED ] && return 0
  GH_MERGE_WHY="gh pr merge exit $rc, PR state ${state:-unknown}: $(printf '%s' "$out" | tr '\n' ' ' | head -c 160)"
  return 1
}

# tree_nolive_ok <gitdir> <rev>: `routecheck --no-live` on <rev>'s tree, in a
# throwaway worktree (xai key failures only WARN, as at the commit gate).
tree_nolive_ok() {
  local dir=$1 rev=$2 wt="$SCRATCH/pr-check-wt" out="$SCRATCH/pr-check-rc.txt" rc
  NOLIVE_WHY=""
  git -C "$dir" worktree add --quiet --detach "$wt" "$rev" >/dev/null 2>&1 ||
    { NOLIVE_WHY="could not check out $rev to run routecheck"; return 1; }
  (cd "$wt" && ROUTE_HEALTH_FILE="$SCRATCH/pr-check-health.txt" ROUTE_HEALTH_TOOLS="$SCRATCH/pr-check-tools.txt" \
    ROUTECHECK_XAI_SOFT=1 timeout 600 bash tests/routecheck.sh --no-live >"$out" 2>&1 9>&-); rc=$?
  git -C "$dir" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$dir" worktree prune >/dev/null 2>&1
  [ "$rc" -eq 0 ] && return 0
  NOLIVE_WHY="routecheck --no-live fails on its tree (exit $rc: $(grep -E '^FAIL ' "$out" | head -3 | cut -c7- | tr '\n' ' ' | head -c 200))"
  return 1
}

# handle_stale_prs <act 0|1>: every OPEN_PRS entry ("branch<TAB>url") is merged
# if GitHub says MERGEABLE, its tree passes routecheck --no-live and its diff
# passes the path gate (no CLI-repair allowance: that was judged against an
# older master — today's run re-derives it); otherwise closed as superseded
# (branch kept). act=0 only logs what it would do. Sets MERGED_ANY,
# STALE_NOTES, OPEN_PR_URL (a PR still open afterwards).
handle_stale_prs() {
  local act=$1 line b url why body
  for line in "${OPEN_PRS[@]}"; do
    IFS=$'\t' read -r b url <<<"$line"
    why=""
    log "older scout PR $url ($b)"
    if ! remote_git "$REPO" fetch -- "+refs/heads/$b:refs/remotes/origin/$b" "+refs/heads/master:refs/remotes/origin/master"; then
      why="could not fetch $b"
    elif ! pr_mergeable "$url"; then
      why="GitHub did not report its mergeability"
    elif [ "$PM_PRSTATE" != OPEN ]; then
      log "  already ${PM_PRSTATE:-gone} — nothing to do"; continue
    elif ! pr_is_mergeable; then
      why="not mergeable (mergeable=$PM_MERGEABLE, mergeStateStatus=$PM_STATE)"
    elif body=$(ghr pr view "$url" --json body -q .body 2>/dev/null) &&
         grep -qF '<!-- model-scout-automerge: no -->' <<<"$body"; then
      # Its own run left it for a human (live routecheck, path gate, BLOCKED…):
      # merging it now would skip exactly the check that stopped it.
      why="its run left it for human review ($(sed -n 's/.*NOT auto-merged — //p' <<<"$body" | head -1 | head -c 200)) and nobody merged it"
    elif [ "$(git -C "$REPO" rev-parse "origin/$b")" != "$PM_OID" ]; then
      why="its head changed while it was being checked"
    elif ! tree_nolive_ok "$REPO" "$PM_OID"; then
      why="$NOLIVE_WHY"
    elif ! path_gate "$REPO" origin/master "$PM_OID" 0; then
      why="$PATH_WHY"
    fi
    if [ -z "$why" ]; then
      if [ "$act" != 1 ]; then log "  gates pass — would merge it (no PR writes in this mode)"; OPEN_PR_URL="$url"; continue; fi
      if gh_merge "$url" "$PM_OID"; then
        MERGED_ANY=1; STALE_NOTES+=("merged older scout PR $url"); log "  merged"; continue
      fi
      why="$GH_MERGE_WHY"
    fi
    if [ "$act" != 1 ]; then log "  would close it: $why"; OPEN_PR_URL="$url"; continue; fi
    if ghr pr close "$url" --comment "Superseded: the model scout run of ${DATE:-today} re-derives routing from the current master instead of building on this PR, which was not auto-merged because: $why. The branch is kept — reopen and merge by hand if you still want these changes." >/dev/null 2>>"${ARTIFACTS:-/tmp}/gh.err"; then
      STALE_NOTES+=("closed older scout PR $url ($why)"); log "  closed as superseded: $why"
    else
      OPEN_PR_URL="$url"; STALE_NOTES+=("could NOT close older scout PR $url ($why)"); log "  WARN: gh pr close failed"
    fi
  done
}

# try_merge_pr: merge today's PR (PR_URL, head COMMIT on BRANCH, cwd = the scout
# worktree). Not mergeable because master moved -> rebase onto origin/master
# ONCE, re-run routecheck --no-live + the path gate, force-push with lease,
# retry. 1 = leave it open; NEEDS_WHY says why.
try_merge_pr() {
  local rebased=0 old
  NEEDS_WHY=""
  while :; do
    if ! pr_mergeable "$PR_URL"; then NEEDS_WHY="GitHub did not report mergeability of $PR_URL"; return 1; fi
    [ "$PM_PRSTATE" = OPEN ] || { NEEDS_WHY="PR is ${PM_PRSTATE:-gone}, not open"; return 1; }
    if pr_is_mergeable; then
      [ "$PM_OID" = "$COMMIT" ] || { NEEDS_WHY="PR head is ${PM_OID:0:12}, not the gated commit ${COMMIT:0:12}"; return 1; }
      gh_merge "$PR_URL" "$COMMIT" && return 0
      NEEDS_WHY="$GH_MERGE_WHY"; return 1
    fi
    if [ "$rebased" = 1 ]; then
      NEEDS_WHY="still not mergeable after one rebase onto origin/master (mergeable=$PM_MERGEABLE, mergeStateStatus=$PM_STATE)"; return 1
    fi
    remote_git . fetch -- "+refs/heads/master:refs/remotes/origin/master" ||
      { NEEDS_WHY="not mergeable ($PM_MERGEABLE/$PM_STATE) and git fetch of master failed"; return 1; }
    if git merge-base --is-ancestor origin/master HEAD; then
      NEEDS_WHY="not mergeable (mergeable=$PM_MERGEABLE, mergeStateStatus=$PM_STATE) although master has not moved"; return 1
    fi
    rebased=1
    log "master moved and the PR is not mergeable ($PM_MERGEABLE/$PM_STATE) — rebasing onto origin/master once"
    if ! git -c user.useConfigOnly=true rebase --quiet origin/master >/dev/null 2>&1; then
      git rebase --abort >/dev/null 2>&1
      NEEDS_WHY="master moved and the scout branch does not rebase cleanly onto it (conflict)"; return 1
    fi
    ROUTE_HEALTH_FILE="$ARTIFACTS/rebase-health.txt" ROUTE_HEALTH_TOOLS="$ARTIFACTS/rebase-tools.txt" \
      ROUTECHECK_XAI_SOFT=1 timeout 600 bash tests/routecheck.sh --no-live >"$ARTIFACTS/routecheck-rebase.txt" 2>&1 9>&- ||
      { NEEDS_WHY="routecheck --no-live fails after rebasing onto the moved master"; return 1; }
    path_gate . origin/master HEAD "${CLI_REPAIR:-0}" || { NEEDS_WHY="after rebase: $PATH_WHY"; return 1; }
    old=$COMMIT
    remote_git . push "--force-with-lease=refs/heads/$BRANCH:$old" -- "HEAD:refs/heads/$BRANCH" ||
      { NEEDS_WHY="rebased, but the force-push (with lease) of $BRANCH failed"; return 1; }
    COMMIT=$(git rev-parse HEAD)
    log "rebased + force-pushed $BRANCH: ${old:0:12} -> ${COMMIT:0:12}"
    sleep "${MODEL_SCOUT_GH_POLL:-5}"
  done
}

# update_live_checkout: after a merge, bring the live checkout (read in place:
# bin/routes.tsv, the docs through ~/.claude symlinks) to the new master —
# fast-forward only, and only when it is ON master. Sets LIVE_BEHIND /
# LIVE_NOTE / LIVE_TARGET (the merged master) / LIVE_UPDATED.
update_live_checkout() {
  local live=$LIVE_REPO br out
  LIVE_BEHIND="" LIVE_NOTE="" LIVE_TARGET="" LIVE_UPDATED=0
  if ! git -C "$live" rev-parse --git-dir >/dev/null 2>&1; then
    LIVE_NOTE="live checkout $live is not a git repo — not updated"; log "WARN: $LIVE_NOTE"; return
  fi
  br=$(git -C "$live" symbolic-ref --short -q HEAD) || br=""
  if ! remote_git "$live" fetch -- "+refs/heads/master:refs/remotes/origin/master"; then
    LIVE_BEHIND="${br:-detached HEAD}"; LIVE_NOTE="git fetch of master into $live failed"; log "WARN: $LIVE_NOTE"; return
  fi
  LIVE_TARGET=$(git -C "$live" rev-parse origin/master)
  if git -C "$live" merge-base --is-ancestor "$LIVE_TARGET" HEAD; then
    log "live checkout $live (${br:-detached}) already contains master ${LIVE_TARGET:0:12}"
    [ "$br" = master ] && LIVE_UPDATED=1
  elif [ "$br" != master ]; then
    LIVE_BEHIND="${br:-detached HEAD}"
    LIVE_NOTE="$live is on ${br:+branch }${br:-a detached HEAD}, not master — left untouched"
    log "live checkout NOT updated: $LIVE_NOTE"
  elif out=$(git -C "$live" merge --ff-only --quiet origin/master 2>&1); then
    LIVE_UPDATED=1; log "live checkout $live fast-forwarded to master ${LIVE_TARGET:0:12} (pull --ff-only)"
  else
    LIVE_BEHIND=master
    LIVE_NOTE="git pull --ff-only in $live failed ($(printf '%s' "$out" | tr '\n' ' ' | head -c 160)) — nothing forced"
    log "WARN: $LIVE_NOTE"
  fi
  if [ "$LIVE_UPDATED" = 1 ] && grep -q -- '--cron-only' "$live/install.sh" 2>/dev/null; then
    log "bash $live/install.sh --cron-only"
    bash "$live/install.sh" --cron-only 2>&1 9>&- | sed 's/^/  install: /'
  fi
}

if [ "${MODEL_SCOUT_LIB:-0}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

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
print(d["last_success"] or "" if "last_success" in d else (d.get("date") if d.get("status") in ("no-change","pr","merged","pr-needs-review","local-commit") else "") or "")' "$STATE" 2>/dev/null)
SINCE="${PREV_SUCCESS:-$(date -d '14 days ago' +%F)}"
# X has its own window: a degraded run (no X search) still advances
# last_success — its web research counted — but not last_x_success, so the
# next x-recency pass searches X back over the gap instead of skipping it for
# good. Never later than the research window; capped at 30 days (a key dead
# for months shouldn't mean a months-wide X search). null = no measured X
# search yet (the 14-day first-run default); state files from before this
# field fall back to last_success.
PREV_X_SUCCESS=$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit()
print((d["last_x_success"] if "last_x_success" in d else d.get("last_success")) or "")' "$STATE" 2>/dev/null)
X_SINCE="${PREV_X_SUCCESS:-$(date -d '14 days ago' +%F)}"
[[ "$SINCE" < "$X_SINCE" ]] && X_SINCE="$SINCE"
[[ "$X_SINCE" < "$(date -d '30 days ago' +%F)" ]] && X_SINCE=$(date -d '30 days ago' +%F)
X_FULL=0               # set once the grok gate measures a real x_search pass

STATUS=failed          # pessimistic until the run proves otherwise
SUMMARY="run died before finishing (see log)"
PR_URL=""
OPEN_PR_URL=""         # a scout PR still open after this run
OPEN_PRS=()            # older open scout PRs found before the run ("branch<TAB>url")
STALE_NOTES=()         # what happened to them (merged / closed as superseded)
MERGED_ANY=0           # this run merged a PR (older or today's) -> refresh the live checkout
NEEDS_REVIEW=""        # why today's PR was left open for a human
CLI_REPAIR=0           # the pre-run live routecheck failed (not just xai): model-run.sh / routecheck.sh edits may auto-merge
FINAL_LIVE=""          # result of the wrapper's final live routecheck of the committed tree (ok|fail|"")
LIVE_REPO="${MODEL_SCOUT_LIVE_REPO:-$HOME/dotfiles/claude}"
LIVE_BEHIND="" LIVE_NOTE="" LIVE_TARGET="" LIVE_UPDATED=0
NEEDS_DAN=""           # the agent's "Needs Dan" items (artifacts/needs-dan), surfaced by the banner
RESEARCH_WHY=""        # the degraded reason of a merged / pr-needs-review run (kept in state)
RH_FAIL="" RH_XAI=""   # check_route_health's verdict on the latest live routecheck
SLUG=""                # owner/repo on GitHub (gh -R, HTTPS fallback)
BRANCH=""
CLEANUP_NOTE="not run"
DEGRADED=()            # reasons a run that otherwise worked must still be recorded "failed"
RESEARCH_DEGRADED=()   # reasons it is recorded "degraded" (no X search; web-only fallback ran)
WT=""
SCRATCH=$(mktemp -d /tmp/model-scout.XXXXXX)
WORK_ROOT="$SCRATCH/work"            # the agent's throwaway model-call workdirs live here
ARTIFACTS="$SCRATCH/artifacts"       # grok output, second review, status line, signals
REGISTRY="$SCRATCH/workdirs.txt"     # workdirs the agent registered (validated at cleanup)
mkdir -p "$WORK_ROOT" "$ARTIFACTS"; : >"$REGISTRY"

fail() { STATUS=failed; SUMMARY="$*"; log "FAILED: $*"; exit 1; }

# JSON state, written atomically (the SessionStart hook reads it).
write_state() {  # $1 = the status the research itself ended with (before DEGRADED)
  local last_success="$PREV_SUCCESS" last_x_success="$PREV_X_SUCCESS"
  # A dry run did no research, so it must not shrink the next run's window.
  if [ "${1:-$STATUS}" != failed ] && [ "$DRY_RUN" -eq 0 ]; then
    last_success="$DATE"
    [ "$X_FULL" = 1 ] && last_x_success="$DATE"
  fi
  python3 - "$STATE" "$DATE" "$STATUS" "$SUMMARY" "$PR_URL" "$LOG" "$RUN_START" \
    "$last_success" "$MARKER" "$BRANCH" "$CLEANUP_NOTE" "$OPEN_PR_URL" "$last_x_success" \
    "$NEEDS_REVIEW" "$RESEARCH_WHY" "$LIVE_BEHIND" "$LIVE_NOTE" "$LIVE_TARGET" "$NEEDS_DAN" <<'PY'
import json, os, sys, time
(p, date, status, summary, pr, log, start, last_ok, marker, branch, cleanup, open_pr, last_x,
 needs_review, degraded, live_behind, live_note, live_target, needs_dan) = sys.argv[1:]
d = {"date": date, "status": status, "pr_url": pr or None, "summary": summary,
     "needs_review": needs_review or None, "degraded": degraded or None,
     "needs_dan": needs_dan or None,
     "log": log, "finished_at": int(time.time()), "started_at": int(start),
     "last_success": last_ok or None, "last_x_success": last_x or None,
     "marker": marker, "branch": branch or None,
     "cleanup": cleanup, "open_pr": open_pr or None,
     "live_checkout_behind": live_behind or None, "live_checkout_note": live_note or None,
     "live_target": live_target or None}
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
  for a in grok-research.md:grok grok-fallback.md:grok-fallback second-review.md:review; do
    [ -s "$ARTIFACTS/${a%%:*}" ] && cp "$ARTIFACTS/${a%%:*}" "$LOGDIR/$DATE.${a##*:}.md"
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

  # A merge (an older scout PR's or today's) changed master: bring the live
  # checkout along (ff-only, on master only), and — if it now holds exactly the
  # tree the final live routecheck passed — publish that verdict to the banner.
  if [ "$MERGED_ANY" = 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    section "live checkout"
    update_live_checkout
    if [ "$LIVE_UPDATED" = 1 ] && [ -n "$FINAL_LIVE" ] && [ -s "${ROUTE_HEALTH_FILE:-}" ] &&
       [ "$(git -C "$LIVE_REPO" rev-parse 'HEAD^{tree}' 2>/dev/null)" = "$(git -C "$REPO" rev-parse "${COMMIT:-none}^{tree}" 2>/dev/null)" ]; then
      cp -f "$ROUTE_HEALTH_FILE" "$LIVE_HEALTH" && cp -f "$ROUTE_HEALTH_TOOLS" "$LIVE_TOOLS" &&
        log "published the final live routecheck verdict to $LIVE_HEALTH (live checkout = the merged tree)"
    fi
    [ -n "$LIVE_BEHIND" ] && notes+=("live checkout behind master: $LIVE_NOTE")
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
  # failing sweep, routes still broken) only make the run visible as failed,
  # RESEARCH_DEGRADED ones (no X search) as degraded — an open PR is still
  # recorded in open_pr either way. failed wins over degraded.
  local research_status="$STATUS" why
  [ -n "$RH_XAI" ] && RESEARCH_DEGRADED+=("$RH_XAI")
  [ -n "$RH_FAIL" ] && DEGRADED+=("$RH_FAIL")
  if [ "${#STALE_NOTES[@]}" -gt 0 ]; then
    SUMMARY="$SUMMARY; $(printf '%s; ' "${STALE_NOTES[@]}" | sed 's/; $//')"
  fi
  if [ "${#RESEARCH_DEGRADED[@]}" -gt 0 ]; then
    why=$(IFS='|'; echo "${RESEARCH_DEGRADED[*]}" | sed 's/|/; /g')
    log "RESEARCH DEGRADED: $why"
    RESEARCH_WHY="$why"
    case "$STATUS" in
      no-change|pr|local-commit) STATUS=degraded; SUMMARY="DEGRADED: $why — $SUMMARY" ;;
      merged|pr-needs-review) SUMMARY="DEGRADED: $why — $SUMMARY" ;;   # status kept; `degraded` field set
      *) SUMMARY="$SUMMARY; DEGRADED: $why" ;;
    esac
  fi
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

# GitHub slug for gh -R / the HTTPS fallback: from origin's URL, else gh.
SLUG=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -nE 's#^.*github\.com[:/]+##p' | sed -E 's#/$##; s#\.git$##')
[ -n "$SLUG" ] || SLUG=$(cd "$REPO" && timeout 60 gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
log "github repo: ${SLUG:-unknown}"
if [ -z "$SLUG" ] && [ "$DRY_RUN" -eq 0 ] && [ "$NO_PR" -eq 0 ]; then
  fail "cannot determine the GitHub repo (origin URL / gh repo view) — needed to open and merge the PR; use --no-pr"
fi

# ---------- base selection ----------
# Always a FRESH origin/master. An older open scout PR is never stacked on any
# more: it is merged first if it passes the gates, else closed as superseded.
section "base"
if command -v gh >/dev/null 2>&1; then
  # A FAILED lookup is not "no open PR": treating it so (API blip, rate limit,
  # timeout) opened a second, conflicting scout PR next to the open one
  # (review finding 2026-09-22). Parse errors count as failures too.
  gh_rc=0
  prs_json=$(cd "$REPO" && timeout 60 gh pr list --state open --limit 100 --json headRefName,url 2>"$ARTIFACTS/gh.err") || gh_rc=$?
  [ "$gh_rc" -eq 0 ] && { open_prs=$(printf '%s' "$prs_json" | python3 -c 'import json,sys
prs=[p for p in json.load(sys.stdin) if p["headRefName"].startswith("claude/model-scout-")]
prs.sort(key=lambda p: p["headRefName"])
print("\n".join("%s\t%s" % (p["headRefName"], p["url"]) for p in prs))' 2>>"$ARTIFACTS/gh.err") || gh_rc=97; }
  if [ "$gh_rc" -ne 0 ]; then
    msg="gh pr list failed (exit $gh_rc: $(head -c 200 "$ARTIFACTS/gh.err" | tr '\n' ' ')) — cannot handle older scout PRs"
    if [ "$DRY_RUN" -eq 1 ] || [ "$NO_PR" -eq 1 ]; then log "WARN: $msg"
    elif [ -n "$BASE" ]; then log "WARN: $msg — explicit --base: committing locally only"; NO_PR=1
    else fail "$msg"; fi
  elif [ -n "$open_prs" ]; then
    while IFS= read -r line; do [ -n "$line" ] && OPEN_PRS+=("$line"); done <<<"$open_prs"
    OPEN_PR_URL="${OPEN_PRS[-1]#*$'\t'}"
    log "${#OPEN_PRS[@]} open scout PR(s): $(printf '%s ' "${OPEN_PRS[@]#*$'\t'}")"
  else
    log "no open scout PR"
  fi
else
  log "gh missing — cannot check for open scout PRs"
fi

if [ -n "$BASE" ]; then
  # An explicit base is a manual/test run: leave older scout PRs alone, and
  # don't open a second one next to them either (publish falls back to --no-pr).
  if [ "${#OPEN_PRS[@]}" -gt 0 ] && [ "$NO_PR" -eq 0 ]; then
    log "explicit --base with an open scout PR — will commit locally only (no second PR)"
    NO_PR=1
  fi
else
  remote_git "$REPO" fetch -- "+refs/heads/master:refs/remotes/origin/master" || fail "git fetch origin master failed"
  if [ "${#OPEN_PRS[@]}" -gt 0 ]; then
    section "older scout PRs"
    if [ -z "$SLUG" ]; then
      log "WARN: GitHub repo unknown — older scout PRs not handled"
    else
      OPEN_PR_URL=""
      act=1; { [ "$DRY_RUN" -eq 1 ] || [ "$NO_PR" -eq 1 ]; } && act=0
      handle_stale_prs "$act"
      [ "$MERGED_ANY" = 1 ] && { remote_git "$REPO" fetch -- "+refs/heads/master:refs/remotes/origin/master" || fail "git fetch origin master failed after merging an older scout PR"; }
    fi
  fi
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
export MODEL_SCOUT_ARTIFACTS="$ARTIFACTS" MODEL_SCOUT_DATE="$DATE" MODEL_SCOUT_SINCE="$SINCE" MODEL_SCOUT_X_SINCE="$X_SINCE"

# ---------- deterministic pre-steps → signals ----------
section "signals"
SIG="$ARTIFACTS/signals.md"
fence() { echo '```'; cat; echo '```'; }
{
  echo "## Run context (written by bin/model-scout.sh — values are literal, use them as-is)"
  echo
  echo "- Today: **$DATE**. Research window: **$SINCE → $DATE** (last successful scout run: ${PREV_SUCCESS:-none — first run, window is 14 days})."
  [ "$X_SINCE" != "$SINCE" ] && echo "- X search window: **$X_SINCE → $DATE**"' (`$MODEL_SCOUT_X_SINCE`) — wider than the research window because the last run(s) had no X search; cover X chatter from that whole span.'
  echo "- Worktree (your cwd; edit ONLY here): \`$WT\`"
  echo "- Base: \`$BASE\` (\`${BASE_SHA:0:12}\`). Your diff becomes a PR that the wrapper MERGES ITSELF today if its gates pass (no human review): see \"What happens to your diff\" above."
  echo "- Run marker: \`$MARKER\` — must appear in EVERY prompt you send to any model."
  echo "- Throwaway workdir root: \`$WORK_ROOT\` — make each workdir with \`w=\$(mktemp -d $WORK_ROOT/w.XXXXXX) && echo \"\$w\" >> $REGISTRY\`."
  echo "- Artifacts dir: \`$ARTIFACTS\` — write \`grok-research.md\` (the x-recency pass), \`grok-fallback.md\` (only if x-recency failed), \`second-review.md\` and \`status\` here."
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

# The latest LIVE routecheck on this tree (the pre-run one, the agent's re-run
# after its edits, or the wrapper's final one) still failing is actionable even
# on a no-change run — e.g. codex auth lapsed and the agent, rightly, changed
# nothing. Sets RH_FAIL (-> failed) / RH_XAI (-> degraded); re-callable, the
# last call wins (finish() adds them to DEGRADED / RESEARCH_DEGRADED).
check_route_health() {
  RH_FAIL="" RH_XAI=""
  [ -s "$ROUTE_HEALTH_FILE" ] || return 0
  grep -qE '^[0-9-]+ ok' "$ROUTE_HEALTH_FILE" && return 0
  local auth="" fails xai_names others
  # Only the xai route failing (auth:xai / its live smoke) = the XAI_API_KEY's
  # account (rejected, out of credits, rate-limited) or xAI itself — nothing in
  # the tree to fix, and the research already fell back without X. Degraded,
  # not failed. Anything else failing alongside it still fails the run.
  fails=$(cut -d' ' -f3- "$ROUTE_HEALTH_FILE")
  xai_names="auth:xai $(awk -F'\t' '$1=="model" && $3=="xai" {printf "route:%s ", $2}' bin/routes.tsv 2>/dev/null)"
  others=$(awk -v ids="$xai_names" 'BEGIN {n = split(ids, a, " "); for (i = 1; i <= n; i++) x[a[i]] = 1}
    {for (i = 1; i <= NF; i++) if (!($i in x)) printf "%s ", $i}' <<<"$fails")
  if [ -n "$fails" ] && [ -z "$others" ]; then
    RH_XAI="live routecheck fails only the xai route ($fails) — XAI_API_KEY rejected / out of xAI credits / rate-limited; fix the key in ~/.profile"
    return 0
  fi
  grep -qsF 'AUTH/QUOTA' "$RC_OUT" "$ARTIFACTS/routecheck-final.txt" "$WORK_ROOT"/*/routecheck.txt && auth=" (AUTH/QUOTA errors: codex login / cursor-agent login)"
  grep -qsE '^FAIL +auth:xai' "$RC_OUT" "$ARTIFACTS/routecheck-final.txt" "$WORK_ROOT"/*/routecheck.txt && auth="$auth (XAI_API_KEY rejected / out of xAI credits — fix the key in ~/.profile)"
  RH_FAIL="live routecheck still FAILS: $(cut -d' ' -f3- "$ROUTE_HEALTH_FILE" | head -c 200)$auth"
}
# A pre-run LIVE routecheck on the base that fails on more than the xai key =
# something (usually a CLI update) broke a route: this run is a repair, and its
# bin/model-run.sh / tests/routecheck.sh edits may auto-merge (the final live
# routecheck must still pass).
if [ "$RC_RC" != skip ] && [ "${#rc_args[@]}" -eq 0 ] && [ "$RC_RC" -ne 0 ]; then
  check_route_health
  if [ -n "$RH_FAIL" ]; then CLI_REPAIR=1; log "pre-run live routecheck fails (not just xai) — CLI-break repair run"; fi
fi

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
# The grok pass is mandatory, and its X search is MEASURED, not self-reported:
# grok-research.md must be real `model-run.sh --task-type x-recency` output
# (stderr captured with it), whose `model-run: xai-tools x_search=<n>` line
# comes from the xAI response's usage — printed only for a usable answer.
#   x-recency ok, x_search >= 1          -> full research
#   x-recency 75/73/124/other, or 0 X    -> the agent must have run the
#     `--task-type recency` fallback (cursor grok, web only) into
#     grok-fallback.md: the run is DEGRADED (status "degraded"), with the
#     reason named (a 75 as "XAI_API_KEY rejected" etc.) — never silent
#   no/foreign output, no fallback, or the fallback failed too -> BLOCKED
GROK="$ARTIFACTS/grok-research.md"
GROK_FB="$ARTIFACTS/grok-fallback.md"
XERR_RE='^model-run: (AUTH/QUOTA ERROR|TRANSPORT ERROR|TIMEOUT|xAI |could not build|MODEL_RUN_XSEARCH)'
if [ -z "$BLOCKED" ]; then
  if [ ! -s "$GROK" ]; then
    BLOCKED="agent skipped the mandatory grok x-recency pass (no grok-research.md)"
  elif ! grep -qE '^model-run: --task-type x-recency -> ' "$GROK"; then
    BLOCKED="grok-research.md is not bin/model-run.sh --task-type x-recency output"
  else
    xtools=$(grep -E '^model-run: xai-tools ' "$GROK" | tail -1)
    xs=$(printf '%s' "$xtools" | grep -oE 'x_search=[0-9]+' | cut -d= -f2)
    xerr=$(grep -m1 -E "$XERR_RE" "$GROK" | head -c 300)
    if [ -z "$xerr" ] && [ -n "$xtools" ] && [ "${xs:-0}" -ge 1 ]; then
      X_FULL=1
      log "grok x-recency: FULL — ${xtools#model-run: xai-tools }"
    else
      case "$xerr" in
        *"XAI_API_KEY not set"*) why="XAI_API_KEY not set (x-recency exit 75)" ;;
        *"XAI_API_KEY rejected"*) why="XAI_API_KEY rejected (x-recency exit 75: $(printf '%s' "$xerr" | grep -oE '"error":"[^"]*"' | head -c 120))" ;;
        *"AUTH/QUOTA"*) why="xAI credits / rate limit exhausted (x-recency exit 75)" ;;
        *"TRANSPORT ERROR"*) why="xAI transport error (x-recency exit 73)" ;;
        *"TIMEOUT"*) why="xAI timeout (x-recency exit 124)" ;;
        ?*) why="x-recency failed: ${xerr#model-run: }" ;;
        *) if [ -z "$xtools" ]; then why="x-recency produced no answer (no xai-tools line)"
           else why="x-recency made 0 x_search calls"; fi ;;
      esac
      why=$(printf '%s' "$why" | head -c 200)
      log "grok x-recency NOT full: $why"
      if [ ! -s "$GROK_FB" ]; then
        BLOCKED="$why, and the agent ran no --task-type recency fallback (no grok-fallback.md)"
      elif ! grep -qE '^model-run: --task-type recency -> grok-' "$GROK_FB"; then
        BLOCKED="$why; grok-fallback.md is not bin/model-run.sh --task-type recency output"
      elif fb=$(grep -m1 -oE '^model-run: (AUTH/QUOTA ERROR|TRANSPORT ERROR|TIMEOUT)' "$GROK_FB"); then
        BLOCKED="both grok passes failed: $why; cursor recency fallback ${fb#model-run: }"
      else
        RESEARCH_DEGRADED+=("no X search — $why; research fell back to cursor grok (web only)")
      fi
    fi
  fi
fi
check_route_health
AGENT_SUMMARY="${AGENT_STATUS#ok}"; AGENT_SUMMARY="${AGENT_SUMMARY#blocked}"; AGENT_SUMMARY="${AGENT_SUMMARY# }"
# Nobody reads a merged PR's "Needs Dan" section, so the agent also lists those
# items in artifacts/needs-dan; they go to last-run.json and the banner.
NEEDS_DAN=$(grep -v '^[[:space:]]*$' "$ARTIFACTS/needs-dan" 2>/dev/null | head -5 | paste -sd';' - | sed 's/;/; /g' | head -c 400)
[ -n "$NEEDS_DAN" ] && log "needs Dan: $NEEDS_DAN"

# ---------- gate ----------
section "gate"
[ -f scout/last-report.md ] && cp scout/last-report.md "$LOGDIR/$DATE.report.md"
# Only routing-layer files may change. Anything else (install.sh, settings,
# this script, the cleanup scripts, the scout prompt, skills) is reverted:
# those are reviewed by hand, never rewritten by the daily job.
ALLOW='^(bin/(routes\.tsv|model-run\.sh|catalog-drift\.sh|cli-fingerprint\.sh)|tests/routecheck\.sh|tests/workflows/[^/]+\.js|hooks/route-guard\.sh|hooks/route-health-banner\.sh|agents/model-runner\.md|model-selection\.md|model-usage\.md|README\.md|system-map\.md|scout/(evaluated\.tsv|last-report\.md))$'
# A reverted edit is kept in logs/<date>.reverted.patch, and it also stops the
# auto-merge: the agent thought something outside the routing layer needed
# changing, so a human should look at the whole picture.
REVERTED=()
git add -A
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! printf '%s\n' "$f" | grep -qE "$ALLOW"; then
    log "REVERTED out-of-scope change: $f"
    REVERTED+=("$f")
    git diff --cached -- "$f" >>"$LOGDIR/$DATE.reverted.patch" 2>/dev/null
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
  [ "${#REVERTED[@]}" -gt 0 ] && SUMMARY="$SUMMARY; reverted out-of-scope edit(s) ${REVERTED[*]} (logs/$DATE.reverted.patch)"
  exit 0
fi
log "changed files:"; git diff --cached --stat | sed 's/^/  /'
for f in $(git diff --cached --name-only --diff-filter=d -- '*.sh'); do
  bash -n "$f" || fail "syntax error in $f after agent edits"
done
[ -s scout/last-report.md ] || fail "agent changed files but wrote no scout/last-report.md"
# ROUTECHECK_XAI_SOFT: a rejected / out-of-credit XAI_API_KEY is the account,
# not this diff — it must not block publishing verified routing edits (the run
# is recorded degraded via check_route_health / the grok gate instead).
ROUTECHECK_XAI_SOFT=1 timeout 600 bash tests/routecheck.sh --no-live >"$ARTIFACTS/routecheck-gate.txt" 2>&1 9>&-
GATE_RC=$?
grep -E '^FAIL |^WARN .*ROUTECHECK_XAI_SOFT' "$ARTIFACTS/routecheck-gate.txt" | sed 's/^/  /'
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

# ---------- auto-merge gates (local part) ----------
# Everything that can be decided before GitHub is involved. Any reason here
# leaves today's PR open for a human ("pr-needs-review").
section "auto-merge gates"
MERGE_WHY=()
[ -n "$BLOCKED" ] && MERGE_WHY+=("run BLOCKED: $BLOCKED")
[ -s "$ARTIFACTS/second-review.md" ] || MERGE_WHY+=("no second review")
[ "${#REVERTED[@]}" -gt 0 ] && MERGE_WHY+=("the agent also edited out-of-scope file(s), reverted — see $LOGDIR/$DATE.reverted.patch: ${REVERTED[*]}")
path_gate . "$BASE_SHA" HEAD "$CLI_REPAIR" || MERGE_WHY+=("$PATH_WHY")
if [ "${#MERGE_WHY[@]}" -gt 0 ]; then
  log "no final live routecheck: the PR already needs review"
elif [ "$ROUTECHECK_MODE" != live ] || ! grep -q ROUTECHECK_MARKER tests/routecheck.sh; then
  MERGE_WHY+=("no final live routecheck (MODEL_SCOUT_ROUTECHECK=$ROUTECHECK_MODE)")
elif [ "$NO_PR" -eq 1 ]; then
  log "--no-pr: final live routecheck skipped (nothing will be merged)"
else
  # The FINAL live routecheck, of exactly the committed tree, run by the wrapper
  # (the agent's last run may predate its last edit). Strict — no XAI_SOFT — so
  # its verdict is true; check_route_health then tolerates xai-only failures
  # (= degraded, still merges) and nothing else.
  log "final live routecheck of ${COMMIT:0:12}"
  rm -f "$ROUTE_HEALTH_FILE"   # its verdict must be this run's, not an earlier one's
  timeout 2400 bash tests/routecheck.sh >"$ARTIFACTS/routecheck-final.txt" 2>&1 9>&-
  FINAL_RC=$?
  log "final live routecheck exit $FINAL_RC"; grep -E '^(FAIL|WARN) ' "$ARTIFACTS/routecheck-final.txt" | sed 's/^/  /'
  if [ ! -s "$ROUTE_HEALTH_FILE" ]; then
    FINAL_LIVE=fail; MERGE_WHY+=("final live routecheck exit $FINAL_RC without a verdict")
  else
    check_route_health
    if [ -n "$RH_FAIL" ]; then FINAL_LIVE=fail; MERGE_WHY+=("final $RH_FAIL")
    else FINAL_LIVE=ok; fi
  fi
fi
if [ "${#MERGE_WHY[@]}" -eq 0 ]; then log "local auto-merge gates: pass$([ "$CLI_REPAIR" = 1 ] && echo ' (CLI-break repair)')"
else log "local auto-merge gates: $(printf '%s; ' "${MERGE_WHY[@]}")"; fi

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
  STATUS=local-commit; [ -n "$BLOCKED" ] && STATUS=failed
  SUMMARY="${BLOCKED:+BLOCKED: $BLOCKED; }committed locally on $BRANCH (--no-pr): $AGENT_SUMMARY"
  exit 0
fi

BRANCH=$(new_branch_name)
if ! remote_git . push -- "HEAD:refs/heads/$BRANCH"; then
  git -C "$REPO" branch -f "$BRANCH" "$COMMIT" >/dev/null 2>&1
  fail "git push of $BRANCH failed (commit ${COMMIT:0:12} kept on local branch $BRANCH)"
fi
log "pushed $BRANCH"

BODY="$ARTIFACTS/pr-body.md"
{ cat scout/last-report.md; echo; echo "---"; echo "Run marker \`$MARKER\` · log \`$LOG\` · agent $A_MODEL, $A_TURNS turns, \$$A_COST"
  # The marker tells the NEXT run's older-PR pass whether this run wanted a human.
  if [ "${#MERGE_WHY[@]}" -eq 0 ]; then
    echo "<!-- model-scout-automerge: yes -->Auto-merge: local gates passed (final live routecheck ok$([ "$CLI_REPAIR" = 1 ] && echo ', CLI-break repair')) — the scout merges this PR itself."
  else
    echo "<!-- model-scout-automerge: no -->Auto-merge: NOT auto-merged — $(printf '%s; ' "${MERGE_WHY[@]}" | sed 's/; $//')"
  fi; echo
  echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"; } >"$BODY"
PR_URL=$(cd "$REPO" && timeout 60 gh pr create --base master --head "$BRANCH" \
  --title "$subject" --body-file "$BODY" 2>&1 | grep -Eo 'https://github\.com/[^ ]+/pull/[0-9]+' | tail -1)
[ -n "$PR_URL" ] || fail "branch $BRANCH pushed but gh pr create failed"
OPEN_PR_URL="$PR_URL"
log "PR: $PR_URL"
if [ -n "$BLOCKED" ]; then
  STATUS=failed; SUMMARY="BLOCKED: $BLOCKED — partial changes in $PR_URL (left open)"
  exit 0
fi

# ---------- auto-merge ----------
section "auto-merge"
if [ "${#MERGE_WHY[@]}" -eq 0 ] && try_merge_pr; then
  MERGED_ANY=1; OPEN_PR_URL=""
  STATUS=merged; SUMMARY="${AGENT_SUMMARY:-routing update} (auto-merged)"
  log "merged $PR_URL"
else
  [ "${#MERGE_WHY[@]}" -eq 0 ] && MERGE_WHY+=("$NEEDS_WHY")
  NEEDS_REVIEW=$(printf '%s; ' "${MERGE_WHY[@]}" | sed 's/; $//')
  STATUS=pr-needs-review; SUMMARY="$AGENT_SUMMARY — left open for review: $NEEDS_REVIEW"
  log "PR left open for review: $NEEDS_REVIEW"
  ghr pr comment "$PR_URL" --body "Not auto-merged by the model scout: $NEEDS_REVIEW. Review and merge by hand, or leave it: the next daily run merges it if its gates pass then, otherwise closes it as superseded and re-derives from master." >/dev/null 2>&1 ||
    log "WARN: gh pr comment failed"
fi
exit 0
