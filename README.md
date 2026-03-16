# dans-claude

Personal Claude Code config — hooks, agents, and utilities. Designed to live alongside CC's own `~/.claude/` without interfering with its runtime state.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/dotfiles/claude
bash ~/dotfiles/claude/install.sh
```

The install script:
1. Symlinks `CLAUDE.md`, `agents/`, `plan-requirements.md`, and `statusline-command.sh` into `~/.claude/`
2. Deep-merges `settings.partial.json` into your existing `~/.claude/settings.json` (preserves CC-managed keys like model, permissions, plugins)
3. Backs up any existing files before overwriting

Then restart Claude Code (`/exit` or Ctrl+C, then run `claude`).

## Update

```bash
cd ~/dotfiles/claude && git pull
```

Symlinked files take effect immediately. If `settings.partial.json` changed, re-run `install.sh` to merge.

## Structure

```
~/dotfiles/claude/
├── install.sh               # Sets up symlinks + merges settings
├── CLAUDE.md                # Global instructions (symlinked to ~/.claude/CLAUDE.md)
├── settings.partial.json    # Hook and statusline config (merged into settings.json)
├── plan-requirements.md     # Requirements the plan reviewer enforces
├── agents/
│   └── plan-reviewer.md     # Reusable named agent for plan review
├── statusline-command.sh    # Color status bar: dir | model | context + tokens | cost
└── README.md
```

After install, `~/.claude/` looks like:

```
~/.claude/
├── settings.json              ← CC-managed, with your hooks merged in
├── CLAUDE.md → ~/dotfiles/claude/CLAUDE.md
├── agents/ → ~/dotfiles/claude/agents/
├── plan-requirements.md → ~/dotfiles/claude/plan-requirements.md
├── statusline-command.sh → ~/dotfiles/claude/statusline-command.sh
├── projects/                  ← CC runtime (untouched)
├── sessions/                  ← CC runtime (untouched)
└── ...
```

## Plan Review Hook

A `PreToolUse` agent hook on `ExitPlanMode` fires automatically when Claude finishes a plan. It spins up a fresh subagent with only the plan and requirements in context (no conversation history) and blocks plan approval if requirements are unmet.

The subagent reads the plan file and `plan-requirements.md` using its own tool calls, then returns `{"ok": true}` or `{"ok": false, "reason": "..."}`. On rejection, Claude sees the feedback, revises, and tries again.

**Requirements enforced:**

1. Testing strategy with named framework(s) and test types
2. System tools and external dependencies enumerated
3. Fully automated test runs — human steps explicitly labeled
4. Agent-loop compatible task lists
5. Parallel tasks marked
6. Full lifecycle coverage: setup → development → testing → deployment

**To edit requirements:** modify `plan-requirements.md` and commit.

## Named Agents

### `agents/plan-reviewer.md`

The plan reviewer as a standalone named agent. While the hook runs it automatically on plan exit, you can also invoke it directly:

```
Use the plan-reviewer agent to check plan.md
```

### Adding a new agent

Create a markdown file in `agents/`:

```yaml
---
name: my-agent
description: When Claude should use this agent
tools: Read, Bash, WebFetch
model: sonnet
---

System prompt here.
```

## Adding a new hook

Add entries to `settings.partial.json` and re-run `install.sh`:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "ToolName",
      "hooks": [{ "type": "agent", "prompt": "Instructions. Data: $ARGUMENTS", "timeout": 60 }]
    }
  ]
}
```

## Notes

- `statusline-command.sh` uses Python for JSON parsing (no `jq` dependency). Displays: 📁 directory, 🌿 git branch, 🧠 model, context bar (color shifts green→yellow→red, capped at 200k), input/output tokens, 💰 session cost, 🌲 worktree, 🤖 agent name.
- `settings.partial.json` is deep-merged — it won't overwrite CC-managed keys like `model` or `permissions` unless you add them to the partial.
- Per-machine overrides go in `~/.claude/settings.local.json` (CC-managed, not tracked here).
