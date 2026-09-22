#!/usr/bin/env bash
# t3-purge-test-threads — delete test-chat litter from T3 Code through T3's own
# orchestration API, never by writing SQL. Backstop for model-scout / routecheck:
# a `claude -p` transcript that did get persisted under ~/.claude/projects is
# imported by the t3-claude-import timer (every 15 min) as thread
# `claude-import-<sessionId>`, and the importer auto-creates a project for its
# cwd (that is how 'tmp' (/tmp) and 'claude-grok-4.7' (/tmp/claude-grok-4.7)
# appeared). Deleting the .jsonl afterwards does NOT remove the thread.
#
#   bash ~/dotfiles/claude/bin/t3-purge-test-threads.sh --marker <str> --since <epoch> [--thread-id <id> ...] [--apply]
#
# Dry-run unless --apply. Selection (read-only sqlite, mode=ro, on
# $T3_BASE_DIR/userdata/state.sqlite):
#   threads   live (deleted_at NULL) `claude-import-*` threads created at/after
#             --since whose FIRST user message contains --marker, and that have at
#             most T3_PURGE_MAX_USER_MSGS (default 3) user messages — a longer
#             thread is a real conversation that merely quotes the marker and is
#             skipped with a note; plus every --thread-id given (must be a live
#             `claude-import-*` thread; test chats only reach T3 via the importer).
#   projects  live projects created at/after --since BY THE IMPORTER (their
#             project.created command id is `import:*:project-create`) whose
#             workspace_root is under /tmp or /var/tmp ($TMPDIR is NOT trusted:
#             it could be $HOME) and that are
#             left with 0 non-deleted threads once the threads above are gone.
#             Dispatched WITHOUT force, so T3 itself refuses a non-empty project.
# Deletion: `thread.delete` / `project.delete` POSTed to the running server's
# /api/orchestration/dispatch — the same live path `t3 project remove` uses —
# with a short-lived bearer session issued (and revoked on exit) by the T3 CLI's
# own `t3 auth session issue`. The server's reactors stop any provider session /
# terminals and the importer tombstones deleted threads (never re-imported).
#
# Output, one line per item: `would-delete-thread|thread-deleted|would-delete-project|
# project-deleted|skip|note|error <id> ...`.
# Exit: 0 ok or nothing found · 2 internal error (DB read, token issue, a dispatch
# failed) · 3 --apply but the T3 server is not running (thread.delete has no
# offline CLI path — `t3` has no `thread` subcommand — so rerun once it is up)
# · 64 usage.
# Env: T3_BASE_DIR (default ~/.t3), T3_SERVER_DIR (t3code-v2/apps/server),
# T3_PURGE_MAX_USER_MSGS (default 3).
# 2026-09-22: written for the daily model-scout; first real run deleted the 5
# ROUTE-OK / "say OK" threads left by routecheck runs before --no-session-persistence.
set -u -o pipefail

T3_BASE_DIR="${T3_BASE_DIR:-$HOME/.t3}"
T3_SERVER_DIR="${T3_SERVER_DIR:-$HOME/projects/meta/t3code-v2/apps/server}"
DB="$T3_BASE_DIR/userdata/state.sqlite"
RUNTIME_STATE="$T3_BASE_DIR/userdata/server-runtime.json"
MAX_USER_MSGS="${T3_PURGE_MAX_USER_MSGS:-3}"

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }
MARKER=""; SINCE=""; APPLY=0; IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --marker)    [ $# -ge 2 ] || { echo "t3-purge: --marker needs a value" >&2; exit 64; }; MARKER="$2"; shift 2 ;;
    --since)     [ $# -ge 2 ] || { echo "t3-purge: --since needs a value" >&2; exit 64; }; SINCE="$2"; shift 2 ;;
    --thread-id) [ $# -ge 2 ] || { echo "t3-purge: --thread-id needs a value" >&2; exit 64; }; IDS+=("$2"); shift 2 ;;
    --apply)     APPLY=1; shift ;;
    --dry-run)   APPLY=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "t3-purge: unknown arg '$1'" >&2; exit 64 ;;
  esac
done
case "$SINCE" in ''|*[!0-9]*) echo "t3-purge: --since <epoch-seconds> is required" >&2; exit 64 ;; esac
# A marker shorter than 6 chars would match far too much; the scout's is MODEL-SCOUT-<date>-<rand>.
if [ -n "$MARKER" ] && [ "${#MARKER}" -lt 6 ]; then echo "t3-purge: --marker too short (<6 chars)" >&2; exit 64; fi
if [ -z "$MARKER" ] && [ ${#IDS[@]} -eq 0 ]; then echo "t3-purge: need --marker and/or --thread-id" >&2; exit 64; fi
[ -f "$DB" ] || { echo "t3-purge: note T3 database not found at $DB — nothing to purge"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "t3-purge: python3 required (no sqlite3 binary on this box)" >&2; exit 2; }

# ---- plan: read-only query. Emits TSV rows: thread|project|skip|note ----
PLAN=$(python3 - "$DB" "$SINCE" "$MARKER" "$MAX_USER_MSGS" "${IDS[@]}" <<'PY'
import sqlite3, sys, datetime, os
db_path, since, marker, max_user = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
explicit = sys.argv[5:]
since_iso = datetime.datetime.fromtimestamp(since, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
db = sqlite3.connect('file:' + db_path + '?mode=ro', uri=True, timeout=10)
c = db.cursor()
# EVERY field is flattened: a project/thread title containing a newline + tab
# could otherwise forge a whole `thread<TAB><any id>` plan row and get an
# unrelated thread deleted (review finding 2026-09-22). Ids are re-validated
# before dispatch as well.
flat = lambda s: ' '.join(str('' if s is None else s).split())
clean = lambda s: flat(s)[:90]
def emit(*f): print('\t'.join(flat(x) for x in f))
def user_count(tid):
    return c.execute("SELECT count(*) FROM projection_thread_messages WHERE thread_id=? AND role='user'", (tid,)).fetchone()[0]
TQ = """SELECT t.thread_id, t.project_id, t.created_at, t.title, t.deleted_at, p.title
        FROM projection_threads t LEFT JOIN projection_projects p ON p.project_id = t.project_id"""
targets = {}
for tid in explicit:
    r = c.execute(TQ + " WHERE t.thread_id=?", (tid,)).fetchone()
    if r is None: emit('note', tid, 'not found in T3'); continue
    if r[4] is not None: emit('note', tid, 'already deleted at ' + r[4]); continue
    if not tid.startswith('claude-import-'):
        emit('skip', tid, 'not a claude-import-* thread (test chats only reach T3 via the importer); refusing'); continue
    targets[tid] = r
if marker:
    rows = c.execute(TQ + """ WHERE t.deleted_at IS NULL AND t.thread_id LIKE 'claude-import-%'
        AND t.created_at >= ? AND instr((SELECT m.text FROM projection_thread_messages m
            WHERE m.thread_id = t.thread_id AND m.role = 'user'
            ORDER BY m.created_at, m.message_id LIMIT 1), ?) > 0""", (since_iso, marker)).fetchall()
    for r in rows:
        if r[0] in targets: continue
        n = user_count(r[0])
        if n > max_user:
            emit('skip', r[0], f'first user message has marker but thread has {n} user messages (real conversation?)'); continue
        targets[r[0]] = r
for tid, r in targets.items():
    emit('thread', tid, r[5] or r[1], r[2], clean(r[3]))
def is_tmp(root):
    for base in ('/tmp', '/var/tmp'):
        if root == base or root.startswith(base + '/'): return True
    return False
for pid, title, root, created in c.execute("""SELECT project_id, title, workspace_root, created_at
        FROM projection_projects WHERE deleted_at IS NULL AND created_at >= ?""", (since_iso,)).fetchall():
    if not is_tmp(root or ''): continue
    ev = c.execute("""SELECT command_id FROM orchestration_events WHERE stream_id=? AND event_type='project.created'
        ORDER BY sequence LIMIT 1""", (pid,)).fetchone()
    if not ev or not (ev[0] or '').startswith('import:') or not ev[0].endswith(':project-create'): continue
    live = [t for (t,) in c.execute("SELECT thread_id FROM projection_threads WHERE project_id=? AND deleted_at IS NULL", (pid,))]
    left = [t for t in live if t not in targets]
    if left:
        emit('note', pid, f'temp-dir project {title} ({root}) kept: {len(left)} live thread(s) remain'); continue
    emit('project', pid, title, root, created)
PY
) || { echo "t3-purge: error reading $DB (read-only query failed)" >&2; exit 2; }

N_THREADS=0; N_PROJECTS=0
while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    thread)  N_THREADS=$((N_THREADS+1)) ;;
    project) N_PROJECTS=$((N_PROJECTS+1)) ;;
    skip|note) printf '%s\t%s\t%s\n' "$kind" "$a" "$b" ;;
  esac
done <<<"$PLAN"

if [ "$APPLY" -eq 0 ] || [ $((N_THREADS+N_PROJECTS)) -eq 0 ]; then
  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      thread)  printf 'would-delete-thread\t%s\t[%s]\t%s\t%s\n' "$a" "$b" "$c" "$d" ;;
      project) printf 'would-delete-project\t%s\t%s\t%s\n' "$a" "$b" "$c" ;;
    esac
  done <<<"$PLAN"
  [ $((N_THREADS+N_PROJECTS)) -eq 0 ] && echo "t3-purge: nothing to purge" \
    || echo "t3-purge: dry-run — $N_THREADS thread(s), $N_PROJECTS project(s); rerun with --apply to delete"
  exit 0
fi

# ---- apply: live server only ----
ORIGIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["origin"])' "$RUNTIME_STATE" 2>/dev/null) || ORIGIN=""
if [ -z "$ORIGIN" ] || ! curl -sf -m 3 -o /dev/null "$ORIGIN/.well-known/t3/environment"; then
  echo "t3-purge: T3 server not running (no reachable origin in $RUNTIME_STATE); thread.delete has no offline CLI path — rerun once the server is up. Nothing deleted." >&2
  exit 3
fi

t3cli() {
  if command -v mise >/dev/null 2>&1; then (cd "$T3_SERVER_DIR" && mise exec node@24 -- node src/bin.ts "$@")
  else (cd "$T3_SERVER_DIR" && node src/bin.ts "$@"); fi
}
WORK=$(mktemp -d /tmp/t3-purge.XXXXXX) || exit 2
chmod 700 "$WORK"
SESSION_ID=""
cleanup() {
  [ -n "$SESSION_ID" ] && t3cli auth session revoke --base-dir "$T3_BASE_DIR" "$SESSION_ID" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# Same scopes as `t3 project` (AuthAdministrativeScopes); 10m TTL caps exposure if revoke fails.
ISSUED=$(t3cli auth session issue --base-dir "$T3_BASE_DIR" --ttl 10m --label t3-purge-test-threads --json 2>"$WORK/issue.err") \
  || { echo "t3-purge: could not issue a T3 session token: $(tail -3 "$WORK/issue.err")" >&2; exit 2; }
SESSION_ID=$(printf '%s' "$ISSUED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sessionId"])' 2>/dev/null) || SESSION_ID=""
TOKEN=$(printf '%s' "$ISSUED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null) || TOKEN=""
unset ISSUED
[ -n "$TOKEN" ] || { echo "t3-purge: T3 session issue returned no token" >&2; exit 2; }
printf 'authorization: Bearer %s\n' "$TOKEN" >"$WORK/auth.hdr"; unset TOKEN

FAILED=0
# dispatch <json> → 0 on HTTP 200; body left in $WORK/resp
dispatch() {
  local code
  code=$(curl -sS -m 30 -o "$WORK/resp" -w '%{http_code}' -H @"$WORK/auth.hdr" \
    -H 'content-type: application/json' --data-binary "$1" "$ORIGIN/api/orchestration/dispatch" 2>"$WORK/curl.err") || code=000
  [ "$code" = 200 ] && return 0
  printf 'HTTP %s %s %s' "$code" "$(head -c 300 "$WORK/resp" 2>/dev/null)" "$(head -c 200 "$WORK/curl.err")" >"$WORK/why"
  return 1
}
cmd_json() {  # cmd_json <type> <idfield> <id>
  python3 -c 'import json,sys,uuid; print(json.dumps({"type":sys.argv[1],"commandId":str(uuid.uuid4()),sys.argv[2]:sys.argv[3]}))' "$@"
}

# Belt and braces on top of the planner's flattening: only ids of the exact
# shapes selected above are ever dispatched.
valid_id() { case "$1" in thread) [[ "$2" =~ ^claude-import-[A-Za-z0-9._-]+$ ]] ;; project) [[ "$2" =~ ^[A-Za-z0-9._:-]+$ ]] ;; *) false ;; esac; }
while IFS=$'\t' read -r kind a b c d; do
  [ "$kind" = thread ] || continue
  valid_id thread "$a" || { printf 'error\t%s\trefusing: not a claude-import-* thread id\n' "$a"; FAILED=1; continue; }
  if dispatch "$(cmd_json thread.delete threadId "$a")"; then
    printf 'thread-deleted\t%s\t[%s]\t%s\t%s\n' "$a" "$b" "$c" "$d"
  else
    printf 'error\t%s\tthread.delete failed: %s\n' "$a" "$(cat "$WORK/why")"; FAILED=1
  fi
done <<<"$PLAN"
while IFS=$'\t' read -r kind a b c d; do
  [ "$kind" = project ] || continue
  valid_id project "$a" || { printf 'error\t%s\trefusing: malformed project id\n' "$a"; FAILED=1; continue; }
  # No force: T3's decider rejects the delete if any non-archived thread is still live.
  if dispatch "$(cmd_json project.delete projectId "$a")"; then
    printf 'project-deleted\t%s\t%s\t%s\n' "$a" "$b" "$c"
  else
    printf 'error\t%s\tproject.delete (%s %s) failed: %s\n' "$a" "$b" "$c" "$(cat "$WORK/why")"; FAILED=1
  fi
done <<<"$PLAN"

[ "$FAILED" -eq 0 ] || exit 2
exit 0
