# dans-claude

Personal Claude Code config — hooks, agents, and utilities. Designed to live alongside CC's own `~/.claude/` without interfering with its runtime state.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/dotfiles/claude
bash ~/dotfiles/claude/install.sh
```

The install script:
1. Symlinks `CLAUDE.md`, `CODING_AGENTS.md`, `agents/`, `hooks/`, `skills/`, `plan-requirements.md`, `android.md`, `models.md`, `model-selection.md`, `model-usage.md`, `playwright.md`, and `statusline-command.sh` into `~/.claude/`
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
├── android.md               # System-wide Android deployment + automated-testing reference — canonical emulator/test layer is the android-framework repo (symlinked to ~/.claude/android.md)
├── model-selection.md       # WHICH model to use WHEN — rankings table, task-type guidance, subagent/workflow model assignment (symlinked to ~/.claude/model-selection.md)
├── model-usage.md           # HOW to invoke a chosen model — `codex exec` + `cursor-agent` wrapper patterns, native Claude routing, current model ids, auth/error rules (symlinked to ~/.claude/model-usage.md)
├── models.md                # Deprecated stub pointing at model-selection.md + model-usage.md (split 2026-07-21; symlink kept for old references)
├── playwright.md            # Playwright visual web-testing reference — screenshot toolkit + how agents visually evaluate UIs, used only when the user asks to "test visually" (symlinked to ~/.claude/playwright.md)
├── plans/                   # Design docs for this repo's own tooling (not symlinked)
│   └── model-routing-test-suite.md  # `routecheck` design: manifest-driven drift/auth/contract tests for the model-routing policy (designed 2026-07-21, not yet implemented)
├── bin/
│   ├── model-run.sh         # THE single entrypoint for non-Claude model calls: canonical flags, timeouts, one auto-retry on transient transport errors, distinct exit codes (64 bad-id / 73 transport-after-retry / 75 auth-quota / 124 timeout); accepts <model-id> or --task-type bulk|cheap|recency|second-review
│   └── routes.tsv           # Single source of truth: model ids, id→backend, retired-id successors, task-type→id mappings (drives model-run.sh + routecheck)
├── agents/
│   ├── model-runner.md      # Named agent wrapping bin/model-run.sh — verbatim-output contract, never substitutes models
│   └── plan-reviewer.md     # Reusable named agent for plan review
├── hooks/
│   ├── route-guard.sh       # PreToolUse(Bash): denies raw codex/cursor-agent invocations + retired model ids (structured permissionDecision JSON, command-position matching — chained/env-prefixed bypasses covered), redirects to bin/model-run.sh
│   ├── route-health-banner.sh  # SessionStart: warns (from cached ~/.claude/route-health.txt) when routecheck last failed or is >14d stale — never runs tests itself
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
│   ├── test_ralph_v2.py     # Tests for ralph-v2
│   └── routecheck.sh        # Verifies the whole routing layer: route-guard hook unit tests, mock-backend error-taxonomy tests (fake codex/cursor via PATH shim), zero-token model-run/table checks, live nonce smoke of EVERY bin/routes.tsv row, and an artifact (file-write) smoke per backend (alias `routecheck`; `--no-live` = free tiers only)
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
├── model-selection.md → ~/dotfiles/claude/model-selection.md
├── model-usage.md → ~/dotfiles/claude/model-usage.md
├── playwright.md → ~/dotfiles/claude/playwright.md
├── statusline-command.sh → ~/dotfiles/claude/statusline-command.sh
├── projects/                  ← CC runtime (untouched)
├── sessions/                  ← CC runtime (untouched)
└── ...
```

## Model Routing & Orchestration

How Claude Code sessions on this machine reach non-Anthropic models (gpt-5.5/5.6 via the Codex CLI, composer-2.5 / grok-4.5 / glm-5.2 via the Cursor CLI — both on subscription-seat auth, no API keys), and how that stays deterministic.

### The layers

```
model-selection.md          WHICH model / task type (policy the LLM reads)
        │
model-runner agent          delegation vehicle (visible as a named agent in
  — or direct Bash —        the workflow/agent UI; direct Bash for one-offs)
        │
bin/model-run.sh            THE entrypoint: flags, timeouts, error codes
        │
bin/routes.tsv              single source of truth: ids → backends,
        │                   retired-id successors, task-type → id mappings
codex CLI / cursor-agent    subscription-seat CLIs (never invoked raw)
```

- **Policy** — `model-selection.md` (WHICH model WHEN: rankings, task-type guidance) and `model-usage.md` (HOW to invoke). Global `CLAUDE.md` requires reading model-selection.md before any subagent/workflow delegation.
- **`bin/model-run.sh`** — the only way models get invoked. Takes `<model-id>` or `--task-type bulk|cheap|recency|second-review` (the table resolves the id — the LLM only picks a class), plus a prompt **file** (never inline) and optional workdir. Transient transport errors get one automatic retry with backoff. Distinct exit codes: `64` bad/retired id · `73` transport error persisting after retry · `75` auth/quota (agents must stop and surface, never substitute a model) · `124` timeout.
- **`bin/routes.tsv`** — edit THIS when the model catalog changes; script errors, docs, and tests all derive from it. Then run `routecheck`.
- **`agents/model-runner.md`** — the sonnet wrapper subagent (tools: Bash + Write only). Give it a model id or task type + prompt; it runs the script and returns output verbatim (`MODEL: <id>` prefix). Preferred over direct Bash for delegations because it appears as a named agent in the progress UI rather than an opaque background process.
- **Enforcement (hooks)** — `route-guard.sh` (PreToolUse on Bash) denies raw `codex exec` / headless `cursor-agent` calls and retired model ids with a structured reason pointing at the blessed path; command-position matching with quoted-prose exemption, `bash -c` smuggling covered. Applies to subagents too. `route-health-banner.sh` (SessionStart) surfaces cached routecheck failures/staleness at session start without running anything.
- **Claude models are NOT routed through any of this** — subagents use the Agent tool's `model` param (`sonnet`/`opus`/`haiku`/`fable`); workflow scripts use `agent(prompt, {model, effort})`. model-run.sh rejects Claude model ids with a pointer.

### Verifying (`routecheck`)

`tests/routecheck.sh` (alias `routecheck`) verifies the whole layer: Tier 0 hook unit tests (deny/allow cases incl. bypass regressions), a mock-backend tier (PATH-shimmed fake codex/cursor-agent proving the error taxonomy deterministically — auth→75, transport→73 after retry, transient→recovers, quoted-prose→no false positive), zero-token table/auth/arg-parsing checks, then live smokes: a nonce echo for **every** routes.tsv row through model-run.sh (tested path = used path, ~100 tokens/route) plus one **artifact smoke per backend** — the model must actually write a file, catching tool-execution/sandbox breakage that text round-trips can't see. `--no-live` runs just the free tiers. Full runs write `~/.claude/route-health.txt` for the SessionStart banner. Rule: a FAILing route means the policy files are wrong — fix the id/syntax or remove the model; never leave a documented route broken.

### Maintenance

Catalog drift (new/retired ids): edit `bin/routes.tsv`, run `routecheck`, PR. Auth rot: `codex login` / `cursor-agent login` (routecheck's Tier 1 catches it). Policy changes (rankings, task-type mappings): `model-selection.md` + routes.tsv `task` rows. History of why it's shaped this way (Cursor SDK rejected, MCP deferred, subagent kept for UI visibility): PRs #3–#6.

## Named Agents

### `agents/model-runner.md`

The model-routing wrapper described above — spawn it with a model id or task type + a prompt (file); it returns the model's output verbatim. Sonnet, tools stripped to Bash + Write, never substitutes models on error.

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
