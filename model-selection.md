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
Cursor catalog listed it); its scores were an unbenchmarked copy of
grok-4.6/4.5's until AA benchmarked it — Intelligence and Reliability were
re-scored from that on 2026-09-22 (see the grok-4.7 note below).
**gpt-6-sol, gpt-6-luna and opus-5.5 added 2026-09-22** by the daily model
scout (all three launched that day; grok x-recency leads, every quoted number
confirmed on a fetched primary page — sources in their notes). The same pass
moved the Claude rows to what the aliases now resolve to (`opus` → Opus 5.5,
`fable` → Fable 5.1; code.claude.com model-config, fetched 2026-09-22) and
re-rated gpt-5.6-sol's Intelligence against AA v4.3.2. A same-day
verification pass re-fetched the AA pages and corrected three scores against
their own evidence: gpt-6-sol CE 8\* → 9\* (AA per-task cost), fable-5.1
Reliability 9\* → 6\* (AA-Omniscience hallucination 72.6%), grok-4.6
Reliability 3\* → 4\* (hallucination 34%). **2026-09-23 scout:** opus-5.5 CE
4\* → 6\* from AA's per-effort pages (high effort: v4.3.2 54 at $1.82 per
index task), and gpt-6-sol/luna's AA-Omniscience hallucination rates (60% /
77%) and Coding Agent Index moved from UNVERIFIED to sourced (AA's
Sol/Luna article, 2026-09-22); gpt-6-luna Reliability 4\* → 3\* on that rate,
gpt-6-sol's 5\* kept with its justification now in the note.

- **Cost efficiency** = cost **per completed task**, not per token. (Per-token
  intuition inverts rankings: measured 2026-07-21, sonnet-5 had cheaper tokens
  than the then-current opus-4.8 but burned ~40% more tokens per task, landing
  ~15% more expensive per task.) AA's model and comparison pages print this
  directly as cost per Intelligence Index task — use that number.
- **Intelligence** = ability on hard, unsupervised problems.
- **Taste** = UI/UX judgment, code quality, API design, copy quality.
- **Reliability** = trustworthiness unsupervised: hallucination rate, honesty
  under eval pressure, instruction adherence. This axis decides whether a
  delegation can run without close output review.

| Model        | Cost Efficiency | Intelligence | Taste | Reliability |
| ------------ | --------------- | ------------ | ----- | ----------- |
| composer-2.5 | 10              | 6            | 4*    | 5*          |
| gpt-6-astra  | 6               | 9            | 8     | 6           |
| gpt-6-sol    | 9*              | 8            | 6*    | 5*          |
| gpt-6-luna   | 10*             | 5*           | 4*    | 3*          |
| grok-4.7     | 10*             | 7            | 4*    | 5*          |
| grok-4.6*    | 10*             | 7*           | 4*    | 4*          |
| grok-4.5     | 10              | 7            | 4     | 3           |
| glm-5.2      | 9               | 7            | 7     | 6*          |
| gpt-5.6-terra| 8               | 7            | 6     | 7           |
| gpt-5.6-sol  | 7               | 8            | 6     | 5           |
| gpt-5.5      | 6               | 7            | 5     | 7           |
| opus-5.5     | 6*              | 10*          | 8*    | 9*          |
| sonnet-5     | 4               | 7            | 7     | 8           |
| fable-5.1    | 2               | 9            | 9*    | 6*          |

`*` = thin public evidence; treat as provisional.

**Benchmark numbers below come from different index versions — never mix them.**
The pre-2026-09 rows quote AA Intelligence Index **v4.1.1** (fable-5 59.9,
gpt-5.6-sol 58.9, grok-4.5 53.8); the gpt-6-astra note quotes **v4.3**
(2026-09-07), where the whole scale shifted down: Astra 53, Fable 5.1 53,
Opus 5 51, Sol 47. A v4.3 number is not comparable to a v4.1.1 number — AA's
methodology moved twice in the four days after Astra launched (v4.1.1 61 →
v4.2 55, Fable leading → v4.3 53, tied), so pin every claim to a version and
treat any *standing* ("#1", "tied") as provisional even when the score is
sourced. The 2026-09-22 additions quote **v4.3.2** (AA's model pages; the v4.3
article calls the same index "v4.3" and "v4.3.2"): gpt-6-sol 48, gpt-5.6-sol 47,
gpt-6-luna 37, gpt-5.6-luna 37, Astra 53, Fable 5.1 53 — and **opus-5.5 58
(v4.3.2)**, "#1 out of 212 models". AA runs every one of these at **max**
effort ("GPT-6 Sol (max)", "Claude Opus 5.5 (Adaptive Reasoning, Max Effort)")
except where a note says otherwise; the routes here mostly run at the catalog
default (`medium`/`high`), so treat the scores as ceilings.

- **grok-4.7** is the grok row that matters now: it is the **default grok**
  (`--task-type recency` → `grok-4.7-high`; routed 2026-09-22 as
  `grok-4.7-{high,high-fast,xhigh,medium,low}` — note these ids have **no
  `cursor-` prefix** in the Cursor catalog, unlike 4.6/4.5). Released
  2026-09-21 at $2/$6 per Mtok (cached $0.50; Fast $4/$12 at 2× output speed;
  x.ai/news/grok-4-7). **Benchmarked 2026-09-22** (Artificial Analysis,
  "Benchmarking Grok 4.7", 2026-09-21): AA Intelligence Index **v4.3.2 46**
  (xhigh; +2 over 4.6) → Intelligence 7, now sourced; AA-Omniscience
  hallucination **29%** (xhigh; grok-4.6 34% at high; accuracy 47% vs 48%) → Reliability
  raised 3 → **5\*** — far better than grok-4.5's 54%, but no honesty-under-
  pressure data and still under the bar. It burns ~**81k output tokens per
  index task vs 4.6's 36k**, so CE stays provisional. Taste is still a copy of
  grok-4.5's. The usage caveats are unchanged: never unsupervised on
  high-stakes changes, never a review model. **grok-4.6**
  (`cursor-grok-4.6-*`) and **grok-4.5** (`cursor-grok-4.5-*`) are now
  **legacy**: still routable while the Cursor catalog lists them, but not the
  default. grok-4.6's Reliability 3\* was a copy of grok-4.5's (54%); the same
  AA article measured 4.6 itself at **34%** (high effort, 2026-09-21), so it is
  **4\*** — a notch under 4.7's 29%. Its other scores are frozen legacy
  copies. `bin/catalog-drift.sh` (via `routecheck` and the SessionStart hook)
  warns when a newer grok/composer/glm/gpt version shows up in a catalog so
  the next bump is surfaced at session start, not mid-task. The same model is
  also wired **direct to the xAI API** as `grok-4.7-xsearch`
  (`--task-type x-recency`, 2026-09-22), the only route with real X search;
  the scores above apply to both routes.

Notes (evidence-backed, 2026-07-21; the gpt-6-astra note is 2026-09-18; the
gpt-6-sol/luna, opus-5.5 and fable-5.1 notes are 2026-09-22):

- **gpt-6-astra** (OpenAI GPT-6 "Astra", GA 2026-09-03; the only GPT-6 tier
  until Sol and Luna joined it on 2026-09-22 — still no Terra/mini/nano) — $10/$50 per Mtok, cached input $1,
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
    under the unsupervised bar: when it doesn't know, it guesses wrong rather
    than abstaining about half the time (51%), and
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

- **gpt-6-sol / gpt-6-luna** (OpenAI, GA **2026-09-22** in the API, Codex and
  ChatGPT Work; routed here as `gpt-6-sol` / `gpt-6-luna` via Codex, catalog
  default effort `medium`) — the GPT-6 successors to GPT-5.6 Sol / Luna at
  **half their input price and half (Sol) or ~42% (Luna) of their output
  price**: Sol **$2 / $0.20 cached / $10**, Luna **$0.10 /
  $0.01 / $0.50** per Mtok (2× input and 1.5× output past the long-context
  threshold); 1.05M context, 128k max output. Astra stays OpenAI's top model
  ("continues to be our best model across the board"). Both **supersede their
  GPT-5.6 namesakes**, which stay routable as legacy.
  - **gpt-6-sol: Intelligence 8** — AA Intelligence Index **v4.3.2 48** vs
    gpt-5.6-sol 47, gpt-5.6-terra 42 and Astra 53 (every AA number in this note
    is at **max** effort, from AA's comparison pages); AA Terminal-Bench 4.0 44%
    (5.6-sol 40%, Astra 59%), AA-Omniscience Index 27 (5.6-sol 22, Terra 0,
    Astra (max) 43 — sol-vs-astra comparison page), but GDPval-AA v2.1
    *lower* than 5.6-sol (1487 vs 1588). OpenAI's own evals: DeepSWE v1.1 68.8%
    (max), OSWorld 2.0 offline 60.5% (xhigh), AutomationBench 1.0.6 33.2% at
    $0.27/task, "about half as many mistakes as its predecessor" on its
    internal factuality eval. **CE 9\*** — AA measures **$1.06 per
    Intelligence Index task** vs gpt-5.6-sol $1.99 and gpt-5.6-terra $1.40
    (31k vs Terra's 39k output tokens/task), i.e. cheaper per task than Terra
    *and* 6 points higher; provisional because it is one AA measurement at max
    effort, one day old. AA Coding Agent Index **57** (max, Codex harness;
    5.6-sol 55). **Taste 6\*** copied from gpt-5.6-sol. **Reliability 5\***:
    AA measured its AA-Omniscience **hallucination rate at 60%** (max; 5.6-sol
    92%), bought by abstaining more — it attempts 83% of questions vs 99%, so
    accuracy *fell* 59% → 54%. A real gain over 5.6-sol (5), but still worse
    than Astra's 51% (6), and METR has not evaluated it: 5 stays, provisional.
    It sits above grok-4.5's 3 (54%) despite the higher rate because of
    honesty-side evidence grok lacks: the measured abstention gain (it now
    declines 17% of questions rather than guessing) and OpenAI's "about half
    as many mistakes as its predecessor" on its internal factuality eval (a
    vendor claim). Judge its output as you would Sol's.
  - **gpt-6-luna: Intelligence 5\*** — AA v4.3.2 **37**, level with
    gpt-5.6-luna (37) at half the input and ~42% of the output price, and
    **$0.07 per AA index task vs 5.6-luna's $0.18** (max effort) → CE 10\*;
    Omniscience Index 1 (5.6-luna −10); AA-Omniscience hallucination **77%**
    (max; 5.6-luna 93%, accuracy 44% vs 43%); Coding Agent Index **41** (max,
    −2 vs 5.6-luna).
    OpenAI pitches it for "focused, high-volume tasks, including summarization,
    extraction, and focused coding" — a fast-draft / extraction tier, not an
    agent for open-ended work. Taste is an unmeasured guess below Sol's;
    **Reliability 3\*** (4\* → 3\* on 2026-09-23): its 77% hallucination rate is
    worse than grok-4.5's 54% (Reliability 3) and no honesty evidence offsets
    it, so it cannot sit above 3.
  - Sources: OpenAI launch post openai.com/index/introducing-gpt-6-sol-and-luna
    and developer-community announcement (2026-09-22); OpenAI API model pages
    and pricing page (developers.openai.com, fetched 2026-09-22); Codex
    changelog + models page (learn.chatgpt.com, 2026-09-22); Artificial
    Analysis model page for gpt-6-sol and comparison pages
    gpt-6-sol-vs-gpt-5-6-sol, gpt-6-sol-vs-gpt-5-6-terra, gpt-6-sol-vs-gpt-6-astra,
    gpt-6-luna-vs-gpt-5-6-luna (artificialanalysis.ai/models/comparisons/…,
    undated; fetched 2026-09-22) — the per-task costs are printed there; AA
    article "GPT-6 Sol and Luna push the cost efficiency frontier"
    (2026-09-22, fetched 2026-09-23) — hallucination rates, attempt rate,
    accuracy and Coding Agent Index.

- **grok-4.5** — $2/$6 per Mtok (cached input $0.30; 2× rates past 200k prompt),
  AA Intelligence 53.8 (#4). Reliability 3: **54% hallucination on
  AA-Omniscience** — confidently wrong under speed pressure. Never unsupervised
  on high-stakes changes; never a review model. 500K context.
- **composer-2.5** — Cursor-only. Coding Agent Index 62, ~$0.07/task standard
  tier. Fast multi-file agentic edits; weak on terminal-heavy work and broad
  architecture. Taste/reliability scores are unverified (absent from preference
  boards).
- **gpt-5.6** (GA 2026-07-09; **superseded 2026-09-22** by gpt-6-sol / gpt-6-luna
  at half the price or less — Sol and Luna stay routable as legacy; there is no GPT-6
  Terra). Current list (developers.openai.com pricing, fetched 2026-09-22):
  Sol $4/$20 ("promotional pricing … at least through November 21, 2026"),
  Terra $2/$12, Luna $0.20/$1.20 — the launch prices below are historical.
  **Sol** ($5/$30) AA 58.9 (v4.1.1; **47 on v4.3.2**, hence Intelligence 9 → 8
  on 2026-09-22), and OpenAI claims
  Coding Agent Index 80 at max effort; but **METR flagged Sol for record
  eval-gaming** (honesty-suite metagaming 55.4% vs gpt-5.5's 41.2%; METR called
  its Time Horizon results unusable) — hence Reliability 5. Judge its outputs,
  don't trust its self-reports. **Terra** ($2.50/$15, AA 55.0) is the bulk-work
  default. **Luna** ($1/$6): fast-draft tier only.
- **gpt-5.5** — superseded: same $5/$30 price as Sol with less capability;
  Terra beats it on both axes at half price. Kept only because Codex defaults to
  it; prefer `-m gpt-5.6-terra`. **Leaves Codex for ChatGPT sign-in on
  2026-10-14** (learn.chatgpt.com/docs/models, fetched 2026-09-22) — this
  machine's Codex runs on that seat auth, so expect `catalog-drift` to flag
  `gpt-5.5` vanished then; retire it to `gpt-6-sol`.
- **sonnet-5** — Int raised to 7 (AA 53.4, statistically tied with grok-4.5).
  CE lowered to 4 (see per-task note above). Its $2/$10 intro price is now
  standard — the planned rise to $3/$15 "will not occur"
  (platform.claude.com pricing, fetched 2026-09-22).
- **opus-5.5** (Claude Opus 5.5, `claude-opus-5-5`, released **2026-09-22**;
  the `opus` alias since Claude Code **2.1.280**, which is also Claude Code's
  new default model) — **$4/$20** per Mtok (cache reads $0.20; fast mode
  $8/$40), 1M context, 128k max output, default effort `medium`, thinking
  always on. Replaces the opus-4.8 row (the alias went 4.8 → Opus 5, 2026-07-24
  → 5.5; Opus 5 is now "Legacy").
  - **Intelligence 10\*** — **58 on AA's Intelligence Index v4.3.2** (max
    effort; AA model page: "#1 out of 212 models"), "the highest score we have
    measured by several points", where Fable 5.1 and Astra sit at 53 (both
    max); AA-measured Terminal-Bench 4.0
    59.6%, HLE 61.4%, GDPval-AA v2.1 1846. Anthropic's own table (max effort):
    Terminal-Bench 4.0 66.4% vs Fable 5.1 55.8% / Astra 57.9%, FrontierCode
    v1.1 54.4%, CursorBench 4.0 57.8%. Provisional only because it is one day
    old.
  - **CE 6\*** (4\* → 6\* on 2026-09-23) — at **max** effort it burns ~**119k
    output tokens per AA index task**, **$5.98 per index task** (between Astra
    and Fable 5.1), but the max number is not how it runs here. AA's
    per-effort pages (v4.3.2, fetched 2026-09-23): **high 54 at $1.82/task**
    (53M output tokens for the index), **medium 51 at $1.34/task** (38M;
    `medium` is its API default). At high it still out-scores Astra (max) and
    Fable 5.1 (max), both 53, at ~56% of Astra's $3.26 and under a quarter of
    Fable's $7.63 — so it is no worse than Astra's 6 per completed task. Not
    higher: gpt-6-sol does 48 for $1.06 and Terra 42 for $1.40 (both max).
    Provisional: one AA measurement per effort, one day old.
  - **Taste 8\*, Reliability 9\*** copied from opus-4.8. Taste: not on
    LMArena yet; Design Arena shows a **67% overall win rate over 98
    tournaments** (no Elo yet; Fable 5.1: 62%) — a good early sign, one
    source. Reliability: AA-Omniscience Index **46, the highest measured**
    (Omniscience board: Opus 5.5 (max) 46, Astra (high) 44, Fable 5.1 (max)
    43), but AA prints no hallucination rate for it on any page fetched
    through 2026-09-23. Anthropic calls it "our strongest model on most
    measures of honesty", with boundary-circumvention attempts "around 85%
    less often than Opus 5 or Claude Mythos 5.1" (launch post) — vendor
    claims, not independent. The 9 is the least-evidenced score in this
    row: Fable 5.1 sits only 3 Index points lower and hallucinates 72.6%, so if
    AA publishes a comparable rate for Opus 5.5, re-score it the same way.
  - Sources: anthropic.com/news/claude-opus-5-5 and
    platform.claude.com/docs (models overview + pricing), code.claude.com
    model-config, Claude Code CHANGELOG 2.1.280 (all 2026-09-22); AA article
    "Claude Opus 5.5" (2026-09-22), AA model page and Omniscience page (fetched
    2026-09-22); AA per-effort pages artificialanalysis.ai/models/
    claude-opus-5-5-high and …-medium and designarena.ai/models/claude-opus-5-5
    (undated; fetched 2026-09-23).
  - **UNVERIFIED — do not quote:** a SWE-bench Pro 89.9% (search snippet
    only; Anthropic published no SWE-bench number), any LMArena score, and
    an AA-Omniscience hallucination rate of 58.6% (benchlm.ai, "last updated
    2026-09-22", credited to AA, no effort label; not on any AA page fetched
    2026-09-23).
- **fable-5.1** (Claude Fable 5.1, `claude-fable-5-1`, released 2026-09-01; the
  `fable` alias) — $10/$50 (cache reads $0.25), 1M context, default effort
  `high`. AA Intelligence Index **v4.3.2 53**, tied with Astra and now **5
  below opus-5.5**; $7.63 per AA index task (see the Astra note). Design Arena
  overall Elo 1369 (62% WR; fetched 2026-09-22). Still the Taste ceiling on
  prose and product judgment, but no longer the intelligence ceiling.
  **Reliability 6\*** (was 9\*, carried over from fable-5, lowered
  2026-09-22): AA's Fable 5.1 launch article (artificialanalysis.ai/articles/
  claude-fable-5-1, 2026-09-01, max effort) measured an AA-Omniscience
  **hallucination rate of 72.6%** (Fable 5: 63.6%) — worse than Astra's 51%
  (Reliability 6) — because it attempts **93.4%** of questions and rarely
  abstains. Nothing offsets that on the other two Reliability inputs: Anthropic's
  system card (2026-09-01; Fable 5.1 is Mythos 5.1 with classifiers on top)
  calls honesty "a mixed bag, overall a net regression" — MASK holds firm
  under pressure 85% vs Mythos 5 91% / Opus 5 95% — and publishes no
  instruction-adherence gain to cite (per Zvi Mowshowitz's system-card review,
  thezvi.wordpress.com, 2026-09-04; the 200+-page PDF itself was not fetched).
  So 6, level with Astra, not 7. This bars Fable from *unsupervised
  delegation*, not from the orchestrator or reviewer seat — see Core Rules.
  Treat its unsourced factual claims with the same suspicion as anyone's.
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
Anything lower (grok-4.7/4.6/4.5, composer-2.5, glm-5.2, gpt-6-sol/luna, gpt-5.6-sol,
**gpt-6-astra**, **fable-5.1**) needs its output judged by you or a
high-reliability model before it lands. Astra sits just under the bar despite
its intelligence — judge the diff, not its summary of the diff. The rule is
about **delegated** output nobody reads closely. It does not take fable-5.1 out
of the orchestrator or reviewer seat: there Dan is in the loop and the work is
grounded in files and diffs it has read, while its measured weakness is
unsourced recall. It does mean a Fable *subagent's* report gets the same
judgment as Astra's, and a version, price or API claim Fable makes without a
source gets checked.

## Selection by Task Type

### Bulk / Mechanical / Well-Specified Work

**gpt-5.6-terra via Codex** is the default (gpt-5.5 quality at half price).
Cheaper still, with closer output review required: **composer-2.5** (fast
multi-file agentic edits; avoid terminal-heavy tasks) and **grok-4.7**
(well-specified tasks; cheap tokens but ~81k output tokens per AA task, and
still Reliability 5\* — see the rankings note).
**glm-5.2** is a promising budget alternative via the Cursor catalog.
**gpt-6-sol** (2026-09-22) is the likely next bulk default — AA measures it
**cheaper per task than Terra ($1.06 vs $1.40) and smarter (v4.3.2 48 vs 42)**,
both at max effort — but `bulk` stays on Terra because bulk work runs with
light review and Sol's **Reliability 5\*** is under the ≥7 unsupervised bar,
where Terra's is 7. AA has since measured Sol's hallucination rate at **60%**
(max; 5.6-sol 92%, Astra 51%): better than its predecessor, still worse than
Astra's Reliability-6 figure, so the 5\* holds. Reconsider the switch if an
honesty or instruction-adherence eval (METR or similar) lands for it.
**gpt-6-luna** ($0.10/$0.50) is the fast-draft / extraction / summarization
tier; don't hand it open-ended agent work.

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

Use Taste ≥ 7: **fable-5.1**, **opus-5.5** (also **sonnet-5** for lighter work).
For UI, copy, API design, product design — anything where polish matters.
**gpt-6-astra** is the exception worth knowing: it is #1 on LMArena's Code/WebDev
Arena and on Design Arena's UI Component, SVG, Game Dev and 3D boards, so it is a
legitimate pick for *generating* an interface, a scene, or a graphic. Keep Claude
for prose, copy, decks, and product judgment — Astra is #24 on Text Arena overall
and measurably worse than Sol on presentation.

### Reviews & Planning

**opus-5.5** or **fable-5.1** — prefer opus-5.5 when the review turns on
recalled facts (API semantics, versions, prices): Fable 5.1 is Reliability 6\*
on a 72.6% hallucination rate. For higher confidence add a non-Claude second
opinion: **gpt-6-astra** (`--task-type second-review`) is now the default there,
having replaced gpt-5.6-sol on 2026-09-18 — same reviewer role, half the
hallucination rate (AA-Omniscience 51% vs Sol's 92%), higher intelligence, and
no METR eval-gaming finding against it. It stays there after 2026-09-22:
gpt-6-sol is cheaper but well below Astra on AA-Omniscience (Index 27 vs
Astra (max) 43 — sol-vs-astra comparison page, fetched 2026-09-22).
`gpt-6-sol` (or legacy `gpt-5.6-sol` / `gpt-5.5`) stays routable by id if you
want a third voice or a cheaper pass. Ask any of them for
severity, file:line, a concrete failing scenario, and a SHIP / FIX-FIRST
verdict. **Never grok (4.7, 4.6, or 4.5) or composer-2.5 as review models** — reviews
need low hallucination and strong reasoning, exactly where they trade down.
Judge the findings, not the reviewer's confidence: Astra's hallucination rate is
better than Sol's, not low.

### Recent Information / Research

Two grok routes, split by **whether you need X**:

- **`--task-type x-recency` → `grok-4.7-xsearch`: social / X sentiment.** Hot
  takes, practitioner and lab-staff reactions, "what are people saying about
  X", launch chatter, anything whose best evidence is posts rather than
  pages. It runs grok-4.7 on the **direct xAI Responses API** with the
  server-side `x_search` **and** `web_search` tools. It is the only route in
  this stack that reads X: no other API model has a real-time X feed, and grok
  through Cursor has web search only. model-run prints a measured
  `model-run: xai-tools x_search=<n> web_search=<n> ...` line on stderr, so you
  can prove X was searched instead of trusting grok's word. Wired 2026-09-22;
  the daily model scout uses it first, for the X hot-takes half of its
  research. Pay-per-use (grok-4.7 $2 / $6 per Mtok, cached input $0.50,
  doubled past 200k prompt tokens; `web_search` $5 per 1k calls; `x_search`
  $5 per 1k **posts fetched**, $10 per 1k profiles; docs.x.ai models and
  pricing pages, fetched 2026-09-22). Two test sentiment questions on
  2026-09-22 cost $0.10 and $0.14 each (the response's own `cost_in_usd_ticks`). Needs `XAI_API_KEY` (env or `~/.profile`); a rejected key
  is exit 75, like any auth failure.
- **`--task-type recency` → `grok-4.7-high` (Cursor): general recent info.**
  Breaking news, "what happened this week" research, and cross-checking
  another agent's claims about recent releases, on the already-paid Cursor
  seat, **web search only**. Note the id has **no `cursor-` prefix**, unlike
  the legacy 4.6/4.5 ids. `cursor-grok-4.6-*` and `cursor-grok-4.5-*` remain
  routable as legacy if you need to reproduce an earlier result.

Caveats, applied strictly (they apply to both routes, which run the same model):

- **Do not trust its unsourced recall**: AA-Omniscience measured grok-4.7 at
  a **29%** hallucination rate with only **47%** accuracy (2026-09-21; 4.5 was
  54%), so most of what it "knows" unsourced is still wrong or missing. Require
  citations with dates in the prompt, and post URLs for X claims; treat
  uncited recent "facts" as unverified. grok-4.7's knowledge cutoff is May
  2026 (docs.x.ai models page, fetched 2026-09-22); freshness comes from the
  search tools, not the model. An X post is a lead, not a source: a claim
  that goes into a repo file still needs a primary source.
- Its edge is specifically the **X stream and cheap tokens for search-heavy
  loops**. For ordinary web recency, Claude's native WebSearch is fine. Don't
  route to grok just because a question mentions a date, and don't pay for
  x-recency when the question isn't about what people are saying.

### Avoid

Never use **Haiku** for important work. Never silently substitute a model when
the designated one errors — stop and surface (see model-usage.md). The one
sanctioned substitution is the Fable-quota fallback below, and it is not silent:
you announce it.

## Subagent & Workflow Guidelines

- Main orchestrator: **opus-5.5** or **fable-5.1** at high effort (opus-5.5
  now leads AA's index at a lower price and has the higher Reliability, 9\* vs
  6\*; fable-5.1 keeps the edge on prose and product taste).
- Delegations to non-Claude models go through the **`model-runner`** named
  agent (a sonnet wrapper installed from this repo) — give it a model id OR a
  task type (`bulk` / `cheap` / `recency` / `x-recency` / `second-review` / `fable-fallback`)
  + prompt file; it invokes `bin/model-run.sh` and returns output verbatim. Prefer task types:
  the table picks the id deterministically, and the mapping lives in
  `bin/routes.tsv`, not in your judgment. Don't hand-roll codex/cursor-agent
  commands; a hook denies them. (Direct `model-run.sh` via Bash is fine for
  quick inline one-offs, but the agent is preferred for delegations — it shows
  up as a named agent in the progress UI instead of a background process.)
- **When Fable is out of quota**, a subagent that was scoped for Fable goes to
  **gpt-6-astra**, not down the Claude ladder. Fable 5.1 and Astra are tied on
  AA's v4.3.2 index (53), so Astra is the sideways non-Claude move; sonnet
  would be a quiet downgrade of work you already judged to need the ceiling.
  **Since 2026-09-22 `opus` is not a downgrade either**: Opus 5.5 scores 58 on
  the same board, above both — re-dispatching on `opus` is a legitimate
  alternative (announce it the same way; it shares Claude's quota pool, Astra
  doesn't). Mechanics — `--task-type fable-fallback` through the `model-runner`
  agent — are in model-usage.md. Three rules when you take that route:
  1. **Say so.** Tell the user Fable hit its limit and which model ran instead;
     never let a fallback be invisible.
  2. **Re-read the output.** Astra is Reliability 6 — below the unsupervised
     bar, level with Fable 5.1 (6\*). Give it at least the review a Fable
     subagent's output gets, plus a check for its operational quirks
     (over-testing, extra clarifying questions, cyber gating).
  3. **Keep taste work with Claude.** If the subagent's job was prose, copy, a
     deck, or product judgment rather than code/agent work, prefer **opus** to
     Astra — it is the taste axis Astra is weakest on (Text Arena #24).
- Workflow stages: mechanical fan-out stages → `{ model: 'sonnet', effort:
  'low' }`; judge, verify, and taste-sensitive stages → session model (opus-5.5 /
  fable-5.1) at high effort. Prefer effort `'high'` for fable; avoid `'xhigh'`
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
auth (last run 2026-09-23 by the model scout on codex-cli 0.156.0: ALL
ROUTES OK, no drift or unrouted warnings). If a route fails, fix the id/syntax
or remove the model from these files — never leave a documented route broken.
Models with no runnable route on this machine do not get table rows. Catalog
drift (a newer grok/composer/glm/gpt version, or a routed id disappearing) is
detected by `bin/catalog-drift.sh` — `routecheck` runs it live and the
SessionStart hook runs it from a 24h cache — so a new version is surfaced
before anyone asks for it. Since 2026-09-22 it also reports **unrouted** ids
(a new tier like `gpt-6-sol` or a new family like `claude-opus-5-5-*` that no
`model` / `retired` / `ignore` row in routes.tsv accounts for), and the **daily
model scout** (`bin/model-scout.sh`, cron 11:30 UTC) turns all of that into a
PR: grok research with live X + web search first (`x-recency`, measured
x_search count; a failure falls back to web-only `recency` and marks the run
degraded), independent WebSearch
confirmation of every claim it writes here, table/notes/routes updates under
this file's evidence rules (provisional `*` when thin, pinned benchmark index
versions), a live routecheck, and a gpt-6-astra second review. Models it has
judged — including not-routable ones — are logged in `scout/evaluated.tsv`.
Review its PRs like any other: it proposes, Dan merges. When a benchmark or
price claim matters to a decision, re-verify it — grok with citations is the
cheap way to do that.

Follow these rules strictly unless the user explicitly says otherwise.
