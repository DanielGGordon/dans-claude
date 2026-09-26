# Model scout 2026-09-26: no routing change; 3 models logged (gpt-5.6-cyber, kimi-k2.8-preview not-routable; gpt-6-cyber watch)

## 2026-09-26

### Summary

- **This is the fourth quiet day in a row with no new routable model.** The live catalogs show no drift and no unrouted ids. No lab shipped a model to GA, changed a price or retired a model in the window (2026-09-25 → 09-26). The x-recency pass searched X (`x_search=6`), so no fallback was needed.
- **Three models were logged in `scout/evaluated.tsv` only:**
  - **gpt-5.6-cyber** is on OpenAI's API pricing page but in neither catalog, so it's `not-routable`.
  - **kimi-k2.8-preview** was released 2026-09-11 and missed by earlier runs. It has no id of its own in Cursor's catalog, so it's `not-routable`.
  - **gpt-6-cyber** stays `watch`. It still has no id, and a preview may come at DevDay on 2026-09-29.
- **Route health:** the live routecheck is ALL ROUTES OK (124 PASS). **cursor-agent auto-updated** from 2026.09.23-86fc751 to **2026.09.26-dd393fe**, and every Cursor route passes on it. No repair was needed. Claude Code **2.1.283** and Codex **0.157.0 / 0.157.1** are out but not installed; see Needs Dan.
- **The second review hung on its first attempt again** (exit 124 after 600 s, empty output). The retry finished with **SHIP** and no findings.

### Routing changes

- **`bin/routes.tsv`**: no change. Nothing was added, retired, moved to legacy or ignored, and no task rows moved.
- **`model-selection.md`**: in "Keeping This File Honest", the routecheck date is now 2026-09-26 and the cursor-agent version is 2026.09.26-dd393fe. Nothing else changed.
- **`scout/evaluated.tsv`**: 3 rows added.
- **Not touched:** `hooks/*`, `tests/*`, `model-usage.md`, `agents/model-runner.md`, `README.md` and `system-map.md`.

### Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| gpt-5.6-cyber | OpenAI | unknown | not-routable | Listed under "Cyber models" on the API pricing page at $12.50 input / $1.25 cached / $75 output per Mtok. Not in `codex debug models` or in Cursor's catalog. |
| gpt-6-cyber (re-check) | OpenAI | — | watch | Still no id. Secondary reports mention a "Daybreak Red" alpha and a possible DevDay preview on 2026-09-29. |
| kimi-k2.8-preview | Moonshot | 2026-09-11 | not-routable | A mid-tier model between K2.7 Code and K3 with 1M context. Cursor's catalog still lists only `kimi-k2.7-code` and `kimi-k3-*`, which existing ignore rows cover. No price or AA score. |

These were checked and had nothing new:
- **Anthropic:** news, the deprecations page, and Claude Opus 5.5 still missing from LMArena.
- **AA:** no new article or index version. The Omniscience board still prints Opus 5.5 at Index 46 / accuracy 66% (max) and gives no hallucination rate, so the derived ~59% stands.
- **Other labs:** xAI (`--xai-models` is unchanged and grok-4.7 is still the newest general grok), Google (Gemini API changelog), Cursor (changelog and CLI changelog), Z.ai, DeepSeek, Qwen, MiniMax, Mistral, Meta and Xiaomi.

### Evidence

- **gpt-5.6-cyber:** https://developers.openai.com/api/docs/pricing (undated, fetched 2026-09-26). The row reads "gpt-5.6-cyber | $12.50 | $1.25 | $15.625 | $75.00".
  - $15.625 is the cache-write column (1.25× input, the same ratio as gpt-6-sol's $2 input → $2.50 cache write). It is not cached input. Astra's review agreed.
  - Not in the live Codex catalog, which has 9 slugs, `gpt-reserve` and `codex-auto-review` hidden. Not in Cursor's `--list-models`.
- **gpt-6-cyber:** technology.org/2026/09/25/openai-gpt-6-cyber-preview-daybreak-devday/ (2026-09-25). This came from grok's and a subagent's search results, and I didn't fetch it myself. It is logged in evaluated.tsv only, as `watch`.
- **Kimi K2.8 Preview:** https://llm-stats.com/models/kimi-k2.8 (fetched 2026-09-26). Released 2026-09-11, 1M context, "mid-tier coding and agentic model, positioned between the flagship Kimi K3 and Kimi K2.7 Code". No price or benchmark.
  - **Conflict:** search snippets from Medium and MagicShot say K2.8 Preview "keeps the same API model ID as K2.7 Code". I didn't confirm that on a primary page, since pandaily and kimi.com wouldn't render. If it's true, Cursor's `kimi-k2.7-code` may now serve K2.8. Either way it is covered by the `cursor:kimi-k2.7-*` ignore row, and the evaluated.tsv note says only "no own id".
- **Claude Code 2.1.283** (2026-09-25 21:50): https://github.com/anthropics/claude-code/releases/tag/v2.1.283 (fetched). Relevant lines:
  - "Fixed dynamic workflows started during a model fallback running every agent on the fallback model instead of retrying the configured model"
  - "`claude -p` … no longer load[s] the interactive UI"
  - new `availableModelsMatch` ("exact") and `deniedModels` managed settings

  There's no change to aliases, the default model, `--no-session-persistence`, output formats or the Agent `model` param.
- **Codex 0.157.1** (2026-09-26 01:02 UTC): github.com/openai/codex/releases/tag/rust-v0.157.1. A maintenance tag with no notes; @Codex_Changelog calls it a version bump. The 0.157.0 notes (background-server autostart) are in the 2026-09-25 section.

### Unverified — not quoted

- **@MagicPower21M (2026-09-26), a "leaked DevDay list":** GPT-6.1 Astra, GPT-6 Cyber, "Aeon", "BEL" and a $500 Pro Max tier. It comes from one account.
- **@AI_Screening via @ItsGoharr (2026-09-26):** Gemini 4 Pro is in an arena and beat Opus 5.5 on a 3D sim. This is a rumor.
- **@amn_baluni (2026-09-26):** says, from hallway talk, that DevDay includes a cyber GPT-6.
- **Practitioner anecdotes (2026-09-26):**
  - @PovilasKorop: the same code-audit prompt at medium effort used 68% of Astra's 5-hour limit and 15% of Opus 5.5's.
  - @m1iles: Opus 5.5 is better at frontend and faster than Astra.
  - These are anecdotes and don't change CE or Taste.
- **Codex outage (@thsottiaux, 2026-09-25/26):** Codex was down, service is back, and paid usage limits were reset. This is operational, not a model change.
- **Google AI Overviews' "2026-09-25 launches":** Xing4.0-29B-A4B, TypeSafe Jev, Nemotron 3 Diarization and FLUX 3 Action. grok couldn't confirm any of them on a primary source.
- **"Sonnet/Haiku 5.5 in the coming weeks"** (codersera.com, secondary). No Anthropic source says this.

### Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with no drift and no unrouted ids. It already ran on cursor-agent 2026.09.26-dd393fe.
- **After:** the live `routecheck` gave **ALL ROUTES OK** (124 PASS, 0 FAIL, 0 WARN, hygiene PASS, 22 Cursor test chats deleted). `routecheck --no-live` gives FREE TIERS OK after the edits.
- **CLI versions:**
  - claude 2.1.282 (unchanged)
  - codex-cli 0.156.1 (unchanged)
  - cursor-agent 2026.09.23-86fc751 → **2026.09.26-dd393fe**. It auto-updated, and its changelog has no entry after 2026-08-26.

  No invocation repairs were needed.

### Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`).

- **Attempt 1:** exit 124. model-run timed out after 600 s with empty output, the same first-attempt hang as on 09-22 through 09-24.
- **Attempt 2:** after a pause of about 3 minutes, exit 0 with about 20k tokens.

**Verdict: SHIP**, with no findings. The reviewer checked that all three TSV rows have 5 tab-separated fields and that $1.25 is correctly labeled as cached input, with $15.625 being cache writes. It had only the diff in its workdir, not `routes.tsv`, so its route-consistency check relied on the routecheck result I gave it. No routes changed today.

### Research provenance

- **x-recency:** `model-run: xai-tools x_search=6 web_search=20 x_posts=37 cited_urls=25 status=completed cost_usd=1.2709 store=false`, exit 0. It was the first pass, with no retry and no fallback. The output is in `grok-research.md`.
- **Claude checks:**
  - Two parallel WebSearch/WebFetch subagents (sonnet): one for OpenAI, the Codex CLI, Cursor, xAI, Google, the other labs and AA; one for Anthropic, Claude Code 2.1.283 and the Opus 5.5 evals (AA model and Omniscience pages, LMArena, METR, Design Arena).
  - My own fetches: the Claude Code v2.1.283 release, the OpenAI pricing page and llm-stats' Kimi K2.8 page. The pandaily page for Kimi K2.8 didn't render.
- **Live catalogs:**
  - `cursor-agent --list-models`: no new ids
  - `codex debug models`: unchanged, 9 slugs
  - `bin/model-run.sh --xai-models`: unchanged
  - `catalog-drift.sh --unrouted`: none

### Needs Dan

- **Claude Code 2.1.283 (2026-09-25) isn't installed yet.** It fixes dynamic workflows started during a model fallback, which ran every agent on the fallback model instead of retrying the configured one. That bug could have quietly broken the per-stage model routing in `tests/workflows/orchestration-smoke-*.js`, so re-run those smokes after upgrading. Its new `deniedModels` managed setting could also enforce the "never Haiku for important work" rule in settings rather than prose. That's a judgment call for `settings`, which is outside this run's allowed files.
- **Codex 0.157.x still isn't installed.** Yesterday's note about background-server autostart and the `hygiene:no-test-chats-left` check still applies.
- **The second review hung on its first attempt again.** That's 4 of the last 5 runs. The first attempt reaches model-run's 600 s timeout with empty output, and a retry minutes later finishes in under 2 minutes. This may be worth a look in `bin/model-run.sh` or the codex exec setup, but I left it alone because it's a transient and not a broken route.
- **Still open from earlier runs:**
  - Opus 5.5 at Reliability 7\* vs 6\*.
  - opus-5.5's CAI entry rests on an X post.
  - `bulk` stays on Terra until Sol has an honesty or METR eval.
  - gpt-5.5 leaves Codex on 2026-10-14.
  - cursor-agent auto-updates silently (it happened again today).
- **Connectors:** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.


## 2026-09-25

### Summary

- **A third quiet day with no new routable model.** The live catalogs show no drift and no unrouted ids. No LLM from any lab reached GA, changed price or retired in the window (2026-09-24 → 09-25). Three models are now `watch` because they were announced but not shipped: GPT-6 Cyber, Gemini 4 and Qwen 4. The x-recency pass searched X (`x_search=10`), so no fallback was needed.
- **The opus-5.5 note gains AA's Coding Agent Index v1.5 result: 66** (max effort, Claude Code harness, #1). In the same AA post Opus 5 scores 60 and Fable 5.1 62. It costs **$13.04 per CAI task** vs Opus 5's $10.79 because it uses more tokens. That fits CE 6\* (max is expensive, and the routes here run lower effort), so **no score changes**.
- **Second-review fixes to the same note:**
  - Anthropic's Terminal-Bench 4.0 66.4% was run at **xhigh** and Astra's 57.9% at **high**, not max as the note said.
  - The note now warns that the file's older CAI numbers have no version label and must not be ranked against v1.5.
- **Route health:** the live routecheck is ALL ROUTES OK (124 PASS). Claude Code 2.1.280 → 2.1.282 and codex-cli 0.156.0 → 0.156.1 were installed since the last full check, and no repair was needed. **Codex CLI 0.157.0** came out today and is not installed yet; see Needs Dan.
- **The second review finished on its first attempt this time** (100 s, exit 0). The first-attempt hang from the last three runs did not happen.

### Routing changes

- **`bin/routes.tsv`**: no change. Nothing was added, retired, moved to legacy or ignored, and no task rows moved.
- **`model-selection.md`**
  - **opus-5.5 note, Intelligence bullet:**
    - Adds AA Coding Agent Index v1.5 = 66 (max, Claude Code) and its three sub-scores.
    - Separates AA's Claude Code Terminal-Bench 4.0 result (63.1%) from the Intelligence Index harness's 59.6%.
    - Corrects the effort labels on Anthropic's Terminal-Bench numbers (Opus xhigh, Astra high).
    - Says which CAI numbers in the file are comparable and which aren't.
    - The provisional reason changes from "one day old" to "three days old, and every independent number is from AA".
  - **opus-5.5 note, CE bullet:** adds the $13.04 per CAI task at max (vs Opus 5's $10.79) and notes that AA has published no CAI rows at lower effort.
  - **opus-5.5 note, Sources:** adds AA's CAI post and the orcarouter write-up it was read through.
  - **"Keeping This File Honest":** routecheck date and CLI versions updated to 2026-09-25.
- **`scout/evaluated.tsv`**: 5 rows.
- **Not touched:** `hooks/*`, `tests/*`, `model-usage.md`, `agents/model-runner.md`, `README.md` and `system-map.md`. No ids changed.

### Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| claude-opus-5-5 (re-check) | Anthropic | 2026-09-22 | routed (native) | AA CAI v1.5 66 at $13.04/task (max). Added to the note; scores unchanged. Still no AA-printed hallucination rate. |
| grok-build-0.1 | xAI | May 2026 | ignore (evaluated.tsv only) | In the xAI API model list only. It's a $1/$2 agentic-coding model, not a newer general grok. catalog-drift checks the xai backend for vanished ids only, so no routes.tsv row is needed. |
| gpt-6-cyber | OpenAI | preview "coming weeks" | watch | Possibly at DevDay 2026-09-29. No id, price or score yet. |
| gemini-4 | Google | — | watch | In post-training with no date. |
| qwen-4-\* (re-check) | Alibaba | — | watch | Alibaba says it is "currently in training". No id, price or score yet. |

Checked with nothing new: OpenAI (no model or price change), Anthropic (no Sonnet 5.5 or Haiku 5.5 yet; pricing and deprecation pages unchanged), xAI (no grok newer than 4.7 in `--xai-models`), Cursor (changelog's newest entry is 2026-09-23; CLI changelog's is 2026-08-26), Z.ai, Moonshot, DeepSeek, MiniMax, Mistral, Meta and Xiaomi. AA published no new article in the window.

### Evidence

- **Opus 5.5 Coding Agent Index 66, sub-scores, $13.04/task and ~15.6M vs ~11.4M tokens:** Artificial Analysis on X, https://x.com/ArtificialAnlys/status/2102932119995756613 (2026-09-24).
  - A WebFetch of X returned HTTP 402. The post text shows in the search results, and grok retrieved it through x_search.
  - I read the numbers on https://www.orcarouter.ai/blog/claude-opus-5-5-coding-agent-index (2026-09-24, fetched 2026-09-25), which quotes the AA post and says "Artificial Analysis has not published Coding Agent Index rows at the lower settings."
  - The index version, "Coding Agent Index v1.5", is from https://artificialanalysis.ai/agents/coding-agents (undated, fetched 2026-09-25). The table itself renders client-side.
- **Conflict: comparison rows.** orcarouter lists "GPT-6 Astra 53, GPT-6 Sol 48" as CAI comparisons. Those are their AA *Intelligence Index* v4.3.2 scores, not CAI scores, so I didn't use them. The note quotes only the Opus 5 (60) and Fable 5.1 (62) comparisons from AA's own post.
- **Effort labels on Anthropic's Terminal-Bench numbers:** https://www.anthropic.com/news/claude-opus-5-5 (2026-09-22, re-fetched 2026-09-25).
  - Opus 5.5 at 66.4% is "xhigh effort" and Astra at 57.9% is "high effort", with Astra's "figures … as reported by OpenAI".
  - The page's general rule: "Unless otherwise noted, all Claude Opus 5.5 results use adaptive thinking at max effort."
- **grok-build-0.1:** https://x.ai/news/grok-build-0-1 (2026-05-29): $1/$2 per Mtok, "a coding model specifically trained for agentic coding tasks".
  - **Conflict:** a KuCoin news summary says the beta launched 2026-05-20. The row says "May 2026".
- **GPT-6 Cyber preview:** fortune.com/2026/09/24/openai-launching-gpt-6-cyber-model-and-security-product-devday/ (2026-09-24). Logged in evaluated.tsv only.
- **Gemini 4 in post-training:** 9to5google.com (2026-09-24), quoting Koray Kavukcuoglu. Logged in evaluated.tsv only.
- **Qwen 4 "currently in training":** techafricanews.com (2026-09-24). Logged in evaluated.tsv only.
- **CLI:**
  - Claude Code 2.1.281 (2026-09-23) and 2.1.282 (2026-09-24), from github.com/anthropics/claude-code/releases and code.claude.com/docs/en/changelog: no changes to aliases, the default model, `-p`, `--no-session-persistence`, output formats, the Agent `model` param or Workflow.
  - Codex 0.157.0 (2026-09-25, github.com/openai/codex/releases/tag/rust-v0.157.0) adds GPT-6 Sol/Luna on Bedrock, turns on fullscreen transcripts by default, starts a background server automatically for eligible *interactive* sessions, and applies network policy across redirects. It lists no `codex exec` flag or output changes.

### Unverified — not quoted

- **AA Terminal-Bench-Science 0.1** (@ArtificialAnlys, 2026-09-24): Astra (max) 63%, Opus 5.5 (xhigh) 62% / (max) 59%. A new benchmark, seen in the X post only.
- **Opus 5.5 CAI comparisons "Astra 53 / Sol 48"** (orcarouter): these are its Intelligence Index numbers mislabelled as CAI (see Evidence).
- **@AhamdMurad99471 (2026-09-25): "Grok 4.7 High Fast just dropped in Cursor."** Wrong: `grok-4.7-high-fast` has been routed since 2026-09-22.
- **Practitioner sentiment on Opus 5.5** (@DanielZambrini, @MUSICAHT, @makwired, 2026-09-24/25): "much better than Opus 5", "distilled Fable". Anecdote only.
- **Rumors:**
  - Gemini 4 Pro "in the next three days" (@Priyannkaaaa)
  - a $500 Codex plan (@eidzoku)
  - Grok 5 at 6T parameters (@buildwith_yash)
  - Qwen3.8-Max going from AA 40 to 45 through self-improvement cycles (Alibaba's own claim, not an AA publication)

### Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with no drift and no unrouted ids.
- **After:** the live `routecheck` gave **ALL ROUTES OK** (124 PASS, 0 FAIL, 0 WARN, hygiene PASS, 22 Cursor test chats deleted). `routecheck --no-live` gives FREE TIERS OK both after the edits and after the review fixes.
- **CLI versions:**
  - claude 2.1.280 → **2.1.282**
  - codex-cli 0.156.0 → **0.156.1**
  - cursor-agent 2026.09.23-86fc751 (unchanged)

  All routes pass on these versions, and no invocation repairs were needed.

### Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`). Exit 0 on the first attempt, in about 100 s (11:37:25 → 11:39:05 UTC), using about 71k tokens.

**Verdict: FIX-FIRST.** I fixed both findings:

- **P2, mixed CAI versions:** the new v1.5 score of 66 sat near older unversioned CAI numbers (composer-2.5 62, gpt-5.6-sol 80, Astra 62, gpt-6-sol 57), so a reader could rank 5.6-sol above Opus.
  - The note now limits the comparison to the two models in AA's post and marks the others as unversioned.
  - It also notes that 5.6-sol's 80 is OpenAI's own claim.
  - Astra had said "AA changed the suite" and cited AA's methodology page. I didn't fetch that page, so I wrote "may come from an earlier suite" instead.
- **P2, effort labels:** Anthropic's Terminal-Bench 66.4% is xhigh and Astra's 57.9% is high, not max. I confirmed this by re-fetching the launch post, and the note is corrected.

I rejected nothing.

### Research provenance

- **x-recency:** `model-run: xai-tools x_search=10 web_search=30 x_posts=61 cited_urls=20 status=completed cost_usd=1.8901 store=false`, exit 0. It was the first pass, with no retry and no fallback. The output is in `grok-research.md`.
- **Claude checks:**
  - Two parallel WebSearch/WebFetch subagents (sonnet): one for OpenAI, Cursor, xAI, Google and the other labs plus AA and the Codex/Cursor CLIs; one for Anthropic, the Claude Code 2.1.281/282 releases and AA/METR/Arena on Opus 5.5.
  - My own fetches:
    - AA's Opus 5.5 model page and coding-agents page
    - the orcarouter CAI write-up
    - the Anthropic launch post (effort footnotes)
    - x.ai/news/grok-build-0-1
    - the Codex 0.157.0 release
- **Live catalogs:**
  - `cursor-agent --list-models`: unchanged
  - `codex debug models`: 9 slugs; `gpt-reserve` and `codex-auto-review` hidden
  - `bin/model-run.sh --xai-models`: grok-4.7 is still the newest general grok, alongside grok-build-0.1
  - `catalog-drift.sh --unrouted`: none

### Needs Dan

- **Codex CLI 0.157.0 (2026-09-25) isn't installed yet.** It turns on **automatic background-server startup** for eligible interactive sessions. The notes don't mention `codex exec`, but a persistent daemon could matter to the ephemeral/no-test-chats hygiene. After it lands, check the first routecheck's `hygiene:no-test-chats-left` and `artifact:codex` lines.
- **opus-5.5's CAI entry rests on an X post read through a third-party write-up.** AA's CAI page renders client-side and X blocks fetches. Re-check the numbers against AA's page when it's readable.
- **Still open from earlier runs:**
  - Opus 5.5 at Reliability 7\* vs 6\* (judgment call; 2026-09-24).
  - The Reliability axis has no single anchor.
  - `bulk` stays on Terra until Sol has an honesty or METR eval.
  - gpt-5.5 leaves Codex on 2026-10-14.
  - The second-review first-attempt hang, which didn't happen today (1 of 4 runs clean).
  - cursor-agent auto-updates silently.
- **Connectors:** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.

## 2026-09-24 — Model scout 2026-09-24: no routing change; opus-5.5 Reliability 9\*→7\* on a derived ~59% hallucination rate

### Summary

- **Another quiet day, with no new routable model.** The live catalogs show no drift and no unrouted ids. The only launches in the window were speech models (Gemini 3.8 Flash TTS and Flash-Lite TTS) and a Qwen 4 preview with no API id, and none of them is in a catalog. The x-recency pass searched X (`x_search=8`), so no fallback was needed.
- **opus-5.5 Reliability 9\* → 7\*.** AA's Omniscience board now prints Opus 5.5 (max) at **accuracy 66%** alongside its Index of 46. AA defines the Index as correct − incorrect and the hallucination rate as incorrect ÷ non-correct. That makes Opus's rate **(66−46)/(100−66) ≈ 59%** (55–63% allowing for integer rounding). The method reproduces every rate AA *does* print to within 2 points (Fable 5.1, gpt-6-sol, gpt-6-luna, gpt-5.6-sol). The file labels 59% as derived, not AA-printed.
  - That rate is level with gpt-6-sol (5\*) and worse than Astra's 51% (6), so 9\* broke the file's own rule. Yesterday's note already said to "re-score it the same way" once a comparable rate appeared.
  - The score stays at 7, not 6, only because of Anthropic's honesty claims (vendor-side). That is a judgment call; see Needs Dan.
- **Route health:** the live routecheck is ALL ROUTES OK. cursor-agent auto-updated during the run from 2026.09.18 to **2026.09.23-86fc751**, and every Cursor route passes on it.
- **The second review hung again on its first attempt** (exit 124 after 1200 s, empty output). The retry finished in about 75 s. See Needs Dan.

### Routing changes

- **`bin/routes.tsv`**: no change.
- **`model-selection.md`**:
  - **Table:** opus-5.5 Reliability 9\* → 7\*.
  - **Rankings intro:** a dated 2026-09-24 sentence.
  - **opus-5.5 note:**
    - Taste and Reliability now have separate bullets.
    - The Reliability bullet shows the derivation, the cross-checks and the comparison with Sol and Astra, and quotes METR's scope disclaimer.
    - The Omniscience page and the METR post are added to Sources.
    - The UNVERIFIED benchlm 58.6% bullet now notes that the derivation agrees with it.
  - **"Reviews & Planning":** gives Opus's 7\* and ~59% next to Fable's 6\* and 72.6%.
  - **"Subagent & Workflow Guidelines":** the orchestrator line now says "7\* vs 6\*" and separates the max-effort figures from the high-effort ones.
  - **"Keeping This File Honest":** routecheck date and CLI versions updated to 2026-09-24.
- **`scout/evaluated.tsv`**: 3 rows (opus-5.5 re-check, Gemini 3.8 TTS, Qwen 4 preview).
- **Not touched:** `hooks/route-guard.sh`, `tests/*`, `model-usage.md`, `agents/model-runner.md`, `README.md` and `system-map.md`. No ids changed, and none of these files states Opus's Reliability.

### Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| claude-opus-5-5 (re-check) | Anthropic | 2026-09-22 | routed (native) | AA Omniscience accuracy 66% + Index 46 → derived hallucination ~59% → Reliability 9\* → 7\* |
| gemini-3.8-flash-tts / -flash-lite-tts | Google | 2026-09-22/23 | not-routable | Speech-only (text in, audio out); not in any catalog |
| qwen-4-max / flash / plus / 27b | Alibaba | preview 2026-09-22 | watch | Previewed at Yunqi with no id, price, score or date |

Checked, with nothing new: OpenAI (no model or price change; `sora-2*` and the Videos API shut down 2026-09-24, video only), xAI (no grok newer than 4.7 in `--xai-models`), Cursor (no composer-3; cursor.com/docs/models still lists no GPT-6), Z.ai, Moonshot, DeepSeek, Mistral, Meta, MiniMax and Xiaomi.

### Evidence

- **Opus 5.5 Omniscience accuracy and Index, and AA's definitions:** https://artificialanalysis.ai/evaluations/omniscience (undated; fetched 2026-09-24).
  - The page says: Opus 5.5 (Adaptive Reasoning, Max Effort) Index 46, accuracy 66%; Fable 5.1 Index 43, accuracy 67%; Astra (high) Index 44.
  - Definitions, as the page gives them:
    - Index: "0 equating to a model that answers questions correctly as much as it does incorrectly"
    - Hallucination rate: "incorrect / (incorrect + partial answers + not attempted)"
  - Astra's review also cites AA's methodology paper for the explicit formula (https://arxiv.org/html/2511.13029v1). I have not fetched it; the derivation rests on the page definitions and the cross-checks.
- **Cross-check inputs**, all already in the file with sources:
  - gpt-6-sol 54%/27, AA rate 60%
  - gpt-6-luna 44%/1, AA rate 77%
  - gpt-5.6-sol 59%/22, AA rate 92% (AA Sol/Luna article, 2026-09-22)
  - Fable 5.1 67%/43, AA rate 72.6% (AA Fable 5.1 article, 2026-09-01)
- **METR on Opus 5.5:** https://metr.org/blog/2026-09-22-claude-opus-5-5/ (2026-09-22): "does not attempt to assess whether Claude Opus 5.5 has or does not have particular alignment properties."
- **Opus 5.5's AA hallucination rate is still unprinted:** checked on the AA model page, the -high page and the AA Opus 5.5 article (2026-09-22), all fetched 2026-09-24.
- **Conflict: Opus 5.5's accuracy of 66%.** The Claude research subagent saw it only in a search snippet, while grok and my own fetch of the Omniscience page both read it on the page. I used the page.
- **Conflict: the Gemini 3.8 TTS GA date.** The Gemini API changelog says 2026-09-22 and Google's blog and grok say 2026-09-23. It doesn't affect the verdict, so the row says 09-22/23.
- **CLI:**
  - Claude Code 2.1.281 (2026-09-23; github.com/anthropics/claude-code/releases) has no model, alias, `-p` or persistence-flag changes. It isn't installed here; 2.1.280 is.
  - Codex: the latest stable release is still 0.156.1 (2026-09-23, picker entries only); 0.158.0-alpha.* are pre-releases.
  - Cursor: the CLI changelog's newest entry is still 2026-08-26, yet the installed cursor-agent changed build to 2026.09.23-86fc751.

### Unverified — not quoted

- **@Whats_AI (2026-09-23):** a writing bench with Opus 5.5 at 2631 Elo vs Fable at 2324. A single lab's eval; not fetched.
- **@jn121314 (2026-09-24):** GPT-6 Sol 429s and suspected silent down-routing. One user.
- **@neamtuz (2026-09-24):** "DeepSWE puts Gemini 3.8 Flash level with Astra". No score attached.
- **Sonnet 5.5 / Haiku 5.5 "in the coming weeks":** from emergent.sh (2026-09-22), no date.
- **Moonshot's next K3-line model "before end of October":** search snippet only.
- **Gemini 3.8 Flash-Lite TTS pricing:** $0.50/$6.00, from LiteLLM and AI/TLDR only. It is not a labelled row on the official pricing page.

### Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with no drift and no unrouted ids.
- **After:** the live `routecheck` gave **ALL ROUTES OK** (124 PASS, 0 FAIL, 0 WARN, hygiene PASS, 22 Cursor test chats deleted). `routecheck --no-live` gives FREE TIERS OK, both after the edits and after the review fixes.
- **CLI versions:**
  - claude 2.1.280 and codex-cli 0.156.0 are unchanged.
  - **cursor-agent 2026.09.18-9a7762b → 2026.09.23-86fc751** (auto-update during the run, with no CLI changelog entry). No repair was needed.

### Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`).

- **First attempt:** exit 124 after `MODEL_RUN_TIMEOUT=1200`, with nothing past the header (`Reading additional input from stdin...`). My shell's stdin is `/dev/null`, so stdin wasn't the cause.
- **Retry:** once, after a minute, at 1500 s. Exit 0 in about 75 s (11:58:50 → 12:00:04 UTC), using about 48k tokens.
- **Verdict: FIX-FIRST.** Both findings were fixed:
  - **P2:** the orchestrator line recommends high effort but quoted max-effort evidence. It now gives 58 at max and 54 at high (still above Fable 5.1's 53 at max), and says Reliability was measured at max.
  - **P3:** the note said Opus makes fewer factual errors than Astra, which overstated it. Astra's 51% at Index 43–44 comes to about 19% wrong overall, level with Opus's 20%. The comparison now covers Sol only, and the note says the hallucination evidence alone supports at most 6.
- **Confirmed clean:** the arithmetic (58.8%, 55.1–62.7% from rounding), the honest "derived" label, the METR quote, no current "9\*" claim left, and five fields in every TSV row.
- **Not adopted:** its view that "the exception permits 7; it does not objectively establish" that score. I agree; 7 is left provisional and flagged for Dan below.

### Research provenance

- **x-recency:** `model-run: xai-tools x_search=8 web_search=26 x_posts=44 cited_urls=32 status=completed cost_usd=1.3377 store=false`, exit 0. It was the first pass, with no retry and no fallback. The output is in `grok-research.md`.
- **Claude checks:**
  - Two parallel WebSearch/WebFetch subagents: one for OpenAI, Codex, Cursor and the other labs plus AA; one for Anthropic, the Claude Code releases and AA/METR on Opus.
  - My own WebFetches: the AA Omniscience page (definitions and values), the AA Opus 5.5 article and the METR Opus 5.5 post.
- **Live catalogs:** `cursor-agent --list-models`, `codex debug models` (8 slugs; `gpt-reserve` and `codex-auto-review` hidden), `bin/model-run.sh --xai-models` (grok-4.7 is still the newest text grok), and `catalog-drift.sh --unrouted` (none).

### Needs Dan

- **Opus 5.5 at 7\* or 6\*.** On hallucination alone it is about level with Astra (6) in absolute errors and worse in rate, so it should be 6. It sits at 7 only because of Anthropic's own honesty claims. At 6\*, Opus joins the sub-7 list in Core Rules, and the orchestrator and reviewer carve-out written for Fable would need to cover it too. I chose the smaller change; say if you want 6.
- **The Reliability axis still has no single anchor** (open since 2026-09-23). With the rate derivation available, Reliability could instead be anchored on **absolute wrong-answer share** (accuracy − Index), which rewards knowing more and isn't just abstention. On that measure: Astra ~19%, Opus ~20%, Fable ~24%, Sol ~27%, Luna ~43%, 5.6-sol ~37%.
- **The second-review first attempt hangs** (three runs in a row: 600 s, 600 s, 1200 s). Today's retry took about 75 s. That points to a stuck first request, not slowness. Possible fixes in `bin/model-scout.sh`, which I'm not allowed to edit:
  - a shorter first timeout with an automatic retry
  - run it under `codex exec --json` to see where it stalls
- **cursor-agent auto-updates silently.** 2026.09.23-86fc751 appeared mid-run with no changelog entry. It passed, but the version recorded at the start of the run was stale by the end.
- **Still open from 2026-09-22/23:**
  - `bulk` stays on Terra until Sol has an honesty or METR eval.
  - gpt-5.5 leaves Codex on 2026-10-14.
  - todo-service and second-brain call cards could move to `gpt-6-luna`, but it is at Reliability 3\*.
- **Connectors:** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.

## 2026-09-23 — Model scout 2026-09-23: no routing change; Sol/Luna hallucination rates sourced, opus-5.5 CE 4\*→6\*, Muse to ignore

### Summary

- **Quiet day, no new routable model.** Live catalogs show no drift and no unrouted ids. No model launched in the window that any Cursor or Codex catalog lists; the only launches were Xiaomi's MiMo-V2.6 siblings and Alibaba's Qwen-Audio-3.1, neither in a catalog. Full x-recency pass with measured X search (`x_search=10`), no fallback.
- **GPT-6 Sol/Luna hallucination rates are now sourced.** AA's Sol/Luna article (2026-09-22) states Sol (max) 60% (5.6-sol 92%) and Luna (max) 77% (5.6-luna 93%), plus Coding Agent Index 57 / 41. Yesterday these were UNVERIFIED. **gpt-6-luna Reliability 4\* → 3\***: 77% is worse than grok-4.5's 54% (3), and nothing offsets it. **gpt-6-sol stays 5\***, and its note now gives the reason. `bulk` stays on Terra.
- **opus-5.5 Cost Efficiency 4\* → 6\*.** AA's per-effort pages (v4.3.2): **high 54 at $1.82/task**, medium 51 at $1.34/task, against the max run's 58 at $5.98. At high it still beats Astra (max) and Fable 5.1 (max), both 53, at 56% of Astra's per-task cost.
- **Muse Spark 1.3 moves from watch to ignore.** AA now prints $1.60 per index task (max) at 48. gpt-6-sol gets the same 48 for $1.06.
- **Route health:** live routecheck ALL ROUTES OK on codex-cli 0.156.0, which was installed since the last full check. No invocation repairs.

### Routing changes

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

### Models evaluated

| Model | Vendor | Released | Verdict | Why |
|---|---|---|---|---|
| gpt-6-sol (re-check) | OpenAI | 2026-09-22 | routed (already) | AA hallucination 60% (max) and CAI 57 now sourced; Reliability 5\* kept, justification added |
| gpt-6-luna (re-check) | OpenAI | 2026-09-22 | routed (already) | AA hallucination 77% (max), CAI 41; Reliability 4\* → 3\* |
| claude-opus-5-5 (re-check) | Anthropic | 2026-09-22 | routed (native) | AA high 54 at $1.82/task → CE 6\*; AA hallucination rate still unpublished |
| muse-spark-1.3 | Meta | 2026-09-02 | ignore (was watch) | $1.60 vs gpt-6-sol's $1.06 per AA task at the same 48 (max) |
| mimo-v2.6-flash / -pro-ultraspeed | Xiaomi | 2026-09-22 | not-routable | Not in any catalog |
| qwen-audio-3.1 | Alibaba | 2026-09-23 | not-routable | Speech stack, not a text model in any catalog |

### Evidence

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

### Unverified — not quoted

- **Opus 5.5 hallucination rate 58.6%:** benchlm.ai, credited to AA, no effort label, "last updated 2026-09-22", backed by a search snippet (aivy.com.au, 403). The only repo mention is the UNVERIFIED bullet. A tosea.ai write-up gives 59%.
- **@bcherny (2026-09-23):** "fix landing, going out in tomorrow's release". A possible Claude Code 2.1.281, with no notes yet.
- **@pilvar222 (Aikido, 2026-09-23):** on a 32-CVE set, recall was Luna 53.1% and Sol 68.8%, both below GPT-5.6, with cost per CVE down. From an X post; not fetched.
- **Composer 3:** forum wishes only. "Command A+" and "Solar Mini 4" appear on aggregators, with nothing in any catalog.
- **Muse Spark 1.3 xhigh 45 at $1.37/task:** from grok, via the AA releases page; not fetched.

### Route health

- **Before:** the wrapper's live routecheck gave ALL ROUTES OK, with no drift and no unrouted ids.
- **After:** `routecheck --no-live` gives FREE TIERS OK, before and after the review fix. The live `routecheck` gives **ALL ROUTES OK** (all codex, cursor, xai and native routes PASS, hygiene PASS).
- **CLI versions:** codex **0.155.1 → 0.156.0** since the previous full check. Every codex route passes on it, so no repair was needed. claude 2.1.280 and cursor-agent 2026.09.18-9a7762b are unchanged. codex 0.156.1 is out but not installed.

### Second review

**Reviewer: gpt-6-astra** (`--task-type second-review`).

- **First attempt timed out** (exit 124 at 600 s, as it did yesterday). **Retried once** with `MODEL_RUN_TIMEOUT=1500`, exit 0.
- **Verdict: FIX-FIRST**, with one finding.
- **What it checked and found clean:** it independently confirmed that every task row resolves, that the `retired` rows match route-guard's `RETIRED`, and that the edited ignore row keeps its three fields. It found Opus CE 6\* supported by the explicitly labelled high-effort comparison.
- **Finding (medium), fixed in part and rejected in part:**
  - **The finding:** Sol 5\* (60%) and Luna 4\* (77%) both score above grok-4.5's 3 (54%) without cited honesty evidence.
  - **Luna, fixed:** its Reliability went 4\* → 3\*, since nothing offsets its rate.
  - **Sol, kept at 5\*:** lowering it to 3 would rank it below its own predecessor gpt-5.6-sol (5, at 92%). Its note now cites the honesty-side evidence the rule asks for: AA's measured abstention gain (83% attempted vs 99%) and OpenAI's "about half as many mistakes" factuality claim, labelled as a vendor claim.
- After the fix, `routecheck --no-live` passes. The live check wasn't re-run because only doc scores changed after it passed.

### Research provenance

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

### Needs Dan

- **Reliability anchors don't track hallucination rate consistently.** grok-4.5 is 3 at 54%, but Fable 5.1 is 6\* at 72.6%, gpt-5.6-sol is 5 at 92% and gpt-6-sol is 5\* at 60%. The scout's "a worse rate can't outscore" rule therefore has to lean on honesty evidence to justify every row except grok-4.5's. The Fable 5.1 note says "nothing offsets" its rate, yet it outscores grok-4.5. Either re-anchor grok-4.5 (its 3 predates AA v4.3), or state in the axis definition that Reliability weighs honesty and eval-gaming separately from Omniscience. I didn't touch the legacy grok-4.5 or fable rows.
- **Opus 5.5 hallucination rate.** A secondary site gives 58.6%. If AA confirms it, Opus 5.5 would sit between Astra (51%, Reliability 6) and Fable 5.1 (72.6%, 6\*), and its 9\* would need Anthropic's honesty claims to hold up independently.
- **The second-review route times out at 600 s** on two consecutive runs, even on a 14 KB diff. Astra's `high` pin is slow. Consider a higher default `MODEL_RUN_TIMEOUT` for second-review, or `MODEL_RUN_EFFORT=medium` in `bin/model-scout.sh`, which is outside my allowed files.
- **Still open from 2026-09-22:**
  - `bulk` stays on Terra. Reconsider on an honesty or METR eval for Sol.
  - gpt-5.5 leaves Codex on 2026-10-14.
  - todo-service and second-brain call cards could move to `gpt-6-luna`. Note its Reliability is now 3\* against 5.6-luna's unscored row, so check extraction quality first.
  - Opus-first as the Fable fallback.
- **Connectors:** claude.ai Gmail and Google Drive need authorizing in the claude.ai connector settings. This run didn't need them.
