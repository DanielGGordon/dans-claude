# dans-claude

Personal Claude Code config — hooks, agents, and utilities. Designed to live alongside CC's own `~/.claude/` without interfering with its runtime state.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/dotfiles/claude
bash ~/dotfiles/claude/install.sh
```

The install script:
1. Symlinks `CLAUDE.md`, `CODING_AGENTS.md`, `agents/`, `hooks/`, `skills/`, `plan-requirements.md`, and `statusline-command.sh` into `~/.claude/`
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
├── CODING_AGENTS.md         # Coding agent rules (symlinked to ~/.claude/CODING_AGENTS.md)
├── settings.partial.json    # Hook and statusline config (merged into settings.json)
├── plan-requirements.md     # Requirements the plan reviewer enforces
├── agents/
│   └── plan-reviewer.md     # Reusable named agent for plan review
├── hooks/
│   └── plan-review-stop.sh  # Stop hook: auto-review plan before Claude proceeds
├── skills/
│   └── ralph/
│       └── SKILL.md         # Ralph loop: execute plans task-by-task with context reset
├── statusline-command.sh    # Color status bar: dir | model | context + tokens | cost
└── README.md
```

After install, `~/.claude/` looks like:

```
~/.claude/
├── settings.json              ← CC-managed, with your hooks merged in
├── CLAUDE.md → ~/dotfiles/claude/CLAUDE.md
├── CODING_AGENTS.md → ~/dotfiles/claude/CODING_AGENTS.md
├── agents/ → ~/dotfiles/claude/agents/
├── hooks/ → ~/dotfiles/claude/hooks/
├── skills/ → ~/dotfiles/claude/skills/
├── plan-requirements.md → ~/dotfiles/claude/plan-requirements.md
├── statusline-command.sh → ~/dotfiles/claude/statusline-command.sh
├── projects/                  ← CC runtime (untouched)
├── sessions/                  ← CC runtime (untouched)
└── ...
```

## Plan Review Hook

A `Stop` command hook runs automatically when Claude finishes a turn. It detects plans via two paths:

1. **Plan mode** (`permission_mode == "plan"`): reads the plan directly from `last_assistant_message` in the hook input — no file on disk needed. This fires right when Claude finishes writing the plan, before you're asked to confirm exiting plan mode.
2. **File fallback**: if `plan.md` or `PLAN.md` in the working directory was modified within the last 120 seconds, reads the plan from that file.

Non-plan turns short-circuit fast. The hook runs a Python-based review against `plan-requirements.md` and blocks Claude (exit 2 + stderr feedback) if requirements are unmet. It checks `stop_hook_active` to prevent infinite review loops (only blocks once per stop).

**Requirements enforced:**

1. Testing strategy with named framework(s) and test types
2. System tools and external dependencies enumerated
3. Fully automated test runs — human steps explicitly labeled
4. Agent-loop compatible task lists
5. Parallel tasks marked
6. Full lifecycle coverage: setup → development → testing → deployment

**To edit requirements:** modify `plan-requirements.md` and commit.
**To edit review logic:** modify `hooks/plan-review-stop.sh` and commit.

## Named Agents

### `agents/plan-reviewer.md`

The plan reviewer as a standalone named agent. While the hook runs it automatically on plan exit, you can also invoke it directly:

```
Use the plan-reviewer agent to check plan.md
```

## Skills

### `skills/ralph.md` — Ralph Loop

Executes a plan file task-by-task, dispatching each task to a fresh subagent so context resets between tasks. The plan file on disk is the shared state.

```
/ralph                          # auto-finds plan.md or checks ~/.claude/plans/
/ralph path/to/my-plan.md      # explicit plan path
```

**What it does:**
1. Finds and reads the plan file
2. Adds `- [ ]` checkboxes to tasks if they don't exist (converts tables to checkbox lists)
3. Pre-loads plan context and `CODING_AGENTS.md` once, injecting them into every subagent (avoids redundant re-reads)
4. Prints ASCII Ralph Wiggum, then shows each task with a 15-second countdown before executing
5. Launches a subagent per task (fresh context, no history bleed)
6. Subagent checks off the task (`- [x]`) when the completion criterion is met
7. Respects parallel/sequential markers in the plan — offers to run parallel tasks concurrently

**Stopping and resuming:** Ctrl+C or tell it to stop. Next time you run `/ralph`, it picks up from the first unchecked task.

### Adding a new skill

Create a subdirectory in `skills/` with a `SKILL.md` file containing `user_invocable: true` in frontmatter (e.g., `skills/my-skill/SKILL.md`).

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
