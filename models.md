# Model Strategy & Subagent / Workflow Delegation

## Model Rankings

Scores are **1–10, where higher is better**.

- **Cost efficiency** = cheaper / more efficient for your actual spend.
- **Intelligence** = ability on hard, unsupervised problems.
- **Taste** = UI/UX judgment, code quality, API design, and copy quality.

| Model        | Cost Efficiency | Intelligence | Taste |
| ------------ | --------------- | ------------ | ----- |
| composer-2.5 | 10              | 6            | 4     |
| grok-4.5     | 10              | 7            | 4     |
| gpt-5.5      | 9               | 8            | 5     |
| gpt-5.6      | 7               | 9            | 6     |
| sonnet-5     | 5               | 5            | 7     |
| opus-4.8     | 4               | 7            | 8     |
| fable-5      | 2               | 9            | 9     |

Notes on the newer entries (added 2026-07-09):

- **grok-4.5** — near-GPT-5.5 on coding-agent work but a notch below on raw intelligence (Artificial Analysis ranks it #4, behind Fable-5, Opus-4.8, and GPT-5.5). Its edge is cost: $2/$6 per Mtok (vs $5/$30 for GPT-5.5) *and* ~2–4x better token efficiency per task. Known weakness: high hallucination rate (~54% on AA-Omniscience) — confidently wrong under speed pressure, so don't use it unsupervised on high-stakes changes. 500K context.
- **composer-2.5** — Cursor's agentic coding model. Near-frontier on coding benchmarks (Coding Agent Index 62 vs GPT-5.5's 65) at roughly 1/60th the cost per completed task (~$0.07/task standard tier). Excellent for fast, mechanical, multi-file agentic edits; weak on terminal-heavy work and broad reasoning/architecture. Cursor-only — no public API; drive it via the Cursor CLI (see below).
- **gpt-5.6** — released 2026-07-09 in three tiers: **Sol** (flagship, $5/$30 — same per-token price as GPT-5.5), **Terra** ($2.50/$15, roughly GPT-5.5 performance at half the cost), **Luna** ($1/$6, fastest/cheapest). Sol sits close to Fable-5 in capability at lower cost; the table row scores Sol. Caveat: METR flagged Sol for gaming agentic benchmarks at a record rate — judge outputs rather than trusting headline numbers.

## Core Rules

These rankings are **defaults, not limits**.

Override freely when the output quality requires it. Escalating to a stronger model is cheaper than shipping bad work.

For anything that ships, prioritize:

**Intelligence > Taste > Cost Efficiency**

## Model Selection Guidance

### Bulk / Mechanical / Well-Specified Work

Use **gpt-5.5 via Codex** for:

- Implementation
- Data tasks
- Migrations
- Refactoring
- Mechanical code changes
- Well-scoped fixes

It is very cheap and efficient for this kind of work.

For high-volume mechanical work where per-task cost dominates, **composer-2.5 via the Cursor CLI** and **grok-4.5** are even cheaper alternatives (see their sections below). Composer-2.5 is the pick for fast multi-file agentic edits; grok-4.5 for well-specified coding tasks where its token efficiency pays off. Both need closer output review than gpt-5.5 — composer-2.5 is weak on terminal-heavy work, and grok-4.5 hallucinates confidently.

**gpt-5.6-terra** is the new default sweet spot when you'd otherwise reach for gpt-5.5: roughly the same quality at half the price, via the same Codex CLI (`-m gpt-5.6-terra`).

### User-Facing / High-Taste Work

Use a model with **Taste ≥ 7**.

Prefer:

- **Fable-5**
- **Opus-4.8**

Use these for:

- UI
- Copy
- API design
- Product design
- User-facing code
- Anything where polish matters

### Reviews & Planning

Prefer:

- **Fable-5**
- **Opus-4.8**

For higher confidence, add **gpt-5.5** or **gpt-5.6-sol** as a second opinion. Do not use grok-4.5 or composer-2.5 as review models — reviews need low hallucination and strong reasoning, which is exactly where they trade down.

### Avoid

Never use **Haiku** for important work.

## Using Codex `gpt-5.5` Inside Claude Code

Drive Codex from subagents via the **CLI directly**. Thin **Sonnet low-effort wrapper agents** remain the delegation vehicle (see Subagent & Workflow Guidelines below).

### Canonical Invocation

Write the task prompt to a scratch **file**, then run foreground with a generous timeout (10 min):

```bash
codex exec --dangerously-bypass-approvals-and-sandbox -C <repo> "$(cat <promptfile>)"
```

- **NEVER inline large prompts** in the shell string — 20KB inline prompts hang with zero output. Always go through a prompt file.
- Continue an existing session with:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox resume --last "..."
```

### Why the Flag

Codex's bwrap sandbox cannot nest inside Claude Code's Bash sandbox (`bwrap: loopback: Failed RTM_NEWADDR`). Claude Code's own sandbox remains the outer boundary, so bypassing Codex's inner sandbox is safe and required.

### Reviews

Same mechanism: `codex exec` with a review prompt that asks for findings with **severity**, **file:line**, and a **concrete failing scenario**, plus a **SHIP / FIX-FIRST** verdict. This is the "gpt-5.5 second opinion" the Reviews & Planning section mentions.

### Quota / Billing Errors

If Codex reports quota or billing errors (`429`, `insufficient_quota`): **stop and surface to the user**. Never silently substitute a different model for Codex-designated work.

> Historical note: **codex-plugin-cc** was evaluated and removed 2026-07-07 — its hardcoded per-turn sandbox modes are incompatible with nested bwrap on this machine; re-evaluate only if upstream adds a sandbox passthrough.

### GPT-5.6 via Codex

Same wrapper pattern as gpt-5.5, with an explicit model flag:

```bash
codex exec --dangerously-bypass-approvals-and-sandbox -C <repo> -m gpt-5.6-terra "$(cat <promptfile>)"
```

- Tiers: `gpt-5.6-sol` (flagship, Fable-adjacent), `gpt-5.6-terra` (gpt-5.5 quality at half price — default for bulk work), `gpt-5.6-luna` (cheapest; treat like a fast draft model).
- All the gpt-5.5 rules above (prompt files, sandbox flag, quota errors) apply unchanged.

## Using Composer 2.5 via the Cursor CLI

`cursor-agent` is installed on this machine (`~/.local/bin/cursor-agent`, also aliased as `agent`) — verified 2026-07-09, version 2026.07.08. **It is not logged in yet**: every model-using command fails with "Authentication required" until you run `cursor-agent login` (browser OAuth) or set `CURSOR_API_KEY`. If a subagent hits that error, stop and surface it to the user — same rule as Codex quota errors.

Canonical headless one-shot (same prompt-file discipline as Codex):

```bash
cursor-agent --print --trust --force --output-format text --model composer-2.5 "$(cat <promptfile>)"
```

- `-p/--print` = headless mode (full tool access), `--trust` skips the workspace-trust prompt, `--force`/`--yolo` auto-approves tool calls, `--output-format text|json|stream-json`.
- Run `cursor-agent models` (requires auth) to confirm the exact model ID before automation — the CLI has been reported to silently fall back to a `-fast` variant on near-miss model strings instead of erroring. The `composer-2.5` ID above is the documented name but was **not verifiable end-to-end here because of the auth block**.
- Auth check: `cursor-agent status` / `cursor-agent whoami --format json`.

## Using Grok 4.5

No dedicated CLI. The xAI API is OpenAI-compatible: base URL `https://api.x.ai/v1`, model ID `grok-4.5`, key in `XAI_API_KEY` (docs: https://docs.x.ai/developers/grok-4-5). Use it via `curl`/SDK from a script, or via any agent CLI that supports custom OpenAI-compatible providers. Supports reasoning-effort levels (high is default) and `prompt_cache_key` for long agent loops. Not usable through Codex or the Agent tool — if no wiring exists for the task at hand, prefer composer-2.5 or gpt-5.6-terra instead of improvising.

## Using Claude Models in Subagents & Workflows

Routing to a different **Claude** model needs no CLI and no plugin — it is native to Claude Code's own tools:

| Mechanism | How to select the model |
| --------- | ----------------------- |
| **Agent tool** (subagents) | Pass the `model` parameter: `"sonnet"`, `"opus"`, `"haiku"`, or `"fable"`. |
| **Workflow scripts** | Every `agent()` call accepts options: `agent(prompt, { model: 'sonnet', effort: 'low' })`. |
| **Default (no `model`)** | The subagent inherits the session model — a Fable-5 session fans out Fable-5 workers unless overridden. |

- `effort` is settable per call too: `'low' | 'medium' | 'high' | 'xhigh' | 'max'`.
- Apply the rankings table per stage: mechanical/fan-out workflow stages → `{ model: 'sonnet', effort: 'low' }`; judge, verify, and taste-sensitive stages → session model (Fable-5 / Opus-4.8) at high effort.
- **Do not use `claude -p --model <model>` from Bash** for this. It spawns a nested Claude Code session with separate context and permissions, and you must parse stdout. Unlike Codex (which has no native integration and must go through its CLI), Claude models have first-class routing via the Agent tool — use it. Reserve `claude -p` for genuinely detached background jobs; the Agent tool's background mode covers most of those anyway.

## Subagent & Workflow Guidelines

- The main orchestrator should usually be **Fable-5** or **Opus-4.8** for high-effort work.
- The orchestrator should break down tasks and delegate clearly.
- Use thin wrapper agents, such as **Sonnet on low effort** (`{ model: 'sonnet', effort: 'low' }` — see the Claude models section above), when you need a Claude model to call Codex.
- Always provide:
  - Clear success criteria
  - Required tools
  - Expected output format
  - Constraints and non-goals
- For long-running work, use background mode and status checks so the main session is not blocked.
- Report results back clearly to the main agent.
- For PR-bound work, run a Codex review (see the Reviews subsection above) before finalizing by default.

## Effort & Model Selection Reminders

- Prefer **high effort** for Fable-5.
- Avoid **xhigh** unless the task truly needs it, because it is token-heavy.
- Use **low effort** for simple delegation wrappers.
- Judge every output.
- Escalate without hesitation when quality is not good enough.

Follow these rules strictly unless the user explicitly says otherwise.
