# Model scout 2026-09-23: no routing change; Sol/Luna hallucination rates sourced, opus-5.5 CE 4\*→6\*, Muse to ignore

## Summary

- **Quiet day, no new routable model.** Live catalogs show no drift and no unrouted ids. No model launched in the window that any Cursor or Codex catalog lists; the only launches were Xiaomi's MiMo-V2.6 siblings and Alibaba's Qwen-Audio-3.1, neither in a catalog. Full x-recency pass with measured X search (`x_search=10`), no fallback.
- **GPT-6 Sol/Luna hallucination rates are now sourced.** AA's Sol/Luna article (2026-09-22) states Sol (max) 60% (5.6-sol 92%) and Luna (max) 77% (5.6-luna 93%), plus Coding Agent Index 57 / 41. Yesterday these were UNVERIFIED. **gpt-6-luna Reliability 4\* → 3\***: 77% is worse than grok-4.5's 54% (3), and nothing offsets it. **gpt-6-sol stays 5\***, and its note now gives the reason. `bulk` stays on Terra.
- **opus-5.5 Cost Efficiency 4\* → 6\*.** AA's per-effort pages (v4.3.2): **high 54 at $1.82/task**, medium 51 at $1.34/task, against the max run's 58 at $5.98. At high it still beats Astra (max) and Fable 5.1 (max), both 53, at 56% of Astra's per-task cost.
- **Muse Spark 1.3 moves from watch to ignore.** AA now prints $1.60 per index task (max) at 48. gpt-6-sol gets the same 48 for $1.06.
- **Route health:** live routecheck ALL ROUTES OK on codex-cli 0.156.0, which was installed since the last full check. No invocation repairs.

## Routing changes

- **`bin/routes.tsv`**: no `model`, `task` or `retired` row changes.
  - The dated comment on gpt-6-sol/luna now records Sol's measured 60% hallucination rate as the reason `bulk` stays on Terra.
  - The `cursor:muse-spark-1.3-*` ignore reason changed from "watch … no per-task cost data" to "dominated by gpt-6-sol ($1.60 vs $1.06 per AA index task at 48)".
- **`model-selection.md`**
  - **Table:**
    - opus-5.5 CE 4\* → 6\*
    - gpt-6-luna Reliability 4\* → 3\*
  - **Rankings intro:** a dated 2026-09-23 sentence.
  - **gpt-6-sol/luna note:**
    - Hallucination rates, attempt rate, accuracy and Coding Agent Index are now quoted with their source.
    - The UNVERIFIED bullet is gone.
    - Sol's Reliability justification is written out.
  - **opus-5.5 note:**
    - Per-effort AA numbers and the CE rationale.
    - Design Arena 67% WR over 98 tournaments.
    - Anthropic's honesty claims, labelled as vendor claims.
    - The benchlm 58.6% hallucination figure added to UNVERIFIED.
  - **Bulk section:** Sol's 60% replaces "not yet on a fetched AA page".
  - **"Keeping This File Honest":** routecheck date 2026-09-23.
- **`scout/evaluated.tsv`**: 6 rows.
- **Not touched:** `hooks/route-guard.sh`, `tests/routecheck.sh`, `tests/workflows/*`, `model-usage.md`, `agents/model-runner.md`, `README.md` and `system-map.md` needed no change, because no ids changed.

## Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| gpt-6-sol (re-check) | OpenAI | 2026-09-22 | routed (already) | AA hallucination 60% (max) and CAI 57 now sourced; Reliability 5\* kept, justification added |
| gpt-6-luna (re-check) | OpenAI | 2026-09-22 | routed (already) | AA hallucination 77% (max), CAI 41; Reliability 4\* → 3\* |
| claude-opus-5-5 (re-check) | Anthropic | 2026-09-22 | routed (native) | AA high 54 at $1.82/task → CE 6\*; AA hallucination rate still unpublished |
| muse-spark-1.3 | Meta | 2026-09-02 | ignore (was watch) | $1.60 vs gpt-6-sol's $1.06 per AA task at the same 48 (max) |
| mimo-v2.6-flash / -pro-ultraspeed | Xiaomi | 2026-09-22 | not-routable | Not in any catalog |
| qwen-audio-3.1 | Alibaba | 2026-09-23 | not-routable | Speech stack, not a text model in any catalog |

## Evidence

- **GPT-6 Sol/Luna Omniscience + CAI:** https://artificialanalysis.ai/articles/gpt-6-sol-and-luna-push-the-cost-efficiency-frontier (2026-09-22; fetched 2026-09-23). Quotes:
  - "GPT-6 Sol (max) cuts its hallucination rate from 92% to 60% and GPT-6 Luna (max) from 93% to 77%"
  - "it attempts 83% of questions vs 99% for GPT-5.6 Sol (max) … lowers accuracy 5 points from 59% to 54%"
  - "Luna's accuracy is broadly unchanged at 44% vs 43%"
  - Coding Agent Index: Sol 57 (+2), Luna 41 (−2), both max
  - The article names the Intelligence Index "v4.3". The comparison pages print v4.3.2.
- **Opus 5.5 per effort (AA Intelligence Index v4.3.2):**

  | Effort | Score | $ per index task | Output tokens | Source (undated; fetched 2026-09-23) |
  |---|---|---|---|---|
  | max | 58 | $5.98 | not quoted | https://artificialanalysis.ai/models/claude-opus-5-5 |
  | high | 54 | $1.82 | 53M | https://artificialanalysis.ai/models/claude-opus-5-5-high |
  | medium | 51 | $1.34 | 38M | https://artificialanalysis.ai/models/claude-opus-5-5-medium |

  - AA's Omniscience board and the Opus-vs-Fable comparison page print the Omniscience Index (46), but no hallucination rate.
- **Opus 5.5 Design Arena:** https://www.designarena.ai/models/claude-opus-5-5 (undated; fetched 2026-09-23): 67% overall win rate over 98 tournaments. No Elo and no rank are shown.
- **Opus 5.5 honesty (vendor):** https://www.anthropic.com/news/claude-opus-5-5 (2026-09-22): "our strongest model on most measures of honesty", and boundary circumvention "around 85% less often than Opus 5 or Claude Mythos 5.1".
- **Muse Spark 1.3:** https://artificialanalysis.ai/models/muse-spark-1-3 (undated; fetched 2026-09-23): "Muse Spark 1.3 (max)", 48, #17/212, $1.60 per index task, $1.25/$4.25. No Omniscience figures.
- **Conflict, resolved:** a research subagent read the AA comparison pages' "Non-Hallucination Rate" as 84% for *both* GPT-6 Sol and GPT-5.6 Sol, which would imply a 16% hallucination rate. That contradicts the AA article's explicit prose (92% → 60%) and the 92% for 5.6-sol already in the file. My own re-fetch of the comparison page found the metric's definition but no values. I went with the article.
- **CLI:**
  - codex 0.156.0 notes: https://github.com/openai/codex/releases/tag/rust-v0.156.0 (2026-09-22). TUI, voice, `/usage`, worktrees and a new `--no-daemon` flag. Nothing touching `codex exec` flags, JSON output, `--ephemeral` or `debug models`.
  - 0.156.1 (2026-09-23) is a hotfix: Sol/Luna in the picker.
  - Claude Code: 2.1.280 is still the latest, per https://github.com/anthropics/claude-code/releases.
  - Cursor CLI: the latest changelog entry is still 2026-08-26 (https://cursor.com/docs/cli/changelog).

## Unverified — not quoted

- **Opus 5.5 hallucination rate 58.6%:** benchlm.ai, credited to AA, no effort label, "last updated 2026-09-22", backed by a search snippet (aivy.com.au, 403). The only repo mention is the UNVERIFIED bullet. A tosea.ai write-up gives 59%.
- **@bcherny (2026-09-23):** "fix landing, going out in tomorrow's release". A possible Claude Code 2.1.281, with no notes yet.
- **@pilvar222 (Aikido, 2026-09-23):** on a 32-CVE set, recall was Luna 53.1% and Sol 68.8%, both below GPT-5.6, with cost per CVE down. From an X post; not fetched.
- **Composer 3:** forum wishes only. "Command A+" and "Solar Mini 4" appear on aggregators, with nothing in any catalog.
- **Muse Spark 1.3 xhigh 45 at $1.37/task:** from grok, via the AA releases page; not fetched.

## Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with no drift and no unrouted ids.
- **After:** `routecheck --no-live` gives FREE TIERS OK, before and after the review fix. The live `routecheck` gives **ALL ROUTES OK** (all codex, cursor, xai and native routes PASS, hygiene PASS).
- **CLI versions:** codex **0.155.1 → 0.156.0** since the previous full check. Every codex route passes on it, so no repair was needed. claude 2.1.280 and cursor-agent 2026.09.18-9a7762b are unchanged. codex 0.156.1 is out but not installed.

## Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`).

- **First attempt timed out** (exit 124 at 600 s, as it did yesterday). **Retried once** with `MODEL_RUN_TIMEOUT=1500`, exit 0.
- **Verdict: FIX-FIRST**, with one finding.
- **What it checked and found clean:** it independently confirmed that every task row resolves, that the `retired` rows match route-guard's `RETIRED`, and that the edited ignore row keeps its three fields. It found Opus CE 6\* supported by the explicitly labelled high-effort comparison.
- **Finding (medium), fixed in part and rejected in part:**
  - **The finding:** Sol 5\* (60%) and Luna 4\* (77%) both score above grok-4.5's 3 (54%) without cited honesty evidence.
  - **Luna, fixed:** its Reliability went 4\* → 3\*, since nothing offsets its rate.
  - **Sol, kept at 5\*:** lowering it to 3 would rank it below its own predecessor gpt-5.6-sol (5, at 92%). Its note now cites the honesty-side evidence the rule asks for: AA's measured abstention gain (83% attempted vs 99%) and OpenAI's "about half as many mistakes" factuality claim, labelled as a vendor claim.
- After the fix, `routecheck --no-live` passes. The live check wasn't re-run because only doc scores changed after it passed.

## Research provenance

- **x-recency** ran first as a full pass: `model-run: xai-tools x_search=10 web_search=24 x_posts=62 cited_urls=27 status=completed cost_usd=1.5575 store=false`, exit 0. No retry or fallback. The output is in `grok-research.md`.
- **Claude checks:**
  - Two parallel WebSearch/WebFetch subagents: one for OpenAI, Codex and Cursor plus the other labs; one for Anthropic, the Claude Code changelog, aliases and the AA Opus data.
  - My own WebFetch checks:
    - the AA Sol/Luna article
    - the AA Opus 5.5 article
    - the AA opus-5-5, -high and -medium pages
    - the Opus-vs-Fable and Sol-vs-5.6-Sol comparison pages
    - the AA Muse Spark 1.3 page
    - the Design Arena Opus 5.5 page
    - the Anthropic Opus 5.5 launch post
- **Live catalogs:** `codex debug models` (unchanged; `gpt-reserve` and `codex-auto-review` are hidden), `cursor-agent --list-models`, `catalog-drift.sh --unrouted` (none) and `model-run.sh --xai-models` (no grok newer than 4.7).

## Needs Dan

- **Reliability anchors don't track hallucination rate consistently.** grok-4.5 is 3 at 54%, but Fable 5.1 is 6\* at 72.6%, gpt-5.6-sol is 5 at 92% and gpt-6-sol is 5\* at 60%. The scout's "a worse rate can't outscore" rule therefore has to lean on honesty evidence to justify every row except grok-4.5's. The Fable 5.1 note says "nothing offsets" its rate, yet it outscores grok-4.5. Either re-anchor grok-4.5 (its 3 predates AA v4.3), or state in the axis definition that Reliability weighs honesty and eval-gaming separately from Omniscience. I didn't touch the legacy grok-4.5 or fable rows.
- **Opus 5.5 hallucination rate.** A secondary site gives 58.6%. If AA confirms it, Opus 5.5 would sit between Astra (51%, Reliability 6) and Fable 5.1 (72.6%, 6\*), and its 9\* would need Anthropic's honesty claims to hold up independently.
- **The second-review route times out at 600 s** on two consecutive runs, even on a 14 KB diff. Astra's `high` pin is slow. Consider a higher default `MODEL_RUN_TIMEOUT` for second-review, or `MODEL_RUN_EFFORT=medium` in `bin/model-scout.sh`, which is outside my allowed files.
- **Still open from 2026-09-22:**
  - `bulk` stays on Terra. Reconsider on an honesty or METR eval for Sol.
  - gpt-5.5 leaves Codex on 2026-10-14.
  - todo-service and second-brain call cards could move to `gpt-6-luna`. Note its Reliability is now 3\* against 5.6-luna's unscored row, so check extraction quality first.
  - Opus-first as the Fable fallback.
- **Connectors:** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.
