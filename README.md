# dans-claude

Personal Claude Code global config — hooks, agents, and utilities.

## Install

```bash
# 1. Back up any existing config
mv ~/.claude ~/.claude.bak

# 2. Clone into ~/.claude
git clone git@github.com:DanielGGordon/dans-claude.git ~/.claude

# 3. Restore any runtime state from your backup (optional)
cp -r ~/.claude.bak/projects ~/.claude/projects 2>/dev/null
cp -r ~/.claude.bak/sessions ~/.claude/sessions 2>/dev/null
cp ~/.claude.bak/history.jsonl ~/.claude/history.jsonl 2>/dev/null

# 4. Restart Claude Code (quit with /exit or Ctrl+C, then run `claude` again)
```

Claude Code reads `~/.claude/settings.json` on startup — no daemon or background process to restart.

> **Why clone directly?** Claude Code expects config at `~/.claude/`. The `.gitignore` excludes all runtime state (`projects/`, `sessions/`, `plans/`, `history.jsonl`, etc.) so auto-generated files won't pollute your git status.

## Update

```bash
cd ~/.claude && git pull
```

Then restart Claude Code to pick up changes.

## What's included

```
~/.claude/
├── .gitignore               # Excludes CC runtime dirs (projects/, sessions/, plans/, etc.)
├── settings.json            # Global config: hooks, statusline, model, plugins
├── plan-requirements.md     # Requirements the plan reviewer enforces
├── agents/
│   └── plan-reviewer.md     # Reusable named agent for plan review
└── statusline-command.sh    # Custom status bar (called by settings.json statusLine)
```

Hooks are registered as `type: "agent"` entries in `settings.json` — no separate `hooks/` directory needed. Command-based hooks that need shell scripts would go in a `hooks/` directory.

## Plan Review Hook

A `PreToolUse` agent hook on `ExitPlanMode` fires automatically when Claude finishes a plan and tries to exit plan mode. It spins up a **fresh subagent** with only the plan and requirements in context (no conversation history) and blocks plan approval if any requirement is unmet.

The subagent reads the plan file and `plan-requirements.md` using its own tool calls, then returns `{"ok": true}` or `{"ok": false, "reason": "..."}`. On rejection, Claude sees the feedback, revises the plan, and tries again.

**Requirements enforced:**

1. Testing strategy with named framework(s) and test types
2. System tools and external dependencies enumerated (browser automation, cloud accounts, CLI tools, etc.)
3. Fully automated test runs — any human steps must be explicitly labeled
4. Agent-loop compatible task lists (discrete, unambiguous, completion-criterioned)
5. Parallel tasks explicitly marked
6. Full lifecycle coverage: setup → development → testing → deployment

**To edit requirements:** modify `plan-requirements.md` and commit.

## Named Agents

Agents live in `~/.claude/agents/` as markdown files with YAML frontmatter. Claude can pick them up automatically based on the `description` field, or you can invoke them explicitly.

### `agents/plan-reviewer.md`

The plan reviewer as a standalone named agent. While the hook runs it automatically on plan exit, you can also invoke it directly at any time:

```
Use the plan-reviewer agent to check plan.md
```

This is useful for reviewing a plan mid-conversation without waiting for `ExitPlanMode`, or for re-checking after manual edits.

### Adding a new agent

Create a markdown file in `agents/` with frontmatter:

```yaml
---
name: my-agent
description: When Claude should use this agent
tools: Read, Bash, WebFetch
model: sonnet
---

System prompt goes here.
```

## Adding a new hook

Register hooks in `settings.json` under the appropriate event.

**Agent hook** (subagent with tool access, returns `{"ok": true/false}`):

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "ToolName",
      "hooks": [{ "type": "agent", "prompt": "Your instructions. Hook data: $ARGUMENTS", "timeout": 60 }]
    }
  ]
}
```

**Command hook** (shell script, exit `0` to allow, exit `2` to block):

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

## .gitignore

The `.gitignore` excludes everything Claude Code generates at runtime:

| Excluded | Why |
|----------|-----|
| `projects/`, `sessions/`, `plans/` | Auto-memory, session history, plan drafts |
| `cache/`, `paste-cache/`, `backups/` | Temp data |
| `history.jsonl`, `file-history/` | Conversation and file edit history |
| `telemetry/`, `debug/`, `shell-snapshots/` | Diagnostics |
| `settings.local.json` | Per-machine overrides (not portable) |

Only tracked files (`settings.json`, `agents/`, `plan-requirements.md`, `statusline-command.sh`) are committed.

## Notes

- `statusline-command.sh` uses Python for JSON parsing — no `jq` dependency required.
- `settings.json` contains a machine-specific path for the statusline command. Update it after cloning if your home directory differs.
- `settings.local.json` (gitignored) is for per-machine overrides like project-specific permissions.
