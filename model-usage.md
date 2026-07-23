# Model Usage — HOW to Invoke Each Model

This file is the mechanics reference: once you already know which model you want
(see `~/.claude/model-selection.md` for choosing), this is how you drive it.

**Every route below is live-verified** by `bash ~/dotfiles/claude/tests/routecheck.sh`
(alias `routecheck`), which smokes each model through the same entrypoint you
use. A SessionStart hook warns when routing is broken or the last check is
stale. If a route fails for you, run `routecheck`, then fix or remove the entry.

## The Canonical Path (non-Claude models)

There is exactly ONE way to invoke a non-Claude model. Do not hand-roll `codex`
or `cursor-agent` commands — a PreToolUse hook (`route-guard`) blocks them.

**Delegating (the normal case):** spawn the **`model-runner`** agent (a named
agent installed from this repo). Tell it the model id — or just a task type —
plus the prompt (or prompt file path), and optionally a workdir. It runs the
script below and returns the model's output verbatim, with all error rules
baked in. Preferred over direct Bash for delegations because it appears as a
named agent in the workflow/agent progress UI instead of an opaque background
process.

**Direct call (quick inline one-offs, scripts, or when you ARE the wrapper):**

```bash
bash ~/dotfiles/claude/bin/model-run.sh <model-id> <promptfile> [workdir]
bash ~/dotfiles/claude/bin/model-run.sh --task-type bulk|cheap|recency|second-review <promptfile> [workdir]
```

- `--task-type` resolves the model id deterministically from the table — prefer
  it when the task fits a class; pass an explicit id only when overriding.
- Prompts are ALWAYS passed via file — the script rejects missing/empty files.
- Timeout 600s (override: `MODEL_RUN_TIMEOUT=<secs>`).
- Exit codes: `0` success · `64` usage/bad-id (the error lists valid ids) ·
  `75` **auth/quota — STOP and surface to the user, never substitute a model** ·
  `124` timeout.

**`bin/routes.tsv` is the single source of truth** for model ids, id→backend
routing, retired-id successors, and task-type mappings. The script, its error
messages, and routecheck's test matrix all derive from it. When the catalog
changes, edit routes.tsv (only), then run `routecheck`. Current ids: run
`bash ~/dotfiles/claude/bin/model-run.sh` with no args, or read the tsv.

## Claude Models (sonnet / opus / haiku / fable)

Native to Claude Code — no CLI, no wrapper, not model-run.sh's job:

| Mechanism | How to select the model |
| --------- | ----------------------- |
| **Agent tool** (subagents) | `model` parameter: `"sonnet"`, `"opus"`, `"haiku"`, or `"fable"`. |
| **Workflow scripts** | `agent(prompt, { model: 'sonnet', effort: 'low' })`. |
| **Default (no `model`)** | Inherits the session model — a Fable-5 session fans out Fable-5 workers unless overridden. |

- `effort` per call: `'low' | 'medium' | 'high' | 'xhigh' | 'max'`.
- **Do not use `claude -p --model <model>` from Bash** for routing — nested
  session, separate context/permissions, stdout parsing. Reserve `claude -p`
  for genuinely detached background jobs.

## Under the Hood (reference only — route-guard blocks running these directly)

What `model-run.sh` executes, kept here so its behavior is auditable and so a
raw invocation can be reconstructed *with the user's explicit approval*:

- **Codex:** `codex exec --dangerously-bypass-approvals-and-sandbox -C <workdir> [-m <model>] "$(cat <promptfile>)"`
  — the bypass flag is required because Codex's bwrap sandbox cannot nest inside
  Claude Code's Bash sandbox (`bwrap: loopback: Failed RTM_NEWADDR`); Claude
  Code's own sandbox remains the outer boundary. Session continuation:
  `codex exec ... resume --last "..."`.
- **Cursor:** `cursor-agent --print --trust --force --output-format text --model <id> "$(cat <promptfile>)"`
  — unknown ids hard-error with the full valid list, but *retired* ids can
  silently remap to a successor (e.g. `composer-2` → 2.5); model-run.sh and
  routecheck exist precisely to catch that class. Check auth with
  `cursor-agent status`; list ids with `cursor-agent --list-models` (both
  allowed by the guard). The Cursor catalog also exposes OpenAI/Anthropic/
  Google models — route those through their native paths instead.
- **Reviews via Codex:** same path — prompt asks for findings with **severity**,
  **file:line**, a **concrete failing scenario**, and a **SHIP / FIX-FIRST**
  verdict.

> **Cursor TypeScript SDK (`@cursor/sdk`): evaluated 2026-07-21, rejected.** Two
> independent reviews (gpt-5.6-sol, grok-4.5) both concluded STAY-ON-CLI: the CLI
> already covers streaming/resume/model-listing; the SDK would mean a bespoke Node
> wrapper + npm surface in this repo, plain-`string` model ids (no added safety),
> and possible consumption billing vs the already-paid seat. Re-evaluate only if
> the CLI loses capabilities or the SDK gains subscription-seat auth.
>
> **codex-plugin-cc**: evaluated and removed 2026-07-07 — hardcoded per-turn
> sandbox modes incompatible with nested bwrap here.

## Direct xAI API (grok-4.5) — UNWIRED, do not use

**Status: not set up on this machine (`XAI_API_KEY` is not set). Do not attempt
this route — use `cursor-grok-4.5-high` via model-run.sh instead.** Kept only as
wiring notes for if the user ever asks for it: OpenAI-compatible, base URL
`https://api.x.ai/v1`, model id `grok-4.5`, key in `XAI_API_KEY` (docs:
https://docs.x.ai/developers/grok-4-5). Live search = Agent Tools (`web_search`,
`x_search`) on the Responses API, $5 per 1k successful invocations (the old
Live Search `search_parameters` API is dead — HTTP 410). $2/$6 per Mtok, cached
input $0.30, rates double past a 200k-token prompt.
