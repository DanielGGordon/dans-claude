# Model Usage — HOW to Invoke Each Model

This file is the mechanics reference: once you already know which model you want
(see `~/.claude/model-selection.md` for choosing), this is how you drive it.
Follow these invocations exactly unless the user explicitly says otherwise.

**Every invocation below is live-verified**: `bash ~/dotfiles/claude/tests/routecheck.sh`
(alias `routecheck`) runs each documented route with a nonce prompt (last run
2026-07-21: ALL ROUTES OK). Don't improvise variations — copy the commands as
written. If one fails for you, run `routecheck`, then fix or remove the entry.

## Universal Rules

- **Prompt files, never inline.** Write the task prompt to a scratch file and pass
  `"$(cat <promptfile>)"`. Large inline prompts (20KB+) hang CLIs with zero output.
- **Thin wrapper agents.** Non-Claude models are reached from a subagent whose only
  job is to run the CLI command and return stdout **verbatim** — no analysis, no
  edits, no substituting its own answer.
- **Auth / quota errors: stop and surface.** If any CLI reports auth, quota, or
  billing errors (`429`, `insufficient_quota`, `Authentication required`): **stop
  and tell the user**. Never silently substitute a different model.
- **Exact model ids only.** Validate against the CLI's own model list when in doubt.
  Retired ids sometimes keep working via silent aliases — treat that as drift, not
  success, and fix the id.

## Claude Models (sonnet / opus / haiku / fable)

Native to Claude Code — no CLI, no wrapper:

| Mechanism | How to select the model |
| --------- | ----------------------- |
| **Agent tool** (subagents) | `model` parameter: `"sonnet"`, `"opus"`, `"haiku"`, or `"fable"`. |
| **Workflow scripts** | `agent(prompt, { model: 'sonnet', effort: 'low' })`. |
| **Default (no `model`)** | Inherits the session model — a Fable-5 session fans out Fable-5 workers unless overridden. |

- `effort` per call: `'low' | 'medium' | 'high' | 'xhigh' | 'max'`.
- **Do not use `claude -p --model <model>` from Bash** for routing. It spawns a
  nested session with separate context/permissions and you must parse stdout.
  Reserve `claude -p` for genuinely detached background jobs; the Agent tool's
  background mode covers most of those anyway.

## OpenAI Models via Codex CLI (gpt-5.5, gpt-5.6 tiers)

Canonical invocation (foreground, generous timeout — 10 min):

```bash
codex exec --dangerously-bypass-approvals-and-sandbox -C <repo> "$(cat <promptfile>)"          # gpt-5.5 default
codex exec --dangerously-bypass-approvals-and-sandbox -C <repo> -m gpt-5.6-terra "$(cat <promptfile>)"
```

- Tiers: `gpt-5.6-sol` (flagship), `gpt-5.6-terra` (default for bulk work),
  `gpt-5.6-luna` (fast draft tier).
- Continue an existing session: `codex exec --dangerously-bypass-approvals-and-sandbox resume --last "..."`.
- **Why the bypass flag:** Codex's bwrap sandbox cannot nest inside Claude Code's
  Bash sandbox (`bwrap: loopback: Failed RTM_NEWADDR`). Claude Code's own sandbox
  remains the outer boundary, so bypassing Codex's inner sandbox is safe and required.
- Reviews use the same mechanism: a review prompt asking for findings with
  **severity**, **file:line**, a **concrete failing scenario**, and a
  **SHIP / FIX-FIRST** verdict.

> Historical note: **codex-plugin-cc** was evaluated and removed 2026-07-07 — its
> hardcoded per-turn sandbox modes are incompatible with nested bwrap on this
> machine; re-evaluate only if upstream adds a sandbox passthrough.

## Cursor CLI (composer-2.5, grok-4.5, and other Cursor-exposed models)

`cursor-agent` (`~/.local/bin/cursor-agent`, also aliased as `agent`) is logged in
via subscription seat. Canonical headless one-shot:

```bash
cursor-agent --print --trust --force --output-format text --model <id> "$(cat <promptfile>)"
```

Current ids (verified 2026-07-21 via `cursor-agent --list-models`):

- `composer-2.5` (and `composer-2.5-fast`)
- `cursor-grok-4.5-high` / `cursor-grok-4.5-high-fast` — the grok-4.5 default;
  `-medium` and `-low` tiers also exist. The old `grok-4.5-xhigh` id is **retired**
  (works only via a silent alias — do not use it).

Behavior and flags:

- Unknown model ids **hard-error** and print the full valid list — but *retired*
  ids can silently remap to a successor (e.g. `composer-2` → 2.5). When an id in
  this file fails or looks stale, run `cursor-agent --list-models` and update here.
- `-p/--print` = headless (full tool access), `--trust` skips workspace-trust,
  `--force`/`--yolo` auto-approves tools, `--output-format text|json|stream-json`,
  `--resume [chatId]` / `--continue` for sessions.
- Check auth with `cursor-agent status`.
- The Cursor catalog also exposes OpenAI/Anthropic/Google/etc. models. Route those
  through their native paths (Codex CLI, Agent tool) instead — the Cursor gateway
  is for models with no other path (composer, grok).

> **Cursor TypeScript SDK (`@cursor/sdk`): evaluated 2026-07-21, rejected.** Two
> independent reviews (gpt-5.6-sol, grok-4.5) both concluded STAY-ON-CLI: the CLI
> already covers streaming/resume/model-listing; the SDK would mean a bespoke Node
> wrapper + npm surface in this repo, plain-`string` model ids (no added safety),
> and possible consumption billing vs the already-paid seat. Re-evaluate only if
> the CLI loses capabilities or the SDK gains subscription-seat auth.

## Direct xAI API (grok-4.5) — UNWIRED, do not use

**Status: not set up on this machine (`XAI_API_KEY` is not set). Do not attempt
this route — use the Cursor CLI route for grok instead.** Kept only as wiring
notes for if the user ever asks for it:

Only worth wiring when you need xAI-side features the Cursor route doesn't
expose — chiefly the live-search agent tools: OpenAI-compatible, base URL
`https://api.x.ai/v1`, model id `grok-4.5`, key in `XAI_API_KEY` (docs:
https://docs.x.ai/developers/grok-4-5). Supports reasoning-effort levels and
`prompt_cache_key` for long agent loops.

- **Live search = Agent Tools** (`web_search`, `x_search`) on the Responses API,
  billed $5 per 1k *successful* tool invocations on top of tokens. The old Live
  Search `search_parameters` API is **dead** (deprecated 2026-01-12, returns
  HTTP 410) — do not use it.
- Pricing notes (2026-07-21): $2/$6 per Mtok, cached input $0.30, **rates double
  past a 200k-token prompt** — keep search-loop contexts short.
