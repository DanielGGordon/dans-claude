#!/usr/bin/env bash
# route-guard — PreToolUse(Bash) hook that makes model routing deterministic:
# raw `codex exec` / headless `cursor-agent` invocations are blocked and
# redirected to bin/model-run.sh, and retired model ids are blocked outright.
# Read-only commands (status, --list-models, --version, login) pass through.
# Exit 2 blocks the tool call; stderr is shown to the model. Always exit 0 on
# parse failure — never break unrelated Bash calls.

cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# The blessed paths themselves (and the test suite) pass through.
case "$cmd" in
  *model-run.sh*|*routecheck*) exit 0 ;;
esac

if printf '%s' "$cmd" | grep -q 'grok-4\.5-xhigh'; then
  echo "BLOCKED by route-guard: model id 'grok-4.5-xhigh' is retired. Use: bash ~/dotfiles/claude/bin/model-run.sh cursor-grok-4.5-high <promptfile>" >&2
  exit 2
fi

if printf '%s' "$cmd" | grep -qE 'codex exec|cursor-agent[^|;&]*(--print|-p )'; then
  echo "BLOCKED by route-guard: don't hand-roll codex/cursor-agent invocations — flags and ids drift. Use the single entrypoint: bash ~/dotfiles/claude/bin/model-run.sh <model-id> <promptfile> [workdir]  (see ~/.claude/model-usage.md; spawn the 'model-runner' agent for delegations). If you genuinely need a raw invocation, ask the user first." >&2
  exit 2
fi

exit 0
