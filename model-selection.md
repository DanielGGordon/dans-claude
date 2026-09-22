# Model Selection — WHICH Model, WHEN

Read this before ANY delegation — every Agent-tool subagent and every Workflow
`agent()` call, not just big fan-outs. Once you know which model you want,
`~/.claude/model-usage.md` has the canonical invocation for it.

## Model Rankings

Scores are **1–10, higher is better**. Last validated **2026-07-21** against
Artificial Analysis, Coding Agent Index, LMArena/Design Arena, and vendor pricing
(two independent research passes: Claude web research + grok-4.5 recent-intel);
**gpt-6-astra added 2026-09-18** from a grok-4.6 citation-backed pass plus
Claude web research (sources in its note below). **grok-4.7 added 2026-09-22**
(surfaced by `bin/catalog-drift.sh`'s newer-version warning the moment the
Cursor catalog listed it); its scores are an unbenchmarked copy of
grok-4.6/4.5's, same as 4.6 was a copy of 4.5's when it launched.

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
| gpt-6-astra  | 6               | 9            | 8     | 6           |
| grok-4.7*    | 10*             | 7*           | 4*    | 3*          |
| grok-4.6*    | 10*             | 7*           | 4*    | 3*          |
| grok-4.5     | 10              | 7            | 4     | 3           |
| glm-5.2      | 9               | 7            | 7     | 6*          |
| gpt-5.6-terra| 8               | 7            | 6     | 7           |
| gpt-5.6-sol  | 7               | 9            | 6     | 5           |
| gpt-5.5      | 6               | 7            | 5     | 7           |
| opus-4.8     | 5               | 7            | 8     | 9           |
| sonnet-5     | 4               | 7            | 7     | 8           |
| fable-5      | 2               | 9            | 9     | 9           |

`*` = thin public evidence; treat as provisional.

**Benchmark numbers below come from different index versions — never mix them.**
The pre-2026-09 rows quote AA Intelligence Index **v4.1.1** (fable-5 59.9,
gpt-5.6-sol 58.9, grok-4.5 53.8); the gpt-6-astra note quotes **v4.3**
(2026-09-07), where the whole scale shifted down: Astra 53, Fable 5.1 53,
Opus 5 51, Sol 47. A v4.3 number is not comparable to a v4.1.1 number — AA's
methodology moved twice in the four days after Astra launched (v4.1.1 61 →
v4.2 55, Fable leading → v4.3 53, tied), so pin every claim to a version and
treat any *standing* ("#1", "tied") as provisional even when the score is
sourced.

- **grok-4.7** is the grok row that matters now: it is the **default grok**
  (`--task-type recency` → `grok-4.7-high`; routed 2026-09-22 as
  `grok-4.7-{high,high-fast,xhigh,medium,low}` — note these ids have **no
  `cursor-` prefix** in the Cursor catalog, unlike 4.6/4.5). Its row is
  **entirely provisional** — no benchmark or pricing data has been gathered
  for it here; every score is a copy of grok-4.6's (itself a copy of
  grok-4.5's), and grok-4.5's caveats (54% AA-Omniscience hallucination, never
  unsupervised on high-stakes changes, never a review model) apply unchanged
  until someone re-benchmarks it and updates this table. **grok-4.6**
  (`cursor-grok-4.6-*`) and **grok-4.5** (`cursor-grok-4.5-*`) are now
  **legacy**: still routable while the Cursor catalog lists them, but not the
  default. `bin/catalog-drift.sh` (via `routecheck` and the SessionStart hook)
  warns when a newer grok/composer/glm/gpt version shows up in a catalog so
  the next bump is surfaced at session start, not mid-task.

Notes (evidence-backed, 2026-07-21; the gpt-6-astra note is 2026-09-18):

- **gpt-6-astra** (OpenAI GPT-6 "Astra", GA 2026-09-03; the only GPT-6 tier —
  there is no mini/nano/Terra/Sol sibling) — $10/$50 per Mtok, cached input $1,
  **doubling to $20/$75 for the whole request past 272k input**; 1.05M context,
  128k max output, training cutoff 2026-04-30. Routed here as `gpt-6-astra`
  via Codex.
  - **Intelligence 9** — AA Intelligence Index **v4.3 = 53, tied with Fable
    5.1** (Opus 5 51, Sol 47), and it gets there on ~**27k output tokens/task
    vs Fable's 78k**. Independent Terminal-Bench 4.0 **59.1%** (Fable 5.1 52.0,
    Opus 5 49.0, Sol 39.9). Coding Agent Index in the Codex harness **62**,
    also tied with Fable 5.1.
  - **Cost Efficiency 6** — list price is a bad proxy: the token cut puts it at
    **$3.26 per AA Index task vs Fable 5.1's $7.63**, and ~15% above Sol per
    completed CAI task despite 2.5× list. Still 2.5–5× Terra/Sol for work that
    doesn't need it, and it burns subscription quota fast.
  - **Taste 8, lopsided** — **#1 overall on Design Arena** (68% WR) and #1 in
    each of 3D Design (74%), SVG, Game Dev and UI Component (Data Visualization
    is its one weak board, #6), plus #1 on LMArena Code/WebDev Arena (1800 vs
    Fable 5.1's 1758) — but **LMArena Text Arena overall #24** and a measured
    *regression* vs Sol on presentation Elo and GDPval-AA. Great at generating
    interfaces and scenes; not the model for prose, copy, or a deck. (Scored 8
    rather than 9 only because those weak boards are real; on generated design
    alone it is at Fable's level.)
  - **Reliability 6** — better than Sol on every honesty axis (AA-Omniscience
    hallucination **51% vs Sol's 92%**; OpenAI-internal hallucination 4.2% vs
    12.2%; 0% vs 48.2% out-of-scope actions on the ExploitGym honeypot; no METR
    eval-gaming finding — **METR has not published on Astra at all**). Still
    under the unsupervised bar: 51% is half of its unsourced answers wrong, and
    OpenAI's own system card says that if it *were* told to sandbag, CoT
    monitors would catch it <11% of the time ("we would likely be unable to
    catch it reliably"). Operationally it also **over-tests small changes, asks
    more clarifying questions, and under-delegates subagents** unless told, and
    OpenAI's misalignment monitoring can pause a Codex task outright — Astra is
    the **first OpenAI model classified Critical for cyber capability** under
    the Preparedness Framework (ExploitBench 100%), so exploit-adjacent work
    hits extra gating and API hard-stops. Budget for interruptions on
    security-flavored tasks rather than being surprised by them.
  - Sources: OpenAI launch post + system card (2026-09-03/09-09), Artificial
    Analysis Index v4.3 + Astra writeup (2026-09-07/09-09), ARC Prize
    (2026-09-03), Design Arena and LMArena boards (fetched 2026-09-18).
  - **UNVERIFIED — do not quote:** any SWE-bench Verified/Pro score for Astra
    (OpenAI published none), a METR time horizon, and the headline ARC-AGI-3
    "99.9%" (that is OpenAI's provider-adapter harness; like-for-like Standard
    harness is **62.7%**).

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
Anything lower (grok-4.7/4.6/4.5, composer-2.5, gpt-5.6-sol, **gpt-6-astra**) needs
its output judged by you or a high-reliability model before it lands. Astra sits
just under the bar despite its intelligence — judge the diff, not its summary of
the diff.

## Selection by Task Type

### Bulk / Mechanical / Well-Specified Work

**gpt-5.6-terra via Codex** is the default (gpt-5.5 quality at half price).
Cheaper still, with closer output review required: **composer-2.5** (fast
multi-file agentic edits; avoid terminal-heavy tasks) and **grok-4.7**
(well-specified tasks where token efficiency pays; hallucinates confidently —
scores inherited from grok-4.6/4.5, see the rankings note).
**glm-5.2** is a promising budget alternative via the Cursor catalog.

### Computer Use, 3D/CAD, and Long Terminal Agents — gpt-6-astra

**gpt-6-astra is the first pick for exactly four shapes of work**, where its
lead over everything else in this stack is measured, not marketing:

1. **Computer use / GUI & browser agents** — OSWorld 2.0 72.6% at ~47% less
   wall-clock per task than Sol (Opus 5 70.2%); ScreenSpot-Pro 92.7% vs Sol
   76.9% / Fable 5.1 87.3%; #1 on AA's AutomationBench over grok-4.6.
2. **3D, CAD, and spatial/scene generation** — BenchCAD 95.9% (Sol 83.3%,
   Fable 5.1 84.3%) and **#1 on Design Arena 3D Design**, Game Dev and SVG.
   Blender/Unreal scene generation from a prompt is its headline demo. Nothing
   else routable here is close.
3. **Long-horizon terminal / agentic coding** — Terminal-Bench 4.0 59.1% vs
   Fable 5.1 52.0 / Opus 5 49.0 / Sol 39.9, at ~1/3 of Sol's tokens.
4. **Hard analysis and science** — FrontierMath Tier 4 97.6%, GPQA Diamond
   96.0%, AA-Briefcase ~+90 Elo over Sol.

Start it at **low or medium effort** for work Sol-high already handled
(OpenAI's own guidance); the route's default pin is `high` (see model-usage.md).
It is **not** a general "best model" upgrade: it ties Fable 5.1 on overall
intelligence, loses to Sol on knowledge-with-tools (HLE 57.2 vs 65.0) and on
DeepSWE, and regresses on presentation. Do not spend Astra tokens on
Terra-shaped bulk work.

### User-Facing / High-Taste Work

Use Taste ≥ 7: **fable-5**, **opus-4.8** (also **sonnet-5** for lighter work).
For UI, copy, API design, product design — anything where polish matters.
**gpt-6-astra** is the exception worth knowing: it is #1 on LMArena's Code/WebDev
Arena and on Design Arena's UI Component, SVG, Game Dev and 3D boards, so it is a
legitimate pick for *generating* an interface, a scene, or a graphic. Keep Claude
for prose, copy, decks, and product judgment — Astra is #24 on Text Arena overall
and measurably worse than Sol on presentation.

### Reviews & Planning

**fable-5** or **opus-4.8**. For higher confidence add a non-Claude second
opinion: **gpt-6-astra** (`--task-type second-review`) is now the default there,
having replaced gpt-5.6-sol on 2026-09-18 — same reviewer role, half the
hallucination rate (AA-Omniscience 51% vs Sol's 92%), higher intelligence, and
no METR eval-gaming finding against it. `gpt-5.6-sol` and `gpt-5.5` stay
routable by id if you want a third voice or a cheaper pass. Ask any of them for
severity, file:line, a concrete failing scenario, and a SHIP / FIX-FIRST
verdict. **Never grok (4.7, 4.6, or 4.5) or composer-2.5 as review models** — reviews
need low hallucination and strong reasoning, exactly where they trade down.
Judge the findings, not the reviewer's confidence: Astra's hallucination rate is
better than Sol's, not low.

### Recent Information / Research

**grok is the default for anything time-sensitive — grok-4.7 via
`grok-4.7-high` (`--task-type recency`)**: xAI's server-side
`web_search` and `x_search` agent tools give grok live web plus real-time
X-stream access no other API model has ($5 per 1k successful tool calls on top
of $2/$6 tokens, grok-4.5 pricing; 4.7's is unverified). Use it for breaking
news, social sentiment, "what happened this week" research, and cross-checking
another agent's claims about recent releases. `cursor-grok-4.6-*` and
`cursor-grok-4.5-*` remain routable as legacy if you need to reproduce an
earlier result.

Caveats, applied strictly:

- **Do not trust its unsourced recall** — 54% AA-Omniscience hallucination rate
  (measured on 4.5; assume the same for 4.7 until re-benchmarked). Require
  citations with dates in the prompt; treat uncited recent "facts" as
  unverified. grok-4.5's training cutoff is 2026-02-01 (4.7's not verified
  here); freshness comes from the search tools, not the model.
- Its edge is specifically the **X stream and cheap tokens for search-heavy
  loops**. For ordinary web recency, Claude's native WebSearch is fine — don't
  route to grok just because a question mentions a date.
- Via Cursor CLI (`grok-4.7-high`, or just `--task-type recency`) for
  general recent-info prompts. Note the id has **no `cursor-` prefix**, unlike
  the legacy 4.6/4.5 ids. The direct xAI Responses API (`x_search` etc.)
  is **unwired on this machine** — see model-usage.md; don't attempt it
  without the user wiring `XAI_API_KEY`.

### Avoid

Never use **Haiku** for important work. Never silently substitute a model when
the designated one errors — stop and surface (see model-usage.md). The one
sanctioned substitution is the Fable-quota fallback below, and it is not silent:
you announce it.

## Subagent & Workflow Guidelines

- Main orchestrator: **fable-5** or **opus-4.8** at high effort.
- Delegations to non-Claude models go through the **`model-runner`** named
  agent (a sonnet wrapper installed from this repo) — give it a model id OR a
  task type (`bulk` / `cheap` / `recency` / `second-review` / `fable-fallback`)
  + prompt file; it invokes `bin/model-run.sh` and returns output verbatim. Prefer task types:
  the table picks the id deterministically, and the mapping lives in
  `bin/routes.tsv`, not in your judgment. Don't hand-roll codex/cursor-agent
  commands; a hook denies them. (Direct `model-run.sh` via Bash is fine for
  quick inline one-offs, but the agent is preferred for delegations — it shows
  up as a named agent in the progress UI instead of a background process.)
- **When Fable is out of quota**, a subagent that was scoped for Fable goes to
  **gpt-6-astra**, not down the Claude ladder. Fable 5.1 and Astra are tied at
  the top of AA's v4.3 index (53), so it is the only sideways move available;
  opus/sonnet would be a quiet downgrade of work you already judged to need the
  ceiling. Mechanics — `--task-type fable-fallback` through the `model-runner`
  agent — are in model-usage.md. Three rules when you take that route:
  1. **Say so.** Tell the user Fable hit its limit and which model ran instead;
     never let a fallback be invisible.
  2. **Re-read the output.** Astra is Reliability 6 — below the unsupervised
     bar that Fable (9) clears. Whatever review you would have skipped for
     Fable, do it for Astra.
  3. **Keep taste work with Claude.** If the subagent's job was prose, copy, a
     deck, or product judgment rather than code/agent work, prefer **opus** to
     Astra — it is the taste axis Astra is weakest on (Text Arena #24).
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

The table above is a snapshot; model catalogs and pricing drift. Every routable
model documented here and in model-usage.md is live-verified by
`bash ~/dotfiles/claude/tests/routecheck.sh` (alias `routecheck`) — it invokes
each route with a nonce prompt and fails loudly on any broken id, syntax, or
auth (last run 2026-09-22, incl. the new grok-4.7 routes: ALL ROUTES OK). If a route fails, fix the id/syntax
or remove the model from these files — never leave a documented route broken.
Models with no runnable route on this machine do not get table rows. Catalog
drift (a newer grok/composer/glm/gpt version, or a routed id disappearing) is
detected by `bin/catalog-drift.sh` — `routecheck` runs it live and the
SessionStart hook runs it from a 24h cache — so a new version is surfaced
before anyone asks for it. Since 2026-09-22 it also reports **unrouted** ids
(a new tier like `gpt-6-sol` or a new family like `claude-opus-5-5-*` that no
`model` / `retired` / `ignore` row in routes.tsv accounts for), and the **daily
model scout** (`bin/model-scout.sh`, cron 11:30 UTC) turns all of that into a
PR: grok recency research with live web + X search, independent WebSearch
confirmation of every claim it writes here, table/notes/routes updates under
this file's evidence rules (provisional `*` when thin, pinned benchmark index
versions), a live routecheck, and a gpt-6-astra second review. Models it has
judged — including not-routable ones — are logged in `scout/evaluated.tsv`.
Review its PRs like any other: it proposes, Dan merges. When a benchmark or
price claim matters to a decision, re-verify it — grok with citations is the
cheap way to do that.

Follow these rules strictly unless the user explicitly says otherwise.
