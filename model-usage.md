# Model Usage — HOW to Invoke Each Model

This file is the mechanics reference: once you already know which model you want
(see `~/.claude/model-selection.md` for choosing), this is how you drive it.

**Every route below is live-verified** by `bash ~/dotfiles/claude/tests/routecheck.sh`
(alias `routecheck`), which smokes each model through the same entrypoint you
use. A SessionStart hook warns when routing is broken, the last check is stale,
or the live Cursor/Codex catalogs have drifted from `bin/routes.tsv` (a newer
`cursor-grok-*` / `composer-*` / `glm-*` / `gpt-*` version, or a routed id that
vanished — `bin/catalog-drift.sh`). If a route fails for you, run `routecheck`,
then fix or remove the entry. catalog-drift also lists **unrouted** catalog ids
(new tiers/families no routes.tsv row accounts for; `--unrouted`), and the daily
model scout (`bin/model-scout.sh`, cron) researches them, updates routes.tsv +
these docs, re-runs routecheck and opens a PR — see the README's "Model scout".

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
bash ~/dotfiles/claude/bin/model-run.sh --task-type bulk|cheap|recency|second-review|fable-fallback <promptfile> [workdir]
```

- `--task-type` resolves the model id deterministically from the table — prefer
  it when the task fits a class; pass an explicit id only when overriding.
  Types: `bulk` · `cheap` · `recency` · `second-review` · `fable-fallback`
  (→ `gpt-6-astra`, for work a Fable subagent can no longer take — see
  model-selection.md).
- Prompts are ALWAYS passed via file — the script rejects missing/empty files.
- Timeout 600s (override: `MODEL_RUN_TIMEOUT=<secs>`).
- Exit codes: `0` success · `64` usage/bad-id (the error lists valid ids) ·
  `73` transport error persisting after the script's one automatic retry
  (provider/network degradation — retry later, don't switch models unasked) ·
  `75` **auth/quota — STOP and surface to the user, never substitute a model** ·
  `124` timeout.

### Reasoning effort (Codex models only)

Codex applies each model's **catalog default** reasoning level unless told
otherwise, and for the frontier tiers that default is **`low`** (`gpt-6-astra`
and `gpt-5.6-sol` both ship `default_reasoning_level: low`) — i.e. the most
capable model arrives at its weakest setting if nobody pins it. So the effort
lives in the routing table, not in your prompt:

- `bin/routes.tsv` has an optional **4th column** on `model` rows (codex only):
  the reasoning effort for that id. `gpt-6-astra` is pinned to **`high`**;
  everything else is blank (= backend default).
- Override for one call with `MODEL_RUN_EFFORT=<low|medium|high|xhigh|max>`
  (e.g. `MODEL_RUN_EFFORT=xhigh bash ~/dotfiles/claude/bin/model-run.sh
  gpt-6-astra prompt.md`). Ignored with a warning on cursor-backed models.
- The Codex banner echoes what it actually used (`reasoning effort: high`) —
  check it when a run looks lazier than expected.
- Astra's catalog also lists an **`ultra`** level ("maximum reasoning with
  automatic task delegation"). It is deliberately **not** wired in: it lets the
  model spawn its own delegated sub-tasks, which is a different cost and
  supervision story. Don't pass it without asking the user first.

**`bin/routes.tsv` is the single source of truth** for model ids, id→backend
routing, retired-id successors, and task-type mappings. The script, its error
messages, routecheck's test matrix and the catalog-drift check all derive from
it. When the catalog changes, edit routes.tsv (only), then run `routecheck`.
Current ids: run `bash ~/dotfiles/claude/bin/model-run.sh` with no args, or
read the tsv. Codex: `gpt-6-astra` is the frontier tier (GPT-6, effort pinned to
`high`); `gpt-5.6-terra` stays the bulk default. Grok: `grok-4.7-*` is
the default (`--task-type recency` → `grok-4.7-high`; note these ids have no
`cursor-` prefix, unlike the legacy ones); `cursor-grok-4.6-*` and
`cursor-grok-4.5-*` are legacy but still routable.

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
- **When Fable is out of quota** (an Agent/Workflow call with `model: 'fable'`
  comes back with a usage-limit / model-unavailable error): do NOT silently
  retry on opus or sonnet. Re-dispatch that subagent's prompt through the
  `model-runner` agent with `--task-type fable-fallback` (→ `gpt-6-astra`),
  keeping the same success criteria and output format, and tell the user which
  model actually ran. Why `model-run.sh` and not a Claude retry: Astra is the
  only other model in this stack at Fable's intelligence tier, and the routing
  table makes the substitution auditable instead of ad hoc. If Astra's own
  backend then errors 75 (auth/quota), stop and surface — no third hop.

## Under the Hood (reference only — route-guard blocks running these directly)

What `model-run.sh` executes, kept here so its behavior is auditable and so a
raw invocation can be reconstructed *with the user's explicit approval*:

- **Codex:** `codex exec --dangerously-bypass-approvals-and-sandbox -C <workdir> [-m <model>] [-c model_reasoning_effort="<level>"] "$(cat <promptfile>)"`
  — the bypass flag is required because Codex's bwrap sandbox cannot nest inside
  Claude Code's Bash sandbox (`bwrap: loopback: Failed RTM_NEWADDR`); Claude
  Code's own sandbox remains the outer boundary. Session continuation:
  `codex exec ... resume --last "..."`. With `MODEL_RUN_EPHEMERAL=1` it adds
  `--ephemeral` (no session files / thread rows) — for **test** calls only
  (routecheck, the model scout, the orchestration smoke); real delegations stay
  persisted so their history is useful.
- **Cursor:** `cursor-agent --print --trust --force --output-format text --model <id> "$(cat <promptfile>)"`
  — unknown ids hard-error with the full valid list, but *retired* ids can
  silently remap to a successor (e.g. `composer-2` → 2.5); model-run.sh and
  routecheck exist precisely to catch that class. Check auth with
  `cursor-agent status`; list ids with `cursor-agent --list-models` (both
  allowed by the guard, as is `codex debug models`, the Codex catalog read).
  `bash ~/dotfiles/claude/bin/catalog-drift.sh` diffs those catalogs against
  routes.tsv. The Cursor catalog also exposes OpenAI/Anthropic/Google models —
  route those through their native paths instead (routes.tsv marks such ids
  with `ignore <glob> <reason>` rows so they stop showing as unrouted). Cursor
  has no ephemeral mode: its chats are keyed by cwd (`~/.cursor/chats/<md5(cwd)>`),
  so a test call must use a throwaway `mktemp -d` workdir and then run
  `bin/test-chat-cleanup.sh --since <epoch> --marker <str> --workdir <dir>`.
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

## Direct xAI API (grok) — UNWIRED, do not use

**Status: not set up on this machine (`XAI_API_KEY` is not set). Do not attempt
this route — use `grok-4.7-high` (or `--task-type recency`) via
model-run.sh instead.** Kept only as wiring notes for if the user ever asks for
it (written against grok-4.5; re-check ids/pricing for 4.7): OpenAI-compatible,
base URL `https://api.x.ai/v1`, model id `grok-4.5`, key in `XAI_API_KEY` (docs:
https://docs.x.ai/developers/grok-4-5). Live search = Agent Tools (`web_search`,
`x_search`) on the Responses API, $5 per 1k successful invocations (the old
Live Search `search_parameters` API is dead — HTTP 410). $2/$6 per Mtok, cached
input $0.30, rates double past a 200k-token prompt.
