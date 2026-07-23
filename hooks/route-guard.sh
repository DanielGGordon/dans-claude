#!/usr/bin/env bash
# route-guard — PreToolUse(Bash) hook that makes model routing deterministic:
# raw `codex exec` / headless `cursor-agent` invocations and retired model ids
# are denied (structured permissionDecision JSON) and redirected to
# bin/model-run.sh. Read-only commands (status, --list-models, login, --version)
# pass through.
#
# Denies match COMMAND POSITION (start of command or after ; && || | & $( `),
# not substrings — so `grep 'codex exec' file` is fine, and a blessed-looking
# prefix cannot exempt a chained raw call (`true model-run.sh; codex exec ...`
# is denied). Fail-open on parse errors — never break unrelated Bash calls.
#
# The hook's stdin (the tool-call JSON) is captured into an env var BEFORE the
# heredoc: `python3 - <<EOF` consumes stdin for the script itself, so reading
# sys.stdin inside would get nothing and silently fail open.
ROUTE_GUARD_PAYLOAD=$(cat 2>/dev/null) || exit 0
export ROUTE_GUARD_PAYLOAD
python3 - <<'PYEOF'
import json, os, re, sys

def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)

try:
    cmd = json.loads(os.environ.get("ROUTE_GUARD_PAYLOAD", "")).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)
if not cmd:
    sys.exit(0)

# Deny decisions run against a STRIPPED view of the command: heredoc bodies
# and quoted strings are prose (commit messages, echoes, docs) and cannot
# execute — matching them raw caused false positives the moment a commit
# message quoted a chained invocation. `bash -c "..."` smuggling is caught
# separately on the raw string below.
stripped = re.sub(r"<<-?\s*'?\"?(\w+)['\"]?[^\n]*\n.*?\n\1(?=\s|$)", " ", cmd, flags=re.S)
stripped = re.sub(r"'[^']*'", "''", stripped)
stripped = re.sub(r'"(?:\\.|[^"\\])*"', '""', stripped)

# Retired ids in executable position (prose mentions survive via stripping).
RETIRED = {"grok-4.5-xhigh": "cursor-grok-4.5-high",
           "grok-4.5-fast-xhigh": "cursor-grok-4.5-high-fast"}
for old, new in RETIRED.items():
    if re.search(r"--model[= ]+" + re.escape(old) + r"\b", stripped):
        deny(f"Model id '{old}' is retired. Use: bash ~/dotfiles/claude/bin/model-run.sh {new} <promptfile>")

# Command-position matcher: start of string or after a shell separator,
# optionally preceded by env assignments / `command` / `exec` / `timeout N`.
PREFIX = r"(?:^|[;&|]\s*|\$\(\s*|`\s*)(?:\S+=\S+\s+|command\s+|exec\s+|timeout\s+\S+\s+|nice\s+|env\s+)*"
codex_raw  = re.search(PREFIX + r"(?:\S*/)?codex\s+(?:[-\w]+\s+)*exec\b", stripped)
cursor_seg = re.search(PREFIX + r"(?:\S*/)?cursor-agent\b([^;&|]*)", stripped)
cursor_raw = bool(cursor_seg) and bool(re.search(r"(?:^|\s)(--print|-p)(?:\s|$)", cursor_seg.group(1)))

# Quoted-string smuggling: `bash -c "codex exec ..."` executes its quoted arg.
shell_c = re.search(r"\b(?:ba|z|da)?sh\s+(?:-\S+\s+)*-c\s+(['\"]).*?(codex\s+exec|cursor-agent[^'\"]*(?:--print|\s-p\s))", cmd)

if codex_raw or cursor_raw or shell_c:
    deny("Don't hand-roll codex/cursor-agent invocations — flags and ids drift. "
         "Use the single entrypoint: bash ~/dotfiles/claude/bin/model-run.sh "
         "<model-id>|--task-type <type> <promptfile> [workdir] (see ~/.claude/model-usage.md; "
         "spawn the 'model-runner' agent for delegations). "
         "If you genuinely need a raw invocation, ask the user first.")

sys.exit(0)
PYEOF
exit 0
