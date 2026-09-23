# Model scout 2026-09-22: route GPT-6 Sol/Luna, move Claude rows to Opus 5.5 / Fable 5.1, triage 223 unrouted Cursor ids

## Summary

- **Full research pass, no fallback.** grok x-recency ran on the direct xAI API with measured X search (`x_search=4`, 29 posts). Claude WebSearch/WebFetch confirmed every number quoted in the repo from a primary page.
- **Routed `gpt-6-sol` and `gpt-6-luna`** (OpenAI, GA today, Codex). Each costs half its GPT-5.6 namesake's input price (and half or less of its output price) and scores at least as well on AA Intelligence Index v4.3.2 (Sol 48 vs 47, Luna 37 vs 37). They **supersede** `gpt-5.6-sol` / `gpt-5.6-luna`, which stay routable as legacy. No task rows moved: `bulk` stays on Terra because gpt-6-sol's Reliability 5\* is under the ≥7 unsupervised bar (Terra: 7), even though AA measures Sol cheaper per task ($1.06 vs $1.40) and higher (48 vs 42).
- **Claude rows follow the aliases.** Since Claude Code 2.1.280 (today), `opus` → Opus 5.5 and `fable` → Fable 5.1, so `opus-4.8`/`fable-5` became `opus-5.5`/`fable-5.1`. **Opus 5.5 scores 58 on AA's index v4.3.2 (max), #1 and 5 points above Fable 5.1/Astra.** The docs no longer call `opus` a downgrade from Fable.
- **grok-4.7 re-benchmarked.** Its Intelligence 7 now has a source (AA v4.3.2 46). **Reliability went from 3 to 5\*** on AA's measured 29% hallucination rate (grok-4.5's was 54%). The "never a review model" rule stays.
- **Every unrouted catalog id is now accounted for.** 223 Cursor ids and 2 Codex ids went down to 0: 2 routed, the rest matched by 30 new `ignore` rows. Claude globs are one per family version, so the next Claude release still surfaces.
- **Live routecheck passed.** ALL ROUTES OK, with no drift or unrouted warnings.

## Routing changes

- **`bin/routes.tsv`**
  - Added `model` rows `gpt-6-sol` and `gpt-6-luna` (codex, no effort pin; catalog default is `medium`), with a dated rationale comment.
  - Dated comment: `gpt-5.5` leaves Codex for ChatGPT sign-in on 2026-10-14.
  - Legacy (still routable, no row change): `gpt-5.6-sol`, `gpt-5.6-luna`.
  - New `ignore` rows:
    - `auto`
    - `cursor:gpt-*` (OpenAI routes through Codex)
    - Claude, one glob per version:
      - `cursor:claude-opus-5-5-*`
      - `cursor:claude-opus-5-[lmhx]*`
      - `cursor:claude-opus-5-thinking-*`
      - `cursor:claude-fable-5-1-*`
      - `cursor:claude-fable-5-[lmhx]*`
      - `cursor:claude-fable-5-thinking-*`
      - `cursor:claude-sonnet-5-[lmhx]*`
      - `cursor:claude-sonnet-5-thinking-*`
      - `cursor:claude-opus-4-8-*`
      - `cursor:claude-opus-4-7-*`
      - `cursor:claude-4.6-*`
      - `cursor:claude-4.5-*`
      - `cursor:claude-4-sonnet*`
    - grok fast-mode variants:
      - `cursor:grok-4.7-[lmx]*-fast`
      - `cursor:cursor-grok-4.6-[lmx]*-fast`
      - `cursor:cursor-grok-4.5-[lm]*-fast`
    - Gemini:
      - `cursor:gemini-3.8-flash-*`
      - `cursor:gemini-3.7-flash-*`
      - `cursor:gemini-3.6-flash-*`
      - `cursor:gemini-3.5-flash`
      - `cursor:gemini-3-flash`
      - `cursor:gemini-3.1-pro`
    - Kimi:
      - `cursor:kimi-k3-*`
      - `cursor:kimi-k2.7-*`
    - Muse (a *watch* item): `cursor:muse-spark-1.3-*`
  - The `[lmhx]*` class keeps `claude-opus-5-*` from swallowing a future `claude-opus-5-6-*`.
- **`tests/routecheck.sh`**
  - The mock Codex catalog now lists `gpt-6-sol` / `gpt-6-luna`, so they aren't reported vanished.
  - The mock unrouted assertions now expect `auto` to be *ignored*: the Cursor summary drops from 3 unrouted ids to 2, and `--unrouted` no longer lists `auto`. The comment is updated to match.
- **`tests/workflows/orchestration-smoke-model-runner.js`**: `IDS` swaps `gpt-5.6-sol` for `gpt-6-sol`. Task rows are unchanged.
- **`model-selection.md`**
  - New rows `gpt-6-sol` (9\*/8/6\*/5\*) and `gpt-6-luna` (10\*/5\*/4\*/4\*).
  - `opus-4.8` → `opus-5.5` (4\*/10\*/8\*/9\*) and `fable-5` → `fable-5.1` (2/9/9\*/6\*).
  - `grok-4.6` Reliability 3\* → 4\* (AA-measured 34%).
  - `gpt-5.6-sol` Intelligence 9 → 8 (AA v4.3.2 47).
  - `grok-4.7` Intelligence 7 is now sourced; Reliability 3\* → 5\*.
  - New notes for GPT-6 Sol/Luna, Opus 5.5 and Fable 5.1.
  - Updated the Astra, gpt-5.6, gpt-5.5, sonnet-5 and grok notes.
  - Updated Core Rules, the Bulk, User-Facing, Reviews, Recent-info and Subagent sections, the Fable-quota fallback, and "Keeping This File Honest".
- **`model-usage.md`**: the current-ids paragraph (GPT-6 Sol/Luna, the gpt-5.5 date), the Claude alias map for Claude Code 2.1.280, and the Fable-fallback rationale.
- **`agents/model-runner.md`** and **`README.md`**: id lists now include gpt-6-sol/luna.
- **`scout/evaluated.tsv`**: 16 rows.
- **Not touched**: `hooks/route-guard.sh` (no new `retired` rows) and `system-map.md` (no retired model is named there).

## Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| gpt-6-sol | OpenAI | 2026-09-22 | supersedes:gpt-5.6-sol | $2/$10 vs $4/$20, AA v4.3.2 48 vs 47, $1.06 vs $1.99 per AA task, Omniscience Index 27 vs 22 (all max) |
| gpt-6-luna | OpenAI | 2026-09-22 | supersedes:gpt-5.6-luna | $0.10/$0.50 vs $0.20/$1.20, same AA v4.3.2 score (37), $0.07 vs $0.18 per AA task (max) |
| claude-opus-5-5 | Anthropic | 2026-09-22 | routed (native) | `opus` alias; AA v4.3.2 58 (max), #1; $4/$20 |
| claude-fable-5-1 | Anthropic | 2026-09-01 | routed (native) | `fable` alias; row renamed from fable-5; hallucination 72.6% → Reliability 6\* |
| Cursor `claude-*` (Opus 5 / Fable 5 / Sonnet 5 / Opus 4.8 / 4.7 / 4.x) | Anthropic | various | ignore | Claude runs natively |
| grok-4.7 (re-check) | xAI | 2026-09-21 | routed (already) | AA 46, hallucination 29%, so scores updated; fast variants ignored |
| gemini-3.8-flash | Google | 2026-09-02 | ignore | AA v4.3.2 41; leads no axis against the routed models |
| gemini-3.7/3.6/3.5/3 flash, 3.1-pro | Google | earlier | ignore | Superseded, or older than the frontier tiers |
| kimi-k3 | Moonshot | 2026-07-16 | ignore | AA 44 at $3/$15, dominated by gpt-6-sol |
| kimi-k2.7-code | Moonshot | 2026-06-12 | ignore | AA 26 |
| muse-spark-1.3 | Meta | 2026-09-02 | watch (+ignore row) | AA 48 (max, limited access) at $1.25/$4.25; no hallucination or per-task data |
| auto | Cursor | n/a | ignore | Router, not a model |
| GLM-5.3 / 5.3-Flash | Z.ai | 2026-08-18/26 | not-routable | Not in Cursor's catalog yet |
| DeepSeek V4.1 Flash | DeepSeek | 2026-09-10 | not-routable | Not in any catalog |
| MiMo-V2.6-Pro | Xiaomi | 2026-09-21/22 | not-routable | Not in any catalog |
| Qwen3.8 Max / Omni-Flash | Alibaba | 2026-09 | not-routable | Not in any catalog |

## Evidence

- **GPT-6 Sol/Luna**
  - **Prices:** gpt-6-sol $2/$0.20/$10 and gpt-6-luna $0.10/$0.01/$0.50 per Mtok; gpt-5.6 current list is Sol $4/$20 (promo "at least through November 21, 2026"), Terra $2/$12, Luna $0.20/$1.20. Source: https://developers.openai.com/api/docs/pricing (no page date; fetched 2026-09-22).
  - **Launch post:** https://openai.com/index/introducing-gpt-6-sol-and-luna/ (2026-09-22; read via proxy). Quotes: "GPT‑6 Astra continues to be our best model across the board", "about half as many mistakes as its predecessor". Vendor evals: DeepSWE v1.1 68.8%, OSWorld 2.0 offline 60.5%, AutomationBench 1.0.6 33.2%.
  - **Announcement:** https://community.openai.com/t/announcing-gpt-6-sol-and-gpt-6-luna-in-the-api-codex-and-chatgpt/1399925 (2026-09-22).
  - **Codex changelog and models page:** https://learn.chatgpt.com/docs/changelog and https://learn.chatgpt.com/docs/models (2026-09-22). Luna is for "focused, high-volume tasks, including summarization, extraction, and focused coding". GPT-5.6 models "remain available during GPT-6 rollout". gpt-5.5 retires 2026-10-14 for ChatGPT sign-in.
  - **AA v4.3.2 scores:** gpt-6-sol 48, gpt-6-luna 37, gpt-6-astra 53. Sources: https://artificialanalysis.ai/models/gpt-6-sol, …/gpt-6-luna, …/gpt-6-astra (undated; fetched 2026-09-22).
  - **AA head-to-heads** (all "(max)" effort, v4.3.2): Sol vs 5.6-Sol 48 vs 47, $1.06 vs $1.99 per index task, Omniscience Index 27 vs 22, Terminal-Bench 4.0 44 vs 40, GDPval-AA v2.1 1487 vs 1588; Sol vs 5.6-Terra 48 vs 42, $1.06 vs $1.40 per index task, 31k vs 39k output tokens per task, Omniscience Index 27 vs 0; Sol vs Astra 48 vs 53, Omniscience Index 27 vs 43, $1.06 vs $3.26; Luna vs 5.6-Luna 37 vs 37, $0.07 vs $0.18 per index task. Sources: https://artificialanalysis.ai/models/comparisons/gpt-6-sol-vs-gpt-5-6-sol, …/gpt-6-sol-vs-gpt-5-6-terra, …/gpt-6-sol-vs-gpt-6-astra, …/gpt-6-luna-vs-gpt-5-6-luna (undated; fetched 2026-09-22).
- **Claude Opus 5.5**
  - **Launch:** https://www.anthropic.com/news/claude-opus-5-5 (2026-09-22). Anthropic's table: Terminal-Bench 4.0 66.4%, FrontierCode v1.1 54.4%, CursorBench 4.0 57.8%.
  - **Docs:** https://platform.claude.com/docs/en/models/opus-5-5/overview and https://platform.claude.com/docs/en/about-claude/pricing ($4/$20, cache $0.20, fast $8/$40; the Sonnet 5 rise to $3/$15 "will not occur").
  - **Aliases:** https://code.claude.com/docs/en/model-config.
  - **Claude Code changelog:** https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (2.1.280, 2026-09-22: "Added Claude Opus 5.5 … now the default Opus model").
  - **AA:** https://artificialanalysis.ai/articles/claude-opus-5-5 (2026-09-22): 58, ~119k output tokens per task, Terminal-Bench 4.0 59.6%, HLE 61.4%. The model page (https://artificialanalysis.ai/models/claude-opus-5-5) says "scores 58 on the Artificial Analysis Intelligence Index v4.3.2, placing it #1 out of 212 models" (Adaptive Reasoning, Max Effort) and $5.98 per index task. The Omniscience board (https://artificialanalysis.ai/evaluations/omniscience) shows Opus 5.5 (max) 46, Astra (high) 44, Fable 5.1 (max) 43; the sol-vs-astra comparison page shows Astra (max) at 43. The doc tags each Astra number with its effort and page.
  - **Conflict:** Terminal-Bench 4.0 is 66.4% by Anthropic and 59.6% by AA. The doc quotes both, labeled.
  - **Resolved in the follow-up:** the first pass said the AA Opus 5.5 page printed no index version. A re-fetch shows it prints v4.3.2; the caveat is gone.
- **Claude Fable 5.1**
  - **Docs:** https://platform.claude.com/docs/en/models/fable-5-1/overview (released 2026-09-01).
  - **AA v4.3:** https://artificialanalysis.ai/articles/artificial-analysis-intelligence-index-v4-3 (2026-09-07): 53.
  - **Hallucination:** https://artificialanalysis.ai/articles/claude-fable-5-1 (2026-09-01): AA-Omniscience hallucination 72.6% vs Fable 5 63.6%, 93.4% of questions attempted. This is a pre-v4.3 article; the doc says so.
  - **Honesty:** Anthropic's Fable 5.1 & Mythos 5.1 system card (2026-09-01), via https://thezvi.wordpress.com/2026/09/04/claude-fable-5-1-and-mythos-5-1-the-system-card/ (2026-09-04): same model as Mythos 5.1 with classifiers; honesty "a mixed bag, overall a net regression"; MASK 85% vs Mythos 5 91% / Opus 5 95%. The PDF itself was too large to fetch.
  - **Design Arena:** https://www.designarena.ai/models/claude-fable-5-1: overall 1369, 62% WR.
- **grok-4.7**
  - **AA:** https://artificialanalysis.ai/articles/benchmarking-grok-4-7 (2026-09-21): index 46 (xhigh), hallucination 29% vs 4.6's 34% (4.6 at high), accuracy 47% vs 48%, ~81k vs 36k output tokens per task. I fetched this one myself. The 34% also re-scores the legacy grok-4.6 row.
  - **Launch:** https://x.ai/news/grok-4-7 (2026-09-21): $2/$6, Fast $4/$12.
- **Ignore-row numbers**
  - **Gemini 3.8 Flash:** https://blog.google/innovation-and-ai/models-and-research/gemini-models/3-8-flash-and-3-8-flash-cyber/ (2026-09-02), https://artificialanalysis.ai/models/gemini-3-8-flash (v4.3.2 41).
  - **Gemini Pro:** https://ai.google.dev/gemini-api/docs/pricing (updated 2026-09-22; 3.1 Pro is the newest Pro).
  - **Kimi:** https://platform.kimi.ai/docs/pricing/chat and https://artificialanalysis.ai/models/kimi-k3 (44), …/kimi-k2-7-code (26).
  - **Muse Spark 1.3:** https://research.meta.ai/blog/introducing-muse-spark-1-3 (2026-09-02), https://dev.meta.ai/models/muse-spark/ ($1.25/$4.25), https://artificialanalysis.ai/models/muse-spark-1-3 (48), and VentureBeat (2026-09-03) on max being in limited safety testing.
- **Cursor `-fast` suffix:** https://cursor.com/docs/models/gpt-5-6-sol and https://cursor.com/docs/models/claude-opus-5-5: priority tier, about 2× price, same model.
- **Conflict (pre-v4.3 scores):** grok's report and AA's changelog summary gave Gemini 3.8 Flash **59**, the pre-v4.3 scale. Fable 5.1's **66** and Muse's **61/62** are also pre-v4.3. Only v4.3.2 numbers are quoted.

## Unverified — not quoted

- GPT-6 Sol/Luna AA-Omniscience hallucination rates (60% / 77%) and Coding Agent Index (57 / 41). Sources were an AA X post snippet and wccftech; these went into model-selection.md's "UNVERIFIED — do not quote" bullet. (The cost per AA task, $1.06 / $0.07, was wrongly listed here in the first pass: it is printed on the AA comparison pages, and is now quoted.)
- Opus 5.5 SWE-bench Pro 89.9% (search snippet only) and any LMArena score for Opus 5.5.
- @rauchg's Next.js eval (Opus 5.5 / GPT-6 Sol / Fable 5.1 at 97%, grok-4.7 at 94%): an X lead, not fetched.
- @hifihedgehog: "GPT-6 Sol is a rebranded Terra successor". A rumor.
- Qwen3.8-Omni-Flash at $0.15/$0.47 (single secondary source).
- VentureBeat: GPT-6 prices are "permanent, not promotional".
- Composer 3 ("Vega"): leaks only.

## Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with 2 WARN `drift:unrouted` lines (2 Codex ids, 223 Cursor ids).
- **After:** `routecheck --no-live` passes (FREE TIERS OK). The live `routecheck` gives **ALL ROUTES OK**, with `route:gpt-6-sol` and `route:gpt-6-luna` PASS and no warnings. `catalog-drift.sh --unrouted` exits 0.
- **CLI versions unchanged:** claude 2.1.280, codex-cli 0.155.1, cursor-agent 2026.09.18-9a7762b. No invocation repairs were needed.
- **Upstream releases:**
  - codex **0.156.0** shipped today. It isn't installed yet, and its notes show no `exec` flag renames.
  - Cursor CLI has published no changelog entry since 2026-08-26.

## Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`).

- **First attempt timed out** (exit 124 after 600 s at `high` effort on a 40 KB diff). Codex's "Reading additional input from stdin..." line was harmless: stdin was `/dev/null`.
- **Retried once** with `MODEL_RUN_TIMEOUT=1500`, exit 0. **Verdict: FIX-FIRST**, with three findings.
- **Checks that came back clean:**
  - The reviewer tested the ignore globs itself: `cursor:claude-opus-5-[lmhx]*` does **not** match `claude-opus-5-6-high`, and `cursor:grok-4.7-[lmx]*-fast` does **not** match the routed `grok-4.7-high-fast`.
  - It confirmed the mock fixture lists both new routed ids and that the updated unrouted assertions pass.

Findings:

1. **Fixed (low): "half the price" was wrong for Luna's output.** Luna's output price is $0.50 against $1.20, about 42%. The wording in model-selection.md, the routes.tsv comment, evaluated.tsv and this report now gives the actual prices.
2. **Fixed (low): contradictory grok-4.7 intro.** The rankings intro still called grok-4.7's scores "an unbenchmarked copy". It now says they were re-scored from AA's benchmark on 2026-09-22.
3. **Rejected (medium): "unsupported numbers".** The flagged numbers were Sol's DeepSWE / OSWorld / AutomationBench, Opus 5.5's HLE 61.4% / GDPval 1846, and Fable 5.1's Design Arena 1369 / 62%. They were missing only from the short evidence summary in the review prompt, not from the sources:
   - The Sol numbers come from OpenAI's launch post, fetched by a research subagent. grok's independent pass reported the same values. The note labels them "OpenAI's own evals".
   - Opus 5.5's HLE and GDPval come from AA's Opus 5.5 article (2026-09-22). GDPval 1846 also appears in Anthropic's table.
   - Fable 5.1's Design Arena numbers come from designarena.ai/models/claude-fable-5-1, fetched 2026-09-22.
   - All are cited in each note's Sources line and in the Evidence section above.

After the fixes: `bash -n` is clean and `routecheck --no-live` gives FREE TIERS OK. The live check wasn't re-run because no routes changed after it passed; the fixes were wording only.

## Verification follow-up (same day)

An independent verifier re-fetched the primary pages and returned FIX-FIRST. What changed (before → after):

- **gpt-6-sol CE 8\* → 9\*.** AA prints $1.06 per index task (Terra $1.40, 5.6-sol $1.99). The costs came out of UNVERIFIED, and the `bulk` rationale now states the real reason (Reliability).
- **fable-5.1 Reliability 9\* → 6\*.** Based on the 72.6% hallucination rate plus the system-card honesty regression. Core Rules, the Reviews section and the Fable-fallback rule were reworded to match.
- **grok-4.6 Reliability 3\* → 4\*.** AA measured 34% (the old score was copied from 4.5's 54%).
- **Astra AA-Omniscience Index.** Now tagged by effort and page: 43 (max, comparison page) and 44 (high, Omniscience board).
- **opus-5.5 58 now pinned to v4.3.2 (max).** The "version not printed" caveat is gone.
- **CE definition.** The sonnet-5-vs-opus-4.8 example is now dated as a 2026-07-21 measurement.
- **Core Rules sub-7 list.** It now includes glm-5.2 (6\*) and fable-5.1.
- **`scout/prompt.md`.** Now requires checking fetched pages before marking a number UNVERIFIED, a final consistency pass, and effort tags on every benchmark number.

## Research provenance

- **x-recency:** ran first, full pass. `model-run: xai-tools x_search=4 web_search=18 x_posts=29 cited_urls=203 status=completed cost_usd=1.1187 store=false`, exit 0. No retry or fallback needed. Output is in `grok-research.md`.
- **Claude checks:** three parallel WebSearch/WebFetch research subagents covered OpenAI GPT-6 Sol/Luna plus the Codex CLI; Anthropic models plus the Claude Code changelog and aliases; and Cursor-catalog models plus the Cursor CLI.
- **My own WebFetch checks:** the OpenAI API pricing page, the Claude Code CHANGELOG, AA's Fable 5.1 article (the 72.6% hallucination rate) and AA's Grok 4.7 article (the 29% rate).
- **Live catalogs:** `codex debug models` (gpt-6-sol/luna default effort `medium`), `cursor-agent --list-models`, and `catalog-drift.sh --unrouted`.

## Needs Dan

- **Fable-quota fallback policy.** Opus 5.5 (Intelligence 10\*, Reliability 9\*) now outranks both Fable 5.1 and Astra. I stopped calling `opus` a downgrade and allowed an announced `opus` re-dispatch as an alternative. I kept `--task-type fable-fallback` → gpt-6-astra as the documented route. Decide whether `opus` should become the *first* choice.
- **Fable 5.1 Reliability lowered 9\* → 6\*.** AA measured a 72.6% AA-Omniscience hallucination rate, worse than Astra's 51% (Reliability 6), and the system card reports an honesty regression, so nothing justified 7. Core Rules now say the ≥7 rule governs delegated output, so Fable keeps the orchestrator/reviewer seat, but its subagent reports get Astra-level review. Confirm you agree.
- **Opus 5.5 Reliability 9\*** is still a copy of opus-4.8's. Its Omniscience Index (46) is only 3 above Fable 5.1's, and AA has published no hallucination rate for it. Re-score when one appears.
- **`bulk` → gpt-6-sol?** AA measures Sol cheaper per task than Terra ($1.06 vs $1.40) and higher on v4.3.2 (48 vs 42), both at max effort. It stays on Terra only because Sol's Reliability 5\* (copied from gpt-5.6-sol) is under the ≥7 unsupervised bar and Terra's is 7. Reconsider once Sol's hallucination and reliability data firms up, or move it now if you accept closer review of bulk output.
- **gpt-5.5 leaves Codex (ChatGPT sign-in) on 2026-10-14.** Expect a `vanished` FAIL then. A later scout run should retire it to `gpt-6-sol`.
- **`system-map.md` / other repos.** todo-service and `second-brain-callcards.timer` run on `gpt-5.6-luna`. `gpt-6-luna` is half the price at the same AA score. Consider switching in those repos; I didn't edit them.
- **`scout/prompt.md` grok hallucination figure.** The first pass flagged that the prompt still said 54% for grok-4.7. The follow-up changed it to AA's measured 29%.
- **Muse Spark 1.3** is a *watch* item behind an ignore row. Its AA score matches gpt-6-sol at a lower per-token price. Reconsider once hallucination and per-task data exist.
- **Connectors.** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.
