# dans-claude

Personal Claude Code config — hooks, agents, and utilities. Designed to live alongside CC's own `~/.claude/` without interfering with its runtime state.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/dotfiles/claude
bash ~/dotfiles/claude/install.sh
```

The install script:
1. Symlinks `CLAUDE.md`, `CODING_AGENTS.md`, `agents/`, `hooks/`, `skills/`, `plan-requirements.md`, `android.md`, `models.md`, `playwright.md`, and `statusline-command.sh` into `~/.claude/`
2. Deep-merges `settings.partial.json` into your existing `~/.claude/settings.json` (preserves CC-managed keys like model, permissions, plugins)
3. Registers user-scoped MCP servers via `claude mcp add` (idempotent; skipped if the server binary isn't on this machine)
4. Adds `source ~/dotfiles/claude/aliases.sh` to `~/.bash_aliases` (creates the file if needed)
5. Backs up any existing files before overwriting

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
├── android.md               # System-wide Android deployment reference (symlinked to ~/.claude/android.md)
├── models.md                # Model strategy & delegation reference — raw `codex exec` wrapper pattern (gpt-5.5/5.6), Cursor CLI for composer-2.5, grok-4.5 via OpenAI-compatible API, + native Claude model routing for subagents/workflows (symlinked to ~/.claude/models.md)
├── playwright.md            # Playwright visual web-testing reference — screenshot toolkit + how agents visually evaluate UIs, used only when the user asks to "test visually" (symlinked to ~/.claude/playwright.md)
├── agents/
│   └── plan-reviewer.md     # Reusable named agent for plan review
├── hooks/
│   └── second-brain-ingest-session-end.sh  # SessionEnd → second-brain quick ingest
├── skills/
│   ├── ralph-v2/
│   │   ├── ralph.py         # Phase-level build/evaluate harness (generator + evaluator + rescue)
│   │   ├── launcher.py      # Entry point / arg parsing
│   │   ├── runner.py        # Per-phase execution loop
│   │   ├── evaluator.py     # Tests phase output against acceptance criteria
│   │   ├── recovery.py      # Rescues stuck phases after timeout
│   │   ├── parallel.py      # Parallel phase execution across worktrees
│   │   ├── plan.py          # Plan parsing (phases + acceptance criteria)
│   │   ├── prompt.py        # Prompt building
│   │   ├── models.py        # Shared dataclasses/constants
│   │   └── tui.py           # Textual TUI (live progress + guidance input)
│   ├── review-plan/
│   │   └── SKILL.md         # On-demand plan review and auto-fix
│   ├── write-a-prd/
│   │   └── SKILL.md         # Create a PRD through interview and design
│   ├── prd-to-plan/
│   │   └── SKILL.md         # Break a PRD into tracer-bullet phases
│   ├── grill-me/
│   │   └── SKILL.md         # Interview relentlessly about a plan
│   ├── redeploy/
│   │   ├── SKILL.md         # Redeploy self-hosted T3 Code prod to origin/main
│   │   └── redeploy.sh      # Sync deploy dir to origin/main, build, detached restart
│   ├── forky/
│   │   └── SKILL.md         # Mark a fork point for later rollback
│   ├── rollback-with-update/
│   │   └── SKILL.md         # Commit, summarize, and rewind to fork point
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
├── tests/
│   └── test_ralph_v2.py     # Tests for ralph-v2
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
├── android.md → ~/dotfiles/claude/android.md
├── models.md → ~/dotfiles/claude/models.md
├── playwright.md → ~/dotfiles/claude/playwright.md
├── statusline-command.sh → ~/dotfiles/claude/statusline-command.sh
├── projects/                  ← CC runtime (untouched)
├── sessions/                  ← CC runtime (untouched)
└── ...
```

## Named Agents

### `agents/plan-reviewer.md`

The plan reviewer as a standalone named agent (validates against `plan-requirements.md`). Invoke it directly:

```
Use the plan-reviewer agent to check plan.md
```

## Skills

### Planning & Design

- **`skills/write-a-prd`** — Create a PRD through user interview, codebase exploration, and module design, then submit as a GitHub issue.
  ```
  /write-a-prd
  ```

- **`skills/prd-to-plan`** — Break a PRD into a phased implementation plan using vertical slices (tracer bullets), saved as a Markdown file in `./plans/`. After writing, automatically validates the plan via the `plan-reviewer` agent and revises it (up to 2 rounds) before returning control to the user.
  ```
  /prd-to-plan
  ```

- **`skills/grill-me`** — Interview you relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree.
  ```
  /grill-me
  ```

### Ops

- **`skills/redeploy`** — Redeploy the self-hosted T3 Code prod server (`15.204.108.12:7443`) to the latest `origin/main`. Runs `redeploy.sh`: syncs the deploy checkout (`~/projects/meta/t3code-v2`) to a detached copy of `origin/main`, `pnpm install` + `pnpm build`, then fires a **detached** `systemctl --user restart t3code.service` and writes a health report to `/tmp/t3-redeploy-status.log`. Only runs on the T3 deploy host (guards on the deploy dir + user service). Note: the invoking chat lives inside `t3code.service`, so **its own session drops on restart** — that's expected; reconnect and read the log.
  ```
  /redeploy
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

### Workflow

- **`skills/forky`** — Mark a fork point in the conversation by writing a breadcrumb file (`.claude/fork-point.json`). Pair with `/rollback-with-update` to rewind later.
  ```
  /forky
  ```

- **`skills/rollback-with-update`** — Commit and push current work, generate a handoff summary, then rewind the conversation to the fork point set by `/forky`. Returns the session to the pre-feature baseline with context about what was done.
  ```
  /rollback-with-update
  ```
  **Workflow:**
  1. Run `/forky` before starting a feature — marks the conversation fork point
  2. Do your work
  3. Run `/rollback-with-update` — commits, pushes, writes `.claude/handoff-summary.md`, then guides you through `/rewind` back to the fork point with the summary injected

  **Files:**
  | File | Purpose | Committed? |
  |------|---------|------------|
  | `.claude/fork-point.json` | Breadcrumb written by `/forky`, read and deleted by `/rollback-with-update` | No |
  | `.claude/handoff-summary.md` | Handoff summary for the next agent | Yes |

### Execution & Review

- **`skills/ralph-v2`** — Ralph v2: a phase-level build/evaluate harness. Unlike the old task-by-task loop, each **phase** gets one generator invocation (implements the whole phase) followed by an evaluator that tests the output against the phase's acceptance criteria, retrying up to `--max-eval-rounds` times. A rescue agent recovers phases that stall past `--task-timeout`. The plan file and a learnings file are the shared state across phases. Plans produced by `prd-to-plan` are written in exactly this format (`## Phase N` + `**Delivers**` + `**Acceptance criteria**`); v2 also parses old `- [ ]` checkbox plans for backward compatibility.
  ```
  python3 ~/dotfiles/claude/skills/ralph-v2/ralph.py            # auto-finds plan.md or ~/.claude/plans/
  python3 ~/dotfiles/claude/skills/ralph-v2/ralph.py plan.md    # explicit plan path
  ```
  **Three-agent system:**
  1. **Generator** — implements the full phase autonomously
  2. **Evaluator** — tests output against acceptance criteria (Playwright, pytest, etc.); loops the generator until criteria pass or `--max-eval-rounds` is hit
  3. **Rescue** — recovers a stuck phase after `--task-timeout`

  **Useful flags:** `--phase N` (run a single phase), `--no-eval` (skip evaluation), `--parallel` worktree execution across independent phases (`<!-- PARALLEL N,M -->`), `--model` / `--reviewer-model`, `--learnings-path`, `--restart`. TUI mode shows live progress and lets you type guidance queued for the next phase.

  **Stopping and resuming:** The plan file on disk is the source of truth — re-run to pick up from the first incomplete phase.

  > Note: ralph-v2 currently ships as Python modules with **no `SKILL.md`**, so there is no `/ralph-v2` slash command yet — invoke it via `python3` as shown above.

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

  **When to use it:** Any time you want to validate a plan — mid-planning or before execution. Plan review is on-demand only (via this skill or the `plan-reviewer` agent); nothing runs automatically.

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

## Hooks

### `hooks/second-brain-ingest-session-end.sh`

SessionEnd hook that triggers a **second-brain quick ingest** so the just-ended session becomes searchable within seconds. Reads the port and token from `~/.second-brain/config.json` (jq if available, python3 fallback) and POSTs to `http://127.0.0.1:$PORT/api/ingest` with a 5s timeout. Fails silently — always exits 0, whether the config is missing or the service is down — so session exit is never noisy or slow. Registered under `SessionEnd` in `settings.partial.json`.

### Adding a new hook

Put the script in `hooks/` (symlinked to `~/.claude/hooks/`), make it executable, register it in `settings.partial.json`, and re-run `install.sh`:

```json
"hooks": {
  "SessionEnd": [
    {
      "matcher": "",
      "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/my-hook.sh" }]
    }
  ]
}
```

## MCP servers

User-scoped MCP servers live in `~/.claude.json`, which is CC-managed — the settings merge can't touch it. So `install.sh` registers them with `claude mcp add --scope user`, guarded by `claude mcp get` to stay idempotent, and skips servers whose binary doesn't exist on the machine.

- **`brain`** — second-brain semantic memory (stdio server at `~/projects/meta/second-brain/bin/brain-mcp`). Loads into new Claude Code sessions after restart.

To add another server, copy the `brain` block in `install.sh`'s MCP section.

## Notes

- `statusline-command.sh` uses Python for JSON parsing (no `jq` dependency). Displays: 📁 directory, 🌿 git branch, model + effort level (🔥 high / ⚡ medium / 🧊 low), true-color gradient context bar (green→yellow→red, fully red at 70%, capped at 200k), input/output tokens, 💰 session cost, 🌲 worktree, 🤖 agent name, 📡 remote control. Requires true-color (24-bit) terminal support.
- `settings.partial.json` is deep-merged — it won't overwrite CC-managed keys like `model` or `permissions` unless you add them to the partial.
- Per-machine overrides go in `~/.claude/settings.local.json` (CC-managed, not tracked here).
