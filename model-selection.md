# Model Selection — WHICH Model, WHEN

Read this before ANY delegation — every Agent-tool subagent and every Workflow
`agent()` call, not just big fan-outs. Once you know which model you want,
`~/.claude/model-usage.md` has the canonical invocation for it.

## Model Rankings

Scores are **1–10, higher is better**. Last validated **2026-07-21** against
Artificial Analysis, Coding Agent Index, LMArena/Design Arena, and vendor pricing
(two independent research passes: Claude web research + grok-4.5 recent-intel).

- **Cost efficiency** = cost **per completed task**, not per token. (Per-token
  intuition inverts rankings: sonnet-5 has cheaper tokens than opus-4.8 but burns
  ~40% more tokens per task, landing ~15% more expensive per task.)
- **Intelligence** = ability on hard, unsupervised problems.
- **Taste** = UI/UX judgment, code quality, API design, copy quality.
- **Reliability** = trustworthiness unsupervised: hallucination rate, honesty
  under eval pressure, instruction adherence. This axis decides whether a
  delegation can run without close output review.

| Model        | Cost Efficiency | Intelligence | Taste | Reliability |
| ------------ | --------------- | ------------ | ----- | ----------- |
| composer-2.5 | 10              | 6            | 4*    | 5*          |
| grok-4.5     | 10              | 7            | 4     | 3           |
| glm-5.2      | 9               | 7            | 7     | 6*          |
| gpt-5.6-terra| 8               | 7            | 6     | 7           |
| kimi-k3      | 7               | 8            | 8     | 6*          |
| gpt-5.6-sol  | 7               | 9            | 6     | 5           |
| gpt-5.5      | 6               | 7            | 5     | 7           |
| opus-4.8     | 5               | 7            | 8     | 9           |
| sonnet-5     | 4               | 7            | 7     | 8           |
| fable-5      | 2               | 9            | 9     | 9           |

`*` = thin public evidence; treat as provisional.

Notes (evidence-backed, 2026-07-21):

- **grok-4.5** — $2/$6 per Mtok (cached input $0.30; 2× rates past 200k prompt),
  AA Intelligence 53.8 (#4). Reliability 3: **54% hallucination on
  AA-Omniscience** — confidently wrong under speed pressure. Never unsupervised
  on high-stakes changes; never a review model. 500K context.
- **composer-2.5** — Cursor-only. Coding Agent Index 62, ~$0.07/task standard
  tier. Fast multi-file agentic edits; weak on terminal-heavy work and broad
  architecture. Taste/reliability scores are unverified (absent from preference
  boards).
- **gpt-5.6** (GA 2026-07-09) — **Sol** ($5/$30) AA 58.9, and OpenAI claims
  Coding Agent Index 80 at max effort; but **METR flagged Sol for record
  eval-gaming** (honesty-suite metagaming 55.4% vs gpt-5.5's 41.2%; METR called
  its Time Horizon results unusable) — hence Reliability 5. Judge its outputs,
  don't trust its self-reports. **Terra** ($2.50/$15, AA 55.0) is the bulk-work
  default. **Luna** ($1/$6): fast-draft tier only.
- **gpt-5.5** — superseded: same $5/$30 price as Sol with less capability;
  Terra beats it on both axes at half price. Kept only because Codex defaults to
  it; prefer `-m gpt-5.6-terra`.
- **sonnet-5** — Int raised to 7 (AA 53.4, statistically tied with grok-4.5).
  CE lowered to 4 (see per-task note above; intro $2/$10 pricing ends
  2026-08-31, then $3/$15).
- **opus-4.8** — $5/$25; cheaper per task than sonnet-5 on agentic work.
- **fable-5** — $10/$50; AA #1 (59.9), LMArena text #1. The quality ceiling.
- **kimi-k3** (Moonshot, released 2026-07-16) — AA 57.1 (above opus-4.8), $3/$15,
  **#1 Arena WebDev** (ahead of fable-5); open weights, on OpenRouter. Very new —
  verify outputs until a track record accumulates. (The `kimi-k2.7-code` in
  Cursor's catalog is the older cheaper sibling, $0.95/$4 on Foundry.)
- **glm-5.2** (Z.ai, early July 2026) — $1.40/$4.40, MIT weights; beats gpt-5.5
  on SWE-bench Pro (62.1 vs 58.6) at ~1/6 cost; leads Design Arena Website —
  real taste signal for a budget model. Available in Cursor's catalog
  (`glm-5.2-high`/`-max`) and OpenRouter.

## Core Rules

These rankings are **defaults, not limits** — override freely when output
quality requires it. Escalating to a stronger model is cheaper than shipping bad
work. For anything that ships:

**Intelligence > Taste > Cost Efficiency**

And the new axis's rule: **only models with Reliability ≥ 7 run unsupervised.**
Anything lower (grok-4.5, composer-2.5, gpt-5.6-sol) needs its output judged by
you or a high-reliability model before it lands.

## Selection by Task Type

### Bulk / Mechanical / Well-Specified Work

**gpt-5.6-terra via Codex** is the default (gpt-5.5 quality at half price).
Cheaper still, with closer output review required: **composer-2.5** (fast
multi-file agentic edits; avoid terminal-heavy tasks) and **grok-4.5**
(well-specified tasks where token efficiency pays; hallucinates confidently).
**glm-5.2** is a promising budget alternative via the Cursor catalog.

### User-Facing / High-Taste Work

Use Taste ≥ 7: **fable-5**, **opus-4.8** (also **sonnet-5** for lighter work).
For UI, copy, API design, product design — anything where polish matters.
**kimi-k3** is worth trialing on web UI work given its Arena WebDev standing,
but review its output like the new model it is.

### Reviews & Planning

**fable-5** or **opus-4.8**. For higher confidence add **gpt-5.6-sol** or
**gpt-5.5** as a second opinion (ask for severity, file:line, concrete failing
scenario, SHIP / FIX-FIRST verdict). **Never grok-4.5 or composer-2.5 as review
models** — reviews need low hallucination and strong reasoning, exactly where
they trade down. Treat sol's verdicts with its METR caveat in mind: judge the
findings, not its confidence.

### Recent Information / Research

**grok-4.5 is the default for anything time-sensitive**: xAI's server-side
`web_search` and `x_search` agent tools give it live web plus real-time X-stream
access no other API model has ($5 per 1k successful tool calls on top of $2/$6
tokens). Use it for breaking news, social sentiment, "what happened this week"
research, and cross-checking another agent's claims about recent releases.

Caveats, applied strictly:

- **Do not trust its unsourced recall** — 54% AA-Omniscience hallucination rate.
  Require citations with dates in the prompt; treat uncited recent "facts" as
  unverified. Its training cutoff is 2026-02-01; freshness comes from the search
  tools, not the model.
- Its edge is specifically the **X stream and cheap tokens for search-heavy
  loops**. For ordinary web recency, Claude's native WebSearch is fine — don't
  route to grok just because a question mentions a date.
- Via Cursor CLI (`cursor-grok-4.5-high`) for general recent-info prompts; the
  direct xAI Responses API (see model-usage.md) only when you specifically need
  `x_search` or search-parameter control. (The old Live Search API is dead —
  HTTP 410.)

### Avoid

Never use **Haiku** for important work. Never silently substitute a model when
the designated one errors — stop and surface (see model-usage.md).

## Subagent & Workflow Guidelines

- Main orchestrator: **fable-5** or **opus-4.8** at high effort.
- Thin CLI wrapper agents (the delegation vehicle for Codex/Cursor models):
  **sonnet, low effort** — their only job is run-command-return-stdout.
- Workflow stages: mechanical fan-out stages → `{ model: 'sonnet', effort:
  'low' }`; judge, verify, and taste-sensitive stages → session model (fable-5 /
  opus-4.8) at high effort. Prefer effort `'high'` for fable-5; avoid `'xhigh'`
  unless truly needed; `'low'` for simple wrappers.
- Always give delegated agents: clear success criteria, required tools, expected
  output format, constraints and non-goals.
- Long-running work: background mode + status checks; report results clearly.
- PR-bound work: run a Codex review before finalizing by default.
- Judge every output. Escalate without hesitation when quality isn't there.

## Keeping This File Honest

The table above is a snapshot; model catalogs and pricing drift. The
model-routing testing suite (see `plans/model-routing-test-suite.md` in the
dotfiles repo) checks that the ids referenced here and in model-usage.md still
exist. When a benchmark or price claim matters to a decision, re-verify it —
grok-4.5 with citations is the cheap way to do that.

Follow these rules strictly unless the user explicitly says otherwise.
