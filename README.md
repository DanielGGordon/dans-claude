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
3. Adds `source ~/dotfiles/claude/aliases.sh` to `~/.bash_aliases` (creates the file if needed)
4. Backs up any existing files before overwriting

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
│   ├── ralph/
│   │   └── SKILL.md         # Ralph loop: execute plans task-by-task with context reset
│   ├── ralph-codex/
│   │   └── SKILL.md         # Ralph-Codex: execute plans with OpenAI Codex CLI in one shot
│   ├── review-plan/
│   │   └── SKILL.md         # On-demand plan review and auto-fix
│   ├── write-a-prd/
│   │   └── SKILL.md         # Create a PRD through interview and design
│   ├── prd-to-plan/
│   │   └── SKILL.md         # Break a PRD into tracer-bullet phases
│   ├── grill-me/
│   │   └── SKILL.md         # Interview relentlessly about a plan
│   ├── excalidraw-diagram/  # Excalidraw diagram generation (cloned from GitHub)
│   │   ├── SKILL.md         # Diagram design methodology + workflow
│   │   └── references/      # Renderer, templates, color palette
│   └── tdd/
│       ├── SKILL.md         # Test-driven development workflow
│       ├── deep-modules.md  # Designing deep modules for testability
│       ├── interface-design.md  # API design for testability
│       ├── mocking.md       # Mocking guidelines
│       ├── refactoring.md   # Refactoring checklist
│       └── tests.md         # Test examples
├── aliases.sh               # Shell aliases sourced from ~/.bash_aliases
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

A `Stop` command hook runs automatically when Claude finishes a turn. It looks for the most recently modified plan file (within 120 seconds) in two locations:

1. **`~/.claude/plans/*.md`** — where Claude Code writes plans during plan mode
2. **`plan.md` / `PLAN.md` in the working directory** — for manually created plan files

If no recently modified plan file is found, the hook exits immediately (fast path). When a plan file is found, it runs a Python-based review against `plan-requirements.md` and blocks Claude (exit 2 + stderr feedback) if requirements are unmet. It checks `stop_hook_active` to prevent infinite review loops (only blocks once per stop).

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

### Planning & Design

- **`skills/write-a-prd`** — Create a PRD through user interview, codebase exploration, and module design, then submit as a GitHub issue.
  ```
  /write-a-prd
  ```

- **`skills/prd-to-plan`** — Break a PRD into a phased implementation plan using vertical slices (tracer bullets), saved as a Markdown file in `./plans/`.
  ```
  /prd-to-plan
  ```

- **`skills/grill-me`** — Interview you relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree.
  ```
  /grill-me
  ```

### Diagrams

- **`skills/excalidraw-diagram`** — Generate Excalidraw diagrams as `.excalidraw` JSON files and render them to PNG using headless Chromium. Cloned from [coleam00/excalidraw-diagram-skill](https://github.com/coleam00/excalidraw-diagram-skill). Requires `uv` and Playwright+Chromium (installed automatically by `install.sh` if `uv` is present).
  ```
  /excalidraw-diagram
  ```

### Development

- **`skills/tdd`** — Test-driven development with red-green-refactor loop. Builds features or fixes bugs one vertical slice at a time.
  ```
  /tdd
  ```

### Execution & Review

- **`skills/ralph`** — Ralph Loop: executes a plan file task-by-task, dispatching each task to a fresh subagent so context resets between tasks.
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
  8. Respects `<!-- BATCH -->` markers — sends all consecutive unchecked tasks after the marker to a single subagent

  **Stopping and resuming:** Ctrl+C or tell it to stop. Next time you run `/ralph`, it picks up from the first unchecked task.

- **`skills/ralph-codex`** — Ralph-Codex: executes a plan file using OpenAI Codex CLI in a single automated shot. Codex reads the plan, executes the next unchecked task, and checks it off — with full permissions and zero user interaction.
  ```
  /ralph-codex                       # auto-finds plan.md or checks ~/.claude/plans/
  /ralph-codex path/to/my-plan.md   # explicit plan path
  ```
  **What it does:**
  1. Finds and reads the plan file
  2. Adds `- [ ]` checkboxes to tasks if they don't exist (converts tables to checkbox lists)
  3. Pre-loads plan context and `CODING_AGENTS.md`, embedding them in the codex prompt
  4. Builds a comprehensive prompt with all plan context, coding standards, and working directory
  5. Calls `codex exec --full-auto --dangerously-bypass-approvals-and-sandbox` with full permissions
  6. Codex executes the next unchecked task and checks it off (`- [x]`) when complete
  7. Reports task completion and repeats for the next unchecked task

  **When to use it:** For linear, independent tasks where you want pure automation without user interaction or approval windows. Codex operates in a single execution context, so all plan context is visible at once — useful for interdependent tasks but less transparent than ralph's step-by-step progress.

  **Stopping and resuming:** Same as `/ralph` — the plan file on disk is the source of truth. Run `/ralph-codex` again to pick up from the first unchecked task.

- **`skills/review-plan`** — Plan Review & Auto-Fix: on-demand plan review that finds the active plan, runs the `plan-reviewer` agent against `plan-requirements.md`, and automatically edits the plan to fix any issues.
  ```
  /review-plan                    # auto-finds plan in ~/.claude/plans/ or CWD
  ```
  **What it does:**
  1. Finds the active plan file (most recent in `~/.claude/plans/*.md`, or `plan.md`/`PLAN.md` in CWD)
  2. Launches the `plan-reviewer` agent to validate against requirements
  3. If the plan passes, reports success and stops
  4. If the plan fails, reads the reviewer feedback and edits the plan to address every issue
  5. Re-runs the reviewer to confirm fixes landed
  6. If still failing, makes one more revision pass (max 2 rounds), then reports any remaining issues

  **When to use it:** Mid-planning when you want to check your plan without exiting plan mode. The Stop hook reviews automatically on exit; this skill lets you review on demand at any point.

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

- `statusline-command.sh` uses Python for JSON parsing (no `jq` dependency). Displays: 📁 directory, 🌿 git branch, model + effort level (🔥 high / ⚡ medium / 🧊 low), true-color gradient context bar (green→yellow→red, fully red at 70%, capped at 200k), input/output tokens, 💰 session cost, 🌲 worktree, 🤖 agent name, 📡 remote control. Requires true-color (24-bit) terminal support.
- `settings.partial.json` is deep-merged — it won't overwrite CC-managed keys like `model` or `permissions` unless you add them to the partial.
- Per-machine overrides go in `~/.claude/settings.local.json` (CC-managed, not tracked here).
