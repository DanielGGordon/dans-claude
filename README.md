# dans-claude

Personal Claude Code config — hooks, agents, and utilities. Designed to live alongside CC's own `~/.claude/` without interfering with its runtime state.

## Install

```bash
git clone git@github.com:DanielGGordon/dans-claude.git ~/dotfiles/claude
bash ~/dotfiles/claude/install.sh
```

The install script:
1. Symlinks `CLAUDE.md`, `CODING_AGENTS.md`, `agents/`, `hooks/`, `skills/`, `plan-requirements.md`, `android.md`, `models.md`, `model-selection.md`, `model-usage.md`, `playwright.md`, `t3-conversations.md`, `system-map.md`, and `statusline-command.sh` into `~/.claude/`
2. Deep-merges `settings.partial.json` into your existing `~/.claude/settings.json` (preserves CC-managed keys like model, permissions, plugins)
3. Registers user-scoped MCP servers via `claude mcp add` (idempotent; skipped if the server binary isn't on this machine)
4. Adds `source ~/dotfiles/claude/aliases.sh` to `~/.bash_aliases` (creates the file if needed)
5. Backs up any existing files before overwriting
6. Installs ONE user-crontab line tagged `# claude-model-scout` that runs `bin/model-scout.sh` daily at 11:30 UTC (~7:30am ET; see "Model scout" below). Idempotent: the tagged line is replaced, every other crontab line is kept byte-for-byte, and a failing `crontab -l` (anything but "no crontab") leaves the crontab untouched. Opt out with `MODEL_SCOUT_CRON=0 bash install.sh` (removes the line and remembers it in `~/.claude/model-scout/cron-disabled`, so later installs keep it off; `MODEL_SCOUT_CRON=1` opts back in); `bash install.sh --cron-only` runs just this step

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
├── android.md               # System-wide Android deployment + automated-testing reference — canonical emulator/test layer is the android-framework repo; per-project divergent branches (T3 Code, Alfred) documented inline (symlinked to ~/.claude/android.md)
├── model-selection.md       # WHICH model to use WHEN — rankings table, task-type guidance, subagent/workflow model assignment (symlinked to ~/.claude/model-selection.md)
├── model-usage.md           # HOW to invoke a chosen model — `codex exec` + `cursor-agent` wrapper patterns, native Claude routing, current model ids, auth/error rules (symlinked to ~/.claude/model-usage.md)
├── models.md                # Deprecated stub pointing at model-selection.md + model-usage.md (split 2026-07-21; symlink kept for old references)
├── playwright.md            # Playwright visual web-testing reference — screenshot toolkit + how agents visually evaluate UIs, used only when the user asks to "test visually" (symlinked to ~/.claude/playwright.md)
├── system-map.md            # THE map of Alfred (Dan's multi-surface assistant) + every repo/service/port/systemd unit/channel on this box — read before any multi-component task, updated in the same commit as any service/port/unit/repo/channel change (symlinked to ~/.claude/system-map.md)
├── t3-conversations.md      # Where T3 Code conversations live (~/.t3/userdata/state.sqlite), the read-only query helper, projection_* tables, and raw transcript paths — read when the user asks about a T3 thread from any project (symlinked to ~/.claude/t3-conversations.md)
├── plans/                   # Design docs for this repo's own tooling (not symlinked)
│   └── model-routing-test-suite.md  # `routecheck` design: manifest-driven drift/auth/contract tests for the model-routing policy (designed 2026-07-21, not yet implemented)
├── bin/
│   ├── model-run.sh         # THE single entrypoint for non-Claude model calls: canonical flags, timeouts, one auto-retry on transient transport errors, distinct exit codes (64 bad-id / 73 transport-after-retry / 75 auth-quota / 124 timeout); accepts <model-id> or --task-type bulk|cheap|recency|second-review|fable-fallback; pins codex reasoning effort from routes.tsv (MODEL_RUN_EFFORT overrides)
│   ├── cli-fingerprint.sh   # Zero-cost identity (resolved path+size+mtime, `--versions` adds `--version`) of claude / codex / cursor-agent — routecheck records it, the SessionStart banner diffs it to nag for a re-test after any CLI update
│   ├── catalog-drift.sh     # Zero-token drift detector: diffs the live Cursor (`cursor-agent --list-models`) + Codex (`codex debug models`) catalogs against routes.tsv — reports a NEWER version of a routed family (e.g. grok-4.8-* when routes stop at 4.7), routed ids that VANISHED, and UNROUTED catalog ids (new tiers/families no model/retired/ignore row accounts for; `--unrouted` lists them one per line); `--cached` (hook mode) reuses ~/.claude/catalog-<backend>.txt for 24h; fail-open
│   ├── model-scout.sh       # The DAILY unattended routing maintainer (cron, installed by install.sh): in its own worktree, collects zero-token signals (CLI versions, routecheck, catalog-drift + --unrouted), runs headless opus on scout/prompt.md (grok recency research → Claude WebSearch → catalogs → edit routes/docs → routecheck → gpt-6-astra review), gates the diff and opens/updates ONE `claude/model-scout-*` PR; always cleans up its test chats; state in ~/.claude/model-scout/
│   ├── test-chat-cleanup.sh # Deletes ONLY test sessions (created ≥ --since AND cwd is a --workdir OR first user message has --marker) from Cursor (~/.cursor/chats + projects), Codex (`codex delete`) and Claude (~/.claude/projects) histories; `--dry-run`; refuses broad workdirs and short markers
│   ├── t3-purge-test-threads.sh  # Deletes imported test threads (first user message has --marker, created ≥ --since) + the empty /tmp projects the importer made, via T3's live orchestration dispatch (`thread.delete` / `project.delete`, never SQL); dry-run unless `--apply`; exit 3 if the T3 server is down
│   ├── system-map-probe.sh  # Writes the cached [alfred] banner (~/.claude/system-map.state): `systemctl --user is-active` for Alfred's units + 1s health curls of second-brain :4820, brain-actions :8791 and todo-service :4821; fail-open
│   └── routes.tsv           # Single source of truth: model ids, id→backend (+ optional codex reasoning effort in a 4th column), retired-id successors, task-type→id mappings, `ignore` globs for catalog ids deliberately left unrouted (drives model-run.sh + routecheck + catalog-drift.sh)
├── scout/                   # Daily model scout inputs/outputs (bin/model-scout.sh)
│   ├── prompt.md            # Instructions for the headless opus run: hard rules (worktree-only edits, file allowlist, test-chat hygiene, stop on auth errors), evidence standard, research → decide → edit → verify → review → report steps
│   ├── evaluated.tsv        # Append-only log of every model the scout judged (date, vendor, model, verdict, note) so it isn't re-researched daily
│   └── last-report.md       # The latest run's report — committed; used verbatim as the scout PR body (created by the first run that changes something)
├── agents/
│   ├── model-runner.md      # Named agent wrapping bin/model-run.sh — verbatim-output contract, never substitutes models
│   └── plan-reviewer.md     # Reusable named agent for plan review
├── hooks/
│   ├── route-guard.sh       # PreToolUse(Bash): denies raw codex/cursor-agent invocations + retired model ids (structured permissionDecision JSON, command-position matching — chained/env-prefixed bypasses covered), redirects to bin/model-run.sh
│   ├── route-health-banner.sh  # SessionStart: warns (from cached ~/.claude/route-health.txt) when routecheck last failed or is >14d stale — never runs tests itself; warns when claude/codex/cursor-agent changed since the last routecheck (cli-fingerprint.sh vs ~/.claude/route-health-tools.txt); also runs catalog-drift.sh --cached and prints one line when a catalog has a newer grok/composer/glm/gpt than routes.tsv (or a routed id vanished); prints one `[model-scout]` line only when the daily scout failed, is >36h stale (or installed >36h ago and never recorded a run), or has a PR awaiting review (reads ~/.claude/model-scout/last-run.json, no network)
│   ├── system-map-banner.sh    # SessionStart: prints the cached [alfred] block (units up/down, health, pointer at ~/.claude/system-map.md); refreshes the cache via bin/system-map-probe.sh at most every 10 min
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
│   ├── grill-me/
│   │   └── SKILL.md         # Interview relentlessly about a plan
│   ├── nou/
│   │   └── SKILL.md         # "No, YOU do it" — execute the just-suggested manual steps
│   ├── to-spec/             # Vendored from mattpocock/skills (see Vendored skills)
│   │   └── SKILL.md         # Turn the current conversation into a spec/PRD
│   ├── to-tickets/          # Vendored from mattpocock/skills
│   │   └── SKILL.md         # Break a plan/spec into tracer-bullet tickets
│   ├── setup-matt-pocock-skills/  # Vendored from mattpocock/skills — one-time tracker/label config
│   ├── excalidraw-diagram/  # Vendored from coleam00/excalidraw-diagram-skill (local patches; see Vendored skills)
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
│   ├── routecheck.sh        # Verifies the whole routing layer: route-guard hook unit tests, model-runner agent-contract lints, mock-backend error-taxonomy tests (fake codex/cursor via PATH shim), zero-token model-run/table checks, live catalog-drift check (vanished id = FAIL, newer version / unrouted ids = WARN), live nonce smoke of EVERY bin/routes.tsv row, an artifact (file-write) smoke per backend, then deletes the test chats the CLIs persisted and proves none are left (alias `routecheck`; `--no-live` = free tiers only); records the CLI versions it verified against
│   └── workflows/           # Orchestration smokes for the Agent/Workflow layer — run from INSIDE a Claude Code session via Workflow({scriptPath}) (see "Verifying")
│       ├── orchestration-smoke-claude.js        # agent({model}) + pipeline() through haiku/sonnet/opus/fable (4 agents, ~50k tokens)
│       └── orchestration-smoke-model-runner.js  # 11 parallel model-runner agents: preferred non-Claude ids + every --task-type; asserts nonce AND resolved `MODEL:` id; runs in one throwaway workdir with MODEL_RUN_EPHEMERAL=1, then test-chat-cleanup.sh
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
├── t3-conversations.md → ~/dotfiles/claude/t3-conversations.md
├── system-map.md → ~/dotfiles/claude/system-map.md
├── statusline-command.sh → ~/dotfiles/claude/statusline-command.sh
├── projects/                  ← CC runtime (untouched)
├── sessions/                  ← CC runtime (untouched)
└── ...
```

## Model Routing & Orchestration

How Claude Code sessions on this machine reach non-Anthropic models (gpt-6-astra / gpt-5.5 / gpt-5.6 via the Codex CLI, composer-2.5 / grok-4.7 (default grok; 4.6/4.5 legacy) / glm-5.2 via the Cursor CLI — both on subscription-seat auth, no API keys), and how that stays deterministic.

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
- **`bin/model-run.sh`** — the only way models get invoked. Takes `<model-id>` or `--task-type bulk|cheap|recency|second-review|fable-fallback` (the table resolves the id — the LLM only picks a class), plus a prompt **file** (never inline) and optional workdir. Codex reasoning effort comes from the table's 4th column (`gpt-6-astra` → `high`, because its catalog default is `low`); `MODEL_RUN_EFFORT` overrides per call. `MODEL_RUN_EPHEMERAL=1` marks a **test** call: codex gets `--ephemeral` (no rollout / thread row, so nothing in `codex resume` or the Codex app); cursor has no equivalent, so test callers pass a throwaway workdir and run `bin/test-chat-cleanup.sh` for it. Transient transport errors get one automatic retry with backoff. Distinct exit codes: `64` bad/retired id · `73` transport error persisting after retry · `75` auth/quota (agents must stop and surface, never substitute a model) · `124` timeout.
- **`bin/routes.tsv`** — edit THIS when the model catalog changes; script errors, docs, and tests all derive from it. Then run `routecheck`. Row shape: `model <id> <backend> [<codex-reasoning-effort>]`; also `retired <old> <successor>`, `task <type> <id>`, and `ignore <glob> <reason>` (a catalog id seen and deliberately not routed — see "Catalog drift detection").
- **`agents/model-runner.md`** — the sonnet wrapper subagent (tools: Bash + Write only). Give it a model id or task type + prompt; it runs the script and returns output verbatim (`MODEL: <id>` prefix). Preferred over direct Bash for delegations because it appears as a named agent in the progress UI rather than an opaque background process.
- **Enforcement (hooks)** — `route-guard.sh` (PreToolUse on Bash) denies raw `codex exec` / headless `cursor-agent` calls and retired model ids with a structured reason pointing at the blessed path; command-position matching with quoted-prose exemption, `bash -c` smuggling covered. Applies to subagents too. `route-health-banner.sh` (SessionStart) surfaces cached routecheck failures/staleness at session start without running tests, warns when claude/codex/cursor-agent changed since the last routecheck (`bin/cli-fingerprint.sh`, zero cost), and runs the catalog-drift check (below) from a 24h cache.
- **`bin/catalog-drift.sh`** — the zero-token drift detector that keeps routes.tsv honest against the live catalogs (see "Catalog drift detection" below).
- **Claude models are NOT routed through any of this** — subagents use the Agent tool's `model` param (`sonnet`/`opus`/`haiku`/`fable`); workflow scripts use `agent(prompt, {model, effort})`. model-run.sh rejects Claude model ids with a pointer.

### Verifying (`routecheck`)

`tests/routecheck.sh` (alias `routecheck`) verifies the whole layer: Tier 0 hook unit tests (deny/allow cases incl. bypass regressions), a mock-backend tier (PATH-shimmed fake codex/cursor-agent proving the error taxonomy deterministically — auth→75, transport→73 after retry, transient→recovers, quoted-prose→no false positive — plus the catalog-drift detector against a fake future catalog), zero-token table/auth/arg-parsing checks, the live catalog-drift check (vanished id FAIL / newer version WARN), then live smokes: a nonce echo for **every** routes.tsv row through model-run.sh (tested path = used path, ~100 tokens/route) plus one **artifact smoke per backend** — the model must actually write a file, catching tool-execution/sandbox breakage that text round-trips can't see. `--no-live` runs just the free tiers. Full runs write `~/.claude/route-health.txt` for the SessionStart banner, plus `~/.claude/route-health-tools.txt` — the claude / codex / cursor-agent builds the run verified against (`bin/cli-fingerprint.sh --versions`). Rule: a FAILing route means the policy files are wrong — fix the id/syntax or remove the model; never leave a documented route broken.

**Test-chat hygiene** (2026-09-22: 97 ROUTE-OK threads had piled up in Codex, 238 routecheck chats in Cursor, and haiku smokes had been imported into T3 Code as visible threads): every live call runs with `MODEL_RUN_EPHEMERAL=1`, claude runs as `claude -p --no-session-persistence` inside the run's `mktemp` dir (never the caller's cwd), and every prompt carries a per-run marker (`ROUTECHECK_MARKER` if a caller such as the model scout supplies one). Before the verdict, `bin/test-chat-cleanup.sh` deletes what the CLIs still persisted (Cursor has no ephemeral mode) and an independent re-check (`hygiene:no-test-chats-left`) must find nothing; a Codex or Claude deletion is a WARN (a CLI update broke the prevention flag). The EXIT trap repeats the cleanup if the run dies early.

`routecheck` covers everything **below** the Agent/Workflow layer (it calls `model-run.sh` directly). The layer above — Claude Code's own `agent({model})` routing, `agentType: 'model-runner'` delegation, and parallel fan-out — is covered by two checked-in workflow scripts in `tests/workflows/`, which can only run inside a Claude Code session (ask Claude: *"run the orchestration smoke workflows"*, i.e. `Workflow({ scriptPath: '~/dotfiles/claude/tests/workflows/orchestration-smoke-claude.js', args: { nonce: 'ORCH-<date>' } })` and the same for `orchestration-smoke-model-runner.js`). Each returns `{ verdict: 'ALL OK' | 'FAIL', results }`. The model-runner smoke runs 11 runners **in parallel** on purpose — that shape is what exposed the 2026-08-24 bug where runners shared one literal `/tmp/model-run-$$.md` prompt file (Write doesn't expand `$$`) and one returned another's answer; routecheck now lints the agent contract against it.

**When to re-test** (the SessionStart banner nags for the first three automatically): after a Claude Code update, a Codex CLI update, or a Cursor CLI update (`cursor-agent update`) — run `routecheck` then both workflows; after a model catalog change (drift warning) — `routecheck` after editing `bin/routes.tsv`; after editing `agents/model-runner.md` — the model-runner workflow. `~/.claude/` symlinks point at the **master** checkout, so a branch's edits to the agent definition are only exercised by the workflow after merge + `git pull`.

### Catalog drift detection (`bin/catalog-drift.sh`)

Why: on 2026-08-19 a task asked for "Grok 4.6" while routes.tsv only knew `cursor-grok-4.5-*`, so model-run.sh rejected it (exit 64) mid-task. The detector makes the NEXT bump (4.7, composer-3, gpt-5.7, ...) show up at session start instead.

What it does (zero tokens, no model calls): reads the live catalogs — Cursor via `cursor-agent --list-models`, Codex via `codex debug models` (a local-cache read of `~/.codex/models_cache.json`, which Codex refreshes itself; both commands are allowed by route-guard) — parses each id into family + version (strip a leading `cursor-`, then `<family>-<N.N>[-variant]`: `cursor-grok-4.6-high-fast` → grok 4.6, `gpt-5.6-sol` → gpt 5.6, `composer-2.5` → composer 2.5) and compares against `bin/routes.tsv`:

- **newer** — a family routed in routes.tsv has a higher version in its catalog than any routed row (`Cursor catalog has grok-4.8-* (7 ids) but routes.tsv stops at grok-4.7`). New *variants* of an already-routed version (e.g. `-xhigh-fast`) are deliberately not drift.
- **Known limitation (family-max semantics)** — comparison is per family against the *highest* routed version, so once a `gpt-6+` id is routed, a later `gpt-5.x` point release is not "newer". The **unrouted** finding below closes that gap; the mock fixture in `tests/routecheck.sh` pins both behaviors.
- **unrouted** (added 2026-09-22, when GPT-6 Sol/Luna and Claude Opus 5.5 shipped the same day — a new *tier* at a routed version and a brand-new family, both invisible to version-max) — catalog ids that are not a `model` row, not a `retired` row, and not matched by an `ignore` row, summarized per backend by family (`Codex catalog has 2 unrouted ids: gpt-6-luna, gpt-6-sol`). `--unrouted` prints the full list as `<backend>\t<id>` lines instead (exit 1 if any). Acknowledge an id you deliberately don't route with `ignore<TAB><glob><TAB><reason>` in routes.tsv: a shell glob matched against the bare id and `<backend>:<id>` (so `cursor:gpt-*` scopes it to Cursor); the reason is mandatory (routecheck checks). Prefer one glob per family **version** (`cursor:claude-opus-5-5-*`) so the next version still surfaces.
- **vanished** — a routes.tsv id is no longer listed by its backend (`routes.tsv id cursor-grok-4.5-low is gone from the Cursor catalog`) — that route will hard-error or silently remap, fix it now.
- **unavailable / stale** — a CLI is missing, times out, or isn't logged in: that backend is skipped (or served from a stale cache) and said so in one line. Never fatal, never blocks.

Output is `<kind>\t<message>` lines; exit `0` no drift · `1` drift (newer, vanished and/or unrouted) · `2` no catalog readable. `--cached` (what the hook uses) reuses `~/.claude/catalog-cursor.txt` / `catalog-codex.txt` when younger than 24h and remembers a failed fetch for 1h (`catalog-<backend>.failed`) so a broken CLI costs one timeout per hour, not per session. Env knobs: `CATALOG_DRIFT_CACHE_DIR`, `CATALOG_DRIFT_MAX_AGE`, `CATALOG_DRIFT_TIMEOUT`, `CATALOG_DRIFT_FAIL_TTL`.

Where it runs:
- **`routecheck`** (Tier 1.5, live fetch, refreshes the caches): a vanished id is a **FAIL**; a newer version or unrouted ids are a **WARN** — advisory, listed in a `WARNINGS (advisory, not failures):` line, and the suite still ends `ALL ROUTES OK` because nothing is actually broken. The detector itself is unit-tested in the mock tier against a fake future catalog (grok 4.8 / gpt-5.7 present, `cursor-grok-4.5-low` gone), the unrouted summary / `--unrouted` list / backend-scoped `ignore` rows, and a logged-out CLI (fail-open).
- **SessionStart** (`hooks/route-health-banner.sh`, `--cached`): prints one line like `[route-health] Cursor catalog has grok-4.8-* (7 ids) but routes.tsv stops at grok-4.7 — run 'routecheck' / update bin/routes.tsv (then model-selection.md + model-usage.md).` or `[route-health] catalog drift check skipped — Cursor catalog unavailable (...)`. Silent when in sync. `unrouted` ids are the daily model scout's input and are not shown while its cron line is installed; without it the banner prints a one-line count.
- **The daily model scout** (below) reads both the live summary and `--unrouted`, and must end each run with every unrouted id either routed or ignored.

How to fix a drift warning: add the new ids as `model` rows in `bin/routes.tsv` (and move the default — e.g. `task recency` — if the new version should be the default), update the rankings/notes in `model-selection.md` (honestly: mark the row provisional until benchmarked) and any id mentions in `model-usage.md` / `agents/model-runner.md`, run `routecheck` (the live nonce smoke proves the new ids work), PR. For a vanished id: remove the row or convert it to a `retired <old> <successor>` row.

Codex caveat: there is no `codex --list-models`; `codex debug models` reads the cache Codex itself maintains, so Codex drift is detected after the next Codex run refreshes that cache — good enough, and free.

### Model scout (`bin/model-scout.sh`, daily cron)

Why: every model bump so far was noticed by hand, late — grok-4.7 was routed a day after release only because catalog-drift happened to flag it, and on 2026-09-22 Claude Opus 5.5, GPT-6 Sol and GPT-6 Luna all shipped the same day. The scout does the detect → route → retire → re-test → PR loop every morning, unattended.

Cron (installed by `install.sh`, tagged `# claude-model-scout`): `30 11 * * * . ~/.profile && ~/dotfiles/claude/bin/model-scout.sh >> ~/.claude/model-scout/cron.log 2>&1`. Manual: `bin/model-scout.sh [--base <ref>] [--no-pr] [--repo <dir>] [--dry-run]` — `--dry-run` runs only the zero-token signals + cleanup; `--no-pr` commits on a local `claude/model-scout-<date>` branch and prints it.

One run:
1. **flock** single instance; log `~/.claude/model-scout/logs/<date>.log` (+ `.report.md` / `.grok.md` / `.review.md` / `.patch`, 30 days kept); cron.log gets one start and one end line.
2. **Own worktree** of `~/dotfiles/claude` in `~/.cache/model-scout/wt-<date>`, detached at `origin/master` — or at the branch of an already-open `claude/model-scout-*` PR, so there is **at most one open scout PR** (an explicit `--base` next to an open scout PR forces `--no-pr`; a failing `gh pr list` aborts the run rather than risk a second PR). The live checkout is never touched.
3. **Signals** (zero tokens except routecheck's ~100/route): CLI versions now vs. at the last routecheck, `tests/routecheck.sh` (live; `MODEL_SCOUT_ROUTECHECK=free|skip`), `catalog-drift.sh` live + `--unrouted`. Every routecheck in a run (the wrapper's and the agent's) writes its verdict into the run's artifacts dir via `ROUTE_HEALTH_FILE` / `ROUTE_HEALTH_TOOLS`, never the live banner's `~/.claude/route-health*.txt` — except the pre-run check of an unmodified `origin/master`, which is published there.
4. **Agent**: `claude -p --no-session-persistence --model opus --effort high --permission-mode bypassPermissions` plus `--disallowedTools` deny rules (git commit/push, `gh pr` writes, crontab, install.sh) and refusing git commit/push hooks in its env, `BASH_MAX_TIMEOUT_MS` raised to 30 min for the ~10-min grok/astra calls, cwd = the worktree, prompt = `scout/prompt.md` + the signals, hard timeout `MODEL_SCOUT_TIMEOUT` (5400s). It must research with grok **first** (`model-run.sh --task-type recency`, live web + X search), confirm every claim via Claude WebSearch/WebFetch of primary sources, reconcile with the live catalogs, then update routes.tsv / docs / `route-guard.sh` RETIRED / the routecheck mock fixture / `scout/evaluated.tsv`, re-run routecheck (repairing invocations a CLI update broke, or removing the route), get a `--task-type second-review` (gpt-6-astra) review, and write `scout/last-report.md`. It writes a status line and the grok output to files the wrapper checks — a run without real grok output (or with a failed grok call reported as `ok`) is marked failed, and one whose grok reports no X search (`SEARCH-TOOLS-USED: … x=no`) is published but recorded failed.
5. **Gate + publish**: only routing-layer files may change (routes.tsv, model-run.sh, catalog-drift.sh, cli-fingerprint.sh, routecheck, the workflow smokes, route-guard, the banner, model-runner.md, model-selection.md, model-usage.md, README.md, system-map.md, `scout/evaluated.tsv` / `last-report.md`); anything else — install.sh, the cleanup scripts, the prompt, this script — is reverted and logged. Every changed `.sh` must pass `bash -n` and `routecheck --no-live` must pass. Then commit (`Co-Authored-By` the model that actually ran), push (SSH, falling back to HTTPS via `gh auth git-credential`), and `gh pr create --base master` with the report as the body — or push to / `gh pr edit` the open scout PR after re-checking it is still OPEN (MERGED mid-run: the commit is replayed onto `origin/master` for a fresh PR; CLOSED or unknown: kept on a local branch, run failed). Never pushes to master.
6. **Always (EXIT trap)**: first retry every sweep queued in `~/.claude/model-scout/pending-cleanup.tsv` by an earlier failed run, then `test-chat-cleanup.sh --since <run start> --marker <run marker>` for the worktree + every throwaway workdir, then `t3-purge-test-threads.sh --apply` (if either fails — e.g. t3code down — the sweep is queued and the run recorded failed) (both run from the script's own `bin/`, never from the worktree the agent could edit), remove the worktree, the headless session's transcript-less `~/.claude/projects/<enc(worktree)>/` and temp dirs, then write `~/.claude/model-scout/last-run.json` (`{date, status: no-change|pr|failed, pr_url, open_pr, summary, log, cleanup, …}`; `open_pr` keeps an open scout PR visible across later no-change runs; `failed` also covers runs that worked but left something actionable — incomplete cleanup, a live routecheck still failing, grok without X).

No test chat may survive: every model call runs with `MODEL_RUN_EPHEMERAL=1` in a `mktemp` workdir under the run's scratch dir, every prompt carries the run marker `MODEL-SCOUT-<date>-<hex>` (shared with routecheck via `ROUTECHECK_MARKER`), and the cleanup scripts are the backstop. Auth/quota errors (model-run exit 75, claude login/usage limits) fail the run loudly into `last-run.json` — the scout never substitutes a model. The SessionStart banner surfaces the result as one `[model-scout]` line, only when there's something to do.

Env knobs: `MODEL_SCOUT_HOME` (`~/.claude/model-scout`), `MODEL_SCOUT_CACHE` (`~/.cache/model-scout`), `MODEL_SCOUT_TIMEOUT`, `MODEL_SCOUT_MODEL` (opus), `MODEL_SCOUT_EFFORT` (high), `MODEL_SCOUT_ROUTECHECK`, `MODEL_SCOUT_BUDGET_USD` (optional `--max-budget-usd`), `MODEL_SCOUT_PROMPT` (test an unmerged prompt).

### Test-chat cleanup (`bin/test-chat-cleanup.sh`, `bin/t3-purge-test-threads.sh`)

Prevention comes first (`MODEL_RUN_EPHEMERAL=1`, `claude -p --no-session-persistence`, throwaway cwds); these two are the net.

- **`test-chat-cleanup.sh --since <epoch> --marker <str> --workdir <dir>... [--dry-run]`** — deletes a record only if it was created at/after `--since` AND (its cwd is exactly one of the workdirs OR its first user message contains the marker). Cursor: `~/.cursor/chats/<md5(cwd)>/<id>/` (meta.json cwd and createdAtMs checked per chat) + its `projects/<slug>/agent-transcripts/<id>/`, and the workdir's project dir once empty and its `.workspace-trusted` path proves it. Codex: rollouts + `state_5` thread rows via `codex delete --force <id>` (falls back to removing the rollout, with a `note`). Claude: top-level `~/.claude/projects/<enc>/<id>.jsonl` (+ `<id>/`), creation time = the transcript's first timestamp, plus a workdir's file-less project dir. Refuses markers under 8 chars and broad workdirs (`/`, `/tmp`, `$HOME`, …). Output `deleted|would-delete|note <cli> <what>`; exit 0 even when nothing matched, 2 internal error, 64 usage. `TEST_CHAT_CLEANUP_HOME` points it at a fake home (routecheck's mock tier).
- **`t3-purge-test-threads.sh --marker <str> --since <epoch> [--thread-id <id>...] [--apply]`** — a `claude -p` transcript that did persist becomes a T3 thread within 15 min (`t3-claude-import.timer`), and deleting the .jsonl afterwards doesn't remove it. This finds live `claude-import-*` threads created since `--since` whose **first** user message contains the marker (threads with >3 user messages are skipped as real conversations) via a read-only sqlite query, and deletes them through the running server's `/api/orchestration/dispatch` (`thread.delete`, then `project.delete` without force for importer-created `/tmp` projects left empty) with a short-lived session token from T3's own CLI, revoked on exit — the same path `t3 project remove` uses; never SQL. Dry-run unless `--apply`; exit 3 (nothing deleted) if the T3 server is down.

### Maintenance

The daily model scout (above) now does the catalog-drift / new-model / CLI-breakage loop and opens a PR; review and merge it, then `git pull` in `~/dotfiles/claude`. If the `[model-scout]` banner says it failed, read the log it names (auth rot is the usual cause). By hand:
Catalog drift (new/retired ids): the SessionStart hook / `routecheck` tell you (see above); then edit `bin/routes.tsv`, run `routecheck`, PR. CLI updates (Claude Code, `codex`, `cursor-agent update`): the SessionStart hook says which tool changed; run `routecheck` + the `tests/workflows/` smokes. Auth rot: `codex login` / `cursor-agent login` (routecheck's Tier 1 catches it). Policy changes (rankings, task-type mappings): `model-selection.md` + routes.tsv `task` rows. History of why it's shaped this way (Cursor SDK rejected, MCP deferred, subagent kept for UI visibility): PRs #3–#6.

## System map (`system-map.md`)

`system-map.md` is the system-wide answer to "what else is running on this box, and
what will I break?" It documents **Alfred** — Dan's multi-surface assistant (phone
call while driving, Android app, web at his desk) — and every component it touches:
the Alfred hub (`~/projects/alfred`: voice-gateway :8790, voice-tunnel,
brain-actions :8791, todo-service :4821, `alive-ping.timer`, and the two client
surfaces that are now live — the Preact web app and the Android app), second-brain
(`~/projects/meta/second-brain`: Postgres `second_brain`, API :4820, MCP `brain`,
ingest + call-card timers), T3 Code (`~/projects/meta/t3code-v2`, :3773 behind
:7443), Caddy (public HTTPS front for T3/DanCode/Abba Bank/Alfred at
:7443/:8443/:9443/:6443), slackcc (`~/projects/slack`, pps :8642 → llama-guard
:8641), whatsapp-bot, android-framework, and this repo. Each entry lists repo path,
purpose, data store, ports/units, how it talks to the others, and where its docs
live — plus an ASCII edge diagram, a ports/units table, and a "How to add a
component" checklist.

Two meta-rules (modelled on `android.md`) make it stay true:

- **Consult first** — any task touching more than one component, or adding/moving a
  service, port, unit, repo or channel, reads it before planning.
- **Update on change** — the agent making that change updates this file in the same
  PR/commit. Volatile values (tunnel URLs, tokens, ids) stay out; the file names the
  config that holds them instead.

Global `CLAUDE.md` carries the short "The System (Alfred)" stanza pointing here, and
the SessionStart banner below keeps it visible.

### `hooks/system-map-banner.sh` + `bin/system-map-probe.sh`

SessionStart banner, same shape as `route-health-banner.sh`: the hook **only prints a
cache** and always exits 0. `bin/system-map-probe.sh` writes that cache
(`~/.claude/system-map.state`) — `systemctl --user is-active` for `t3code`,
`second-brain`, `brain-actions`, `voice-gateway`, `voice-tunnel`, `slackcc`,
`second-brain-callcards.timer`, `alive-ping.timer`, `todo-service`, then 1s-budget curls of
`127.0.0.1:4820/health`, `127.0.0.1:8791/healthz` and `127.0.0.1:4821/healthz`.
The hook refreshes it at most every 10 minutes (`SYSTEM_MAP_MAX_AGE`,
`SYSTEM_MAP_STATE` to override), under `timeout 10`, and prints at most 8 lines:

```
[alfred] units: all 9 active (t3code second-brain …) — checked 18:37
[alfred] health: second-brain ok · brain-actions ok · todo-service ok
[alfred] system map: ~/.claude/system-map.md — read it before any task spanning more than one component; …
```

When something is down the first line becomes `units up (N): …` plus a
`[alfred] NOT RUNNING: voice-gateway:inactive — 'systemctl --user status <unit>' …`
line. Missing `systemctl`/`curl`, an unreadable cache dir, a nonexistent unit: all
degrade to a `?`/"unknown" line, never a failure. **Adding a service to the box
means adding it to `UNITS` in `bin/system-map-probe.sh`** as well as to
`system-map.md`.

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

- **`skills/to-spec`** — Turn the current conversation into a spec (a PRD) — no interview, just synthesis of what was already discussed — and publish it to the configured issue tracker. Vendored from mattpocock/skills.
  ```
  /to-spec
  ```

- **`skills/to-tickets`** — Break a plan, spec, or the current conversation into tracer-bullet tickets, each declaring its blocking edges, published to the configured tracker. Vendored from mattpocock/skills. Both skills expect `/setup-matt-pocock-skills` to have been run once per repo to configure the tracker and label vocabulary.
  ```
  /to-tickets
  ```

- **`skills/grill-me`** — Interview you relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree.
  ```
  /grill-me
  ```

### Diagrams

- **`skills/excalidraw-diagram`** — Generate Excalidraw diagrams as `.excalidraw` JSON files and render them to PNG using headless Chromium. Vendored from [coleam00/excalidraw-diagram-skill](https://github.com/coleam00/excalidraw-diagram-skill) (see Vendored skills). Requires `uv` and Playwright+Chromium (installed automatically by `install.sh` if `uv` is present).
  ```
  /excalidraw-diagram
  ```

### Development

- **`skills/tdd`** — Test-driven development with red-green-refactor loop. Builds features or fixes bugs one vertical slice at a time.
  ```
  /tdd
  ```

### Workflow

- **`skills/nou`** — "No, YOU do it": when Claude just suggested commands or steps for you to run manually, this makes it execute them itself instead.
  ```
  /nou
  ```

### Execution & Review

- **`skills/ralph-v2`** — Ralph v2: a phase-level build/evaluate harness. Unlike the old task-by-task loop, each **phase** gets one generator invocation (implements the whole phase) followed by an evaluator that tests the output against the phase's acceptance criteria, retrying up to `--max-eval-rounds` times. A rescue agent recovers phases that stall past `--task-timeout`. The plan file and a learnings file are the shared state across phases. The expected plan format is `## Phase N` + `**Delivers**` + `**Acceptance criteria**` (documented in `plan-requirements.md`); v2 also parses old `- [ ]` checkbox plans for backward compatibility.
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

### Vendored skills

Third-party skills are vendored as plain committed files in `skills/` — no submodules, no clone-at-install — managed with the [`skills` CLI](https://github.com/vercel-labs/skills):

- **[mattpocock/skills](https://github.com/mattpocock/skills)** (`to-spec`, `to-tickets`, `setup-matt-pocock-skills`) — add more of Matt's skills with:
  ```
  npx skills add mattpocock/skills --skill <name> -a claude-code -g -y
  ```
  `-g` writes to `~/.claude/skills`, which is this repo's `skills/` via the symlink — so the files land in the repo; commit them. Update later with `npx skills update <name>` and review/commit the diff.
- **[coleam00/excalidraw-diagram-skill](https://github.com/coleam00/excalidraw-diagram-skill)** (`excalidraw-diagram`) — pinned at upstream `8646fcc` with local patches: absolute renderer paths (`~/.claude/skills/...` instead of the upstream project-relative `cd .claude/...`), a sharpened trigger description, and `render_template.html` pinned to `@excalidraw/excalidraw@0.18.0` on esm.sh (the unpinned import 404s on a transitive dep). If you re-vendor from upstream, re-apply the patches (`git diff` against the vendoring commit shows them).

### Adding a new skill

Create a subdirectory in `skills/` with a `SKILL.md` whose frontmatter has `name` and `description`. No `install.sh` change is needed — the whole `skills/` directory is symlinked, so new subdirectories load on the next session restart. Add an entry to this README's Skills section (nothing enforces the two staying in sync).

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

### `hooks/system-map-banner.sh`

SessionStart `[alfred]` banner — see "System map" above.

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
