# dans-claude

Personal Claude Code global config — hooks, agents, and utilities.

## Install

```bash
# Back up any existing config
mv ~/.claude ~/.claude.bak

# Clone
git clone git@github.com:DanielGGordon/dans-claude.git ~/.claude
```

After cloning, restart Claude Code. It reads `~/.claude/settings.json` automatically on every session.

## What's included

```
~/.claude/
├── settings.json            # Global settings (hooks, statusline, model, plugins)
├── plan-requirements.md     # Requirements the plan reviewer enforces
├── agents/
│   └── plan-reviewer.md     # Reusable named agent for plan review
└── statusline-command.sh    # Custom status bar: user@host:dir | model | context%
```

## Plan Review Hook

A `PreToolUse` agent hook fires automatically before Claude exits plan mode (`ExitPlanMode`). It spins up a fresh subagent with **only** the plan and requirements in context — no conversation history — and blocks plan approval if any requirement is unmet.

The hook is registered in `settings.json` as `type: "agent"`. The subagent reads the plan file and `plan-requirements.md` using its own tool calls, then returns `{"ok": true}` or `{"ok": false, "reason": "..."}`.

**Requirements enforced:**

1. Testing strategy with named framework(s) and test types
2. System tools and external dependencies enumerated (browser automation, cloud accounts, CLI tools, etc.)
3. Fully automated test runs — any human steps must be explicitly labeled
4. Agent-loop compatible task lists (discrete, unambiguous, completion-criterioned)
5. Parallel tasks explicitly marked
6. Full lifecycle coverage: setup → development → testing → deployment

**To edit requirements:** modify `plan-requirements.md` and commit.

## Named Agents

Agents live in `~/.claude/agents/` as markdown files with YAML frontmatter.

### `agents/plan-reviewer.md`

The same plan reviewer, defined as a reusable named agent. Claude can invoke it automatically based on the description, or you can ask explicitly:

```
Use the plan-reviewer agent to check plan.md
```

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

## Notes

- `statusline-command.sh` uses Python for JSON parsing (no `jq` dependency).
- `settings.json` may contain machine-specific paths (e.g., the statusline command path). Update after cloning if needed.
