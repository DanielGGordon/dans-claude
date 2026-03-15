# dans-claude

Personal Claude Code global config — hooks, settings, and utilities.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/.claude
chmod +x ~/.claude/hooks/*.sh
```

> **Note:** If you already have a `~/.claude` directory, back it up first:
> `mv ~/.claude ~/.claude.bak`

## Hooks

Hooks live in `~/.claude/hooks/` and are registered in `settings.json`.

### `hooks/review-plan.sh`

Fires automatically before Claude exits plan mode (`ExitPlanMode`). Spins up a
fresh Claude agent with only the plan and requirements in context — no
conversation history — and blocks plan approval if any requirement is unmet.

Requirements are defined in `plan-requirements.md`. Claude will be asked to
revise and resubmit until all requirements pass.

**Requirements enforced:**

1. Testing strategy with named framework(s) and test types
2. System tools and external dependencies enumerated (browser automation, cloud accounts, CLI tools, etc.)
3. Fully automated test runs — any human steps must be explicitly labeled
4. Agent-loop compatible task lists (discrete, unambiguous, completion-criterioned)
5. Parallel tasks explicitly marked
6. Full lifecycle coverage: setup → development → testing → deployment

**To edit requirements:** modify `plan-requirements.md` and commit.

### Adding a new hook

1. Add your script to `hooks/`
2. Register it in `settings.json` under the appropriate event (`PreToolUse`, `PostToolUse`, `Stop`, etc.)
3. Commit both files

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "ToolName",
      "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/your-hook.sh", "timeout": 60 }]
    }
  ]
}
```

Hook scripts receive a JSON payload on stdin. Exit `0` to allow, exit `2` with a message on stderr to block and send feedback to Claude.
