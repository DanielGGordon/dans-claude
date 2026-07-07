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

Use **codex-plugin-cc** for native integration.

Avoid raw bash wrappers when possible.

### Available Commands

| Command                             | Purpose                                                                                                      |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `/codex:review`                     | Standard code quality review. Supports `--base <ref>` for branch reviews.                                    |
| `/codex:adversarial-review`         | Skeptical review that pressure-tests design, security, and tradeoffs. Append custom instructions as needed.  |
| `/codex:rescue`                     | Delegate debugging, refactoring, or implementation loops to Codex.                                           |
| `/codex:status`                     | Check background / async Codex jobs.                                                                         |
| `/codex:result`                     | Retrieve results from Codex jobs.                                                                            |
| `/codex:cancel`                     | Cancel a running Codex job.                                                                                  |
| `/codex:setup --enable-review-gate` | Enable the automatic Codex challenge before finalizing changes.                                              |

For subagents and workflows, instruct them to use the slash commands above or exposed `codex-cli-runtime` skills directly.

## Using Claude Models in Subagents & Workflows

Routing to a different **Claude** model needs no CLI and no plugin — it is native to Claude Code's own tools:

| Mechanism | How to select the model |
| --------- | ----------------------- |
| **Agent tool** (subagents) | Pass the `model` parameter: `"sonnet"`, `"opus"`, `"haiku"`, or `"fable"`. |
| **Workflow scripts** | Every `agent()` call accepts options: `agent(prompt, { model: 'sonnet', effort: 'low' })`. |
| **Default (no `model`)** | The subagent inherits the session model — a Fable-5 session fans out Fable-5 workers unless overridden. |

- `effort` is settable per call too: `'low' | 'medium' | 'high' | 'xhigh' | 'max'`.
- Apply the rankings table per stage: mechanical/fan-out workflow stages → `{ model: 'sonnet', effort: 'low' }`; judge, verify, and taste-sensitive stages → session model (Fable-5 / Opus-4.8) at high effort.
- **Do not use `claude -p --model <model>` from Bash** for this. It spawns a nested Claude Code session with separate context and permissions, and you must parse stdout — the same raw-wrapper antipattern the Codex section avoids. Reserve it for genuinely detached background jobs; the Agent tool's background mode covers most of those anyway.

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
- Keep the review gate enabled by default for PR-bound work.

## Effort & Model Selection Reminders

- Prefer **high effort** for Fable-5.
- Avoid **xhigh** unless the task truly needs it, because it is token-heavy.
- Use **low effort** for simple delegation wrappers.
- Judge every output.
- Escalate without hesitation when quality is not good enough.

Follow these rules strictly unless the user explicitly says otherwise.
