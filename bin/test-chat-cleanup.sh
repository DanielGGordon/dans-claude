#!/usr/bin/env bash
# test-chat-cleanup — delete the chat/session records that TEST runs leave in
# the Codex, Cursor and Claude CLIs' own histories — and nothing else. Exists
# because every routecheck / smoke run used to leave its "Output exactly this
# line ... ROUTE-OK-<n>" chats behind: by 2026-09-22 there were 97 routecheck
# threads in Codex, 238 routecheck chats in Cursor, and routecheck's haiku
# smoke had landed in T3 Code as visible threads (the t3-claude-import timer
# imports every top-level ~/.claude/projects/*/*.jsonl every 15 minutes).
#
#   bash ~/dotfiles/claude/bin/test-chat-cleanup.sh --since <epoch> --marker <string> \
#        --workdir <dir> [--workdir <dir> ...] [--dry-run]
#
# A record is deleted ONLY if it was created at/after --since AND (its cwd is
# exactly one of the --workdir dirs OR its first user message contains
# --marker). Prevention comes first (MODEL_RUN_EPHEMERAL=1 -> codex
# --ephemeral; `claude -p --no-session-persistence`); this is the net for what
# cannot be made ephemeral (Cursor has no such flag) or slipped through:
#   Cursor  ~/.cursor/chats/<md5(cwd)>/<chatId>/ (meta.json cwd/createdAtMs are
#           checked per chat before deleting) + ~/.cursor/projects/<slug>/
#           agent-transcripts/<chatId>/; a workdir's whole projects/<slug>/ dir
#           goes once no transcripts remain AND its .workspace-trusted
#           workspacePath is that workdir (slugs are lossy, so never assumed).
#   Codex   rollouts in ~/.codex/sessions + state_5.sqlite thread rows (read
#           mode=ro) -> `codex delete --force <id>` (the supported path: also
#           drops the thread rows); falls back to removing the rollout file,
#           with a `note` line, if the subcommand is missing or fails.
#   Claude  top-level ~/.claude/projects/<enc-cwd>/<id>.jsonl (+ <id>/ dir). The
#           creation time is the transcript's FIRST timestamp, not its mtime,
#           so a long-running session that merely mentions the marker later
#           (e.g. the one that launched the test) is never touched. Also a
#           --workdir's own ~/.claude/projects/<enc(workdir)>/ when it holds no
#           files (only the empty memory/ dir a non-persisted `claude -p` makes).
# Does NOT touch T3 Code — a transcript the importer already picked up is a
# T3 thread; purge those with bin/t3-purge-test-threads.sh.
#
# Output, one line per record, tab-separated:
#   deleted|would-delete  <cli>  <what>        (would-delete under --dry-run)
#   note                  <cli>  <message>     (fallbacks, skipped look-alikes)
# plus a one-line count summary on stderr.
# Exit: 0 ok (also when nothing matched) · 2 internal error (a section crashed;
# the other sections still ran) · 64 usage (bad/missing args, a marker shorter
# than 8 chars, or a broad workdir like / /tmp $HOME that could match real chats).
# Env: TEST_CHAT_CLEANUP_HOME=<dir> roots ALL three stores at <dir>/.cursor,
# <dir>/.codex, <dir>/.claude (routecheck's mock tier uses it; codex delete is
# then run with CODEX_HOME=<dir>/.codex). Otherwise CODEX_HOME /
# CLAUDE_CONFIG_DIR / $HOME as the CLIs themselves resolve them.
set -u

usage() { sed -n '10,11p' "$0" | sed 's/^# \{0,1\}/usage: /' >&2; echo "test-chat-cleanup: $1" >&2; exit 64; }
SINCE=""; MARKER=""; DRY=0; WORKDIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --since)   SINCE="${2:-}"; shift 2 2>/dev/null || usage "--since needs a value" ;;
    --marker)  MARKER="${2:-}"; shift 2 2>/dev/null || usage "--marker needs a value" ;;
    --workdir) [ -n "${2:-}" ] || usage "--workdir needs a value"; WORKDIRS+=("$2"); shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) usage "unknown arg '$1'" ;;
  esac
done
[[ "$SINCE" =~ ^[0-9]+$ ]] || usage "--since must be an epoch (seconds)"
# The marker is the only thing standing between a marker match and a real
# chat that happens to contain the same text — insist on something unique.
[ "${#MARKER}" -ge 8 ] || usage "--marker must be >= 8 chars (use a per-run random marker)"
for w in "${WORKDIRS[@]}"; do
  case "$w" in /*) ;; *) usage "--workdir must be absolute: $w" ;; esac
  w="${w%/}"
  # Throwaway dirs only: a broad dir (or any ancestor of $HOME) could hold the
  # user's real chats created after --since.
  case "$w" in ""|/tmp|/var/tmp|/home|"$HOME"|"${HOME%/*}") usage "refusing broad --workdir '$w' (pass the run's own mktemp dir)" ;; esac
done

python3 - "$SINCE" "$MARKER" "$DRY" "${WORKDIRS[@]}" <<'PYEOF'
import glob, hashlib, json, os, re, shutil, sqlite3, subprocess, sys
from datetime import datetime

since, marker, dry = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
home = os.path.expanduser("~")

def broad(p):
    """/, /tmp, /var/tmp, /home, $HOME or any ancestor of $HOME: could hold real chats."""
    p = p.rstrip("/") or "/"
    return p in ("/", "/tmp", "/var/tmp", "/home", home) or home.startswith(p + "/")

workdirs = set()
for w in sys.argv[4:]:
    w = w.rstrip("/")
    workdirs.add(w)
    if os.path.exists(w):
        # The CLIs may record the resolved path — but a symlinked "throwaway"
        # dir (w.x -> $HOME) must not smuggle a broad dir past the bash-side
        # check, which only saw the literal string (review finding 2026-09-22).
        r = os.path.realpath(w)
        if broad(r):
            print(f"test-chat-cleanup: refusing --workdir '{w}': it resolves to broad dir '{r}'", file=sys.stderr)
            sys.exit(64)
        workdirs.add(r)

root = os.environ.get("TEST_CHAT_CLEANUP_HOME")
CURSOR = os.path.join(root or home, ".cursor")
CODEX = os.path.join(root, ".codex") if root else os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
CLAUDE = os.path.join(root, ".claude") if root else os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")

counts, errors = {"cursor": 0, "codex": 0, "claude": 0}, []

def out(kind, cli, what):
    print(f"{kind}\t{cli}\t{what}", flush=True)

def gone(cli, what, fn):
    """Delete via fn() (unless --dry-run) and report it."""
    if not dry:
        fn()
    counts[cli] += 1
    out("would-delete" if dry else "deleted", cli, what)

def rm(path):
    shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)

def iso_epoch(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def text_of(content):
    """Plain text of a message content (str, or a list of {type:text,...} parts)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and isinstance(p.get("text"), str))
    return ""

# ---------------- Cursor ----------------
def cursor():
    chats, projects = os.path.join(CURSOR, "chats"), os.path.join(CURSOR, "projects")
    if not os.path.isdir(chats):
        return
    targets = {}   # chatId -> (chat dir, why)
    for meta_path in glob.glob(os.path.join(chats, "*", "*", "meta.json")):
        chat_dir = os.path.dirname(meta_path)
        cid = os.path.basename(chat_dir)
        try:
            meta = json.load(open(meta_path))
        except Exception:
            continue
        created = (meta.get("createdAtMs") or 0) / 1000
        if created < since:
            continue
        cwd = str(meta.get("cwd", "")).rstrip("/")
        if cwd in workdirs:
            # The dir name is md5(cwd); a mismatch means it isn't what we think.
            if os.path.basename(os.path.dirname(chat_dir)) != hashlib.md5(cwd.encode()).hexdigest():
                out("note", "cursor", f"skipped {chat_dir}: meta.json cwd {cwd} does not hash to its dir")
                continue
            targets[cid] = (chat_dir, f"cwd={cwd}")
            continue
        # Marker match for a chat run elsewhere: its transcript's first user message.
        for tr in glob.glob(os.path.join(projects, "*", "agent-transcripts", cid, cid + ".jsonl")):
            try:
                with open(tr) as f:
                    for line in f:
                        d = json.loads(line)
                        if d.get("role") == "user":
                            if marker in text_of((d.get("message") or {}).get("content")):
                                targets[cid] = (chat_dir, "marker")
                            break
            except Exception:
                pass
    touched = set()
    for cid, (chat_dir, why) in sorted(targets.items()):
        gone("cursor", f"chat {cid} ({why}) {chat_dir}", lambda d=chat_dir: rm(d))
        for tdir in glob.glob(os.path.join(projects, "*", "agent-transcripts", cid)):
            touched.add(os.path.dirname(os.path.dirname(tdir)))
            if not dry:
                rm(tdir)
        parent = os.path.dirname(chat_dir)
        if not dry and os.path.isdir(parent) and not os.listdir(parent):
            os.rmdir(parent)
    # A throwaway workdir's project dir (worker.log, .workspace-trusted, empty
    # agent-transcripts/) goes too — but only when its recorded workspacePath
    # proves it is that workdir, and no other chat transcripts remain in it.
    for w in workdirs:
        touched.add(os.path.join(projects, re.sub(r"[^A-Za-z0-9]+", "-", w).strip("-")))
    for pdir in sorted(touched):
        if not os.path.isdir(pdir):
            continue
        try:
            wp = str(json.load(open(os.path.join(pdir, ".workspace-trusted"))).get("workspacePath", "")).rstrip("/")
        except Exception:
            wp = None
        tdir = os.path.join(pdir, "agent-transcripts")
        left = os.listdir(tdir) if os.path.isdir(tdir) else []
        if dry:
            left = [x for x in left if x not in targets]
        if wp in workdirs and not left:
            gone("cursor", f"project dir {pdir} (workspacePath={wp})", lambda d=pdir: rm(d))

# ---------------- Codex ----------------
def codex_first_prompt(f):
    """Text of a rollout's FIRST real user prompt — only that is matched against
    the marker, never later turns: a real conversation started during a test
    run that later quotes the run's log must survive (review finding
    2026-09-22). Codex also writes injected context as role=user messages
    (<recommended_plugins>, <environment_context>, # AGENTS.md ...); the
    prompt itself is the first `user_message` / item_completed UserMessage
    event, with the first non-injected role=user message as a fallback."""
    fallback = None
    for n, line in enumerate(f):
        if n > 400:
            break
        try:
            q = json.loads(line).get("payload") or {}
        except Exception:
            continue
        if q.get("type") == "user_message":
            return str(q.get("message") or "")
        item = q.get("item") or {}
        if q.get("type") == "item_completed" and isinstance(item, dict) and item.get("type") == "UserMessage":
            return text_of(item.get("content"))
        if fallback is None and q.get("type") == "message" and q.get("role") == "user":
            t = text_of(q.get("content"))
            if not t.lstrip().startswith(("<", "# AGENTS.md")):
                fallback = t
    return fallback or ""

def codex():
    cands = {}   # thread id -> {"rollout": path or None, "why": str}
    sessions = os.path.join(CODEX, "sessions")
    for dirpath, _, files in os.walk(sessions):
        for fn in files:
            if not (fn.startswith("rollout-") and fn.endswith(".jsonl")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                if os.path.getmtime(path) < since:   # written after creation, so mtime >= created
                    continue
                with open(path) as f:
                    first = json.loads(f.readline())
                    p = first.get("payload") or {}
                    if first.get("type") != "session_meta" or not p.get("id"):
                        continue
                    created = iso_epoch(p.get("timestamp") or first.get("timestamp"))
                    if created is None or created < since:
                        continue
                    why = None
                    if str(p.get("cwd", "")).rstrip("/") in workdirs:
                        why = f"cwd={p.get('cwd')}"
                    elif marker in codex_first_prompt(f):
                        why = "marker"
                    if why:
                        cands[p["id"]] = {"rollout": path, "why": why}
            except Exception:
                continue
    # Thread rows whose rollout is already gone (or never scanned) — read-only.
    db = os.path.join(CODEX, "state_5.sqlite")
    if os.path.exists(db):
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            for tid, rp, cwd, fum in con.execute(
                    "SELECT id, rollout_path, cwd, first_user_message FROM threads WHERE created_at >= ?", (since,)):
                if tid in cands:
                    continue
                if str(cwd or "").rstrip("/") in workdirs:
                    cands[tid] = {"rollout": rp, "why": f"cwd={cwd}"}
                elif marker in (fum or ""):
                    cands[tid] = {"rollout": rp, "why": "marker"}
            con.close()
        except Exception as e:
            out("note", "codex", f"state_5.sqlite unreadable ({e}); rollout scan only")
    if not cands:
        return
    env = dict(os.environ, CODEX_HOME=CODEX)
    try:
        h = subprocess.run(["codex", "delete", "--help"], capture_output=True, text=True, timeout=30,
                           stdin=subprocess.DEVNULL, env=env)
        help_txt = h.stdout + h.stderr if h.returncode == 0 else ""
    except Exception:
        help_txt = ""
    has_delete = "delete" in help_txt.lower() and "session" in help_txt.lower()
    force = ["--force"] if "--force" in help_txt else []
    if not has_delete:
        out("note", "codex", "`codex delete` unavailable — removing rollout files only (state_5 thread rows may remain)")
    for tid, c in sorted(cands.items()):
        rp = c["rollout"]
        def do(tid=tid, rp=rp):
            if has_delete:
                r = subprocess.run(["codex", "delete", *force, tid], capture_output=True, text=True,
                                   timeout=60, stdin=subprocess.DEVNULL, env=env)
                if r.returncode != 0:
                    out("note", "codex", f"codex delete {tid} failed (exit {r.returncode}: {(r.stdout + r.stderr).strip()[:200]}) — removing rollout file")
            if rp and os.path.exists(rp):
                if has_delete:
                    out("note", "codex", f"rollout still present after codex delete — removing {rp}")
                os.remove(rp)
        gone("codex", f"thread {tid} ({c['why']}) {rp or ''}".rstrip(), do)

# ---------------- Claude ----------------
def claude():
    projects = os.path.join(CLAUDE, "projects")
    # Top-level transcripts only: <session>/subagents/** is never imported into T3
    # and belongs to a real parent session.
    for path in glob.glob(os.path.join(projects, "*", "*.jsonl")):
        try:
            if os.path.getmtime(path) < since:
                continue
            created, cwd, first_user = None, None, None
            with open(path) as f:
                for n, line in enumerate(f):
                    if n > 200:
                        break
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if created is None and d.get("timestamp"):
                        created = iso_epoch(d["timestamp"])
                    cwd = cwd or d.get("cwd")
                    if d.get("type") == "user" and not d.get("isMeta") and isinstance(d.get("message"), dict):
                        first_user = text_of(d["message"].get("content"))
                        break
            if created is None or created < since:
                continue
            if str(cwd or "").rstrip("/") in workdirs:
                why = f"cwd={cwd}"
            elif first_user is not None and marker in first_user:
                why = "marker"
            else:
                continue
            side = path[:-len(".jsonl")]
            def do(path=path, side=side):
                os.remove(path)
                if os.path.isdir(side):
                    shutil.rmtree(side)
                # A throwaway cwd's project dir holds nothing else but an empty
                # memory/ dir — drop it too; anything non-empty stays.
                parent = os.path.dirname(path)
                rest = [os.path.join(parent, x) for x in os.listdir(parent)]
                if all(os.path.isdir(x) and not os.path.islink(x) and not os.listdir(x) for x in rest):
                    for x in rest:
                        os.rmdir(x)
                    os.rmdir(parent)
            gone("claude", f"transcript {os.path.basename(side)} ({why}) {path}", do)
        except Exception as e:
            out("note", "claude", f"skipped {path}: {e}")
    # Even with --no-session-persistence, `claude -p` in a throwaway cwd creates
    # ~/.claude/projects/<enc(cwd)>/memory/ (empty) — 2026-09-22: routecheck's
    # haiku smoke left one per run. Drop a workdir's project dir only when it
    # holds no FILES at all (a transcript, or any memory note, keeps it) and was
    # touched at/after --since. <enc> = cwd with every non-alphanumeric -> '-'.
    for w in sorted(workdirs):
        pdir = os.path.join(projects, re.sub(r"[^A-Za-z0-9]", "-", w))
        if not os.path.isdir(pdir) or os.path.islink(pdir) or os.stat(pdir).st_mtime < since:
            continue
        if any(files for _, _, files in os.walk(pdir)):
            continue
        gone("claude", f"empty project dir {pdir} (cwd={w})", lambda d=pdir: shutil.rmtree(d))

for name, fn in (("cursor", cursor), ("codex", codex), ("claude", claude)):
    try:
        fn()
    except Exception as e:
        errors.append(f"{name}: {e!r}")
        out("note", name, f"INTERNAL ERROR: {e!r}")

verb = "would delete" if dry else "deleted"
print(f"test-chat-cleanup: {verb} cursor={counts['cursor']} codex={counts['codex']} claude={counts['claude']}"
      + (f"; errors: {'; '.join(errors)}" if errors else ""), file=sys.stderr)
sys.exit(2 if errors else 0)
PYEOF
