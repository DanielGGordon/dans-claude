# Model Strategy & Subagent / Workflow Delegation

## Model Rankings

Scores are **1–10, where higher is better**.

- **Cost efficiency** = cheaper / more efficient for your actual spend.
- **Intelligence** = ability on hard, unsupervised problems.
- **Taste** = UI/UX judgment, code quality, API design, and copy quality.

| Model    | Cost Efficiency | Intelligence | Taste |
| -------- | --------------- | ------------ | ----- |
| gpt-5.5  | 9               | 8            | 5     |
| sonnet-5 | 5               | 5            | 7     |
| opus-4.8 | 4               | 7            | 8     |
| fable-5  | 2               | 9            | 9     |

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

For higher confidence, add **gpt-5.5** as a second opinion.

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
