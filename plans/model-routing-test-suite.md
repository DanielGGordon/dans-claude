> Design produced 2026-07-21 by a 6-agent workflow. STATUS: the lean core (auth checks + live nonce smokes per route) is IMPLEMENTED as tests/routecheck.sh — this doc is the blueprint for the remaining tiers (manifest, lints, hooks, scheduling) if ever needed.

# Model-Routing Test Suite (`routecheck`)

Tests the **routing layer** of the personal delegation policy: model ids valid, auth alive, wrappers honest, policy files consistent with reality. Skeleton is Design 3 (ops-first, best repo fit), with Design 2's deep contract checks and Design 1's xref/context-injection grafted in.

## Goals & non-goals

**Goals**

- Catch the four verified failure modes before a delegation fails: (1) policy drift / silent alias retirement, (2) auth rot, (3) wrapper-contract violations, (4) catalog churn.
- Zero-token by default; token spend only via explicit `--live`, bounded and cheap (nonce smokes, not benchmarks).
- Zero-maintenance: one bash entrypoint + one python3-stdlib linter; small enough to rewrite in an afternoon.
- Results reach the developer passively (SessionStart banner, statusline) without ever running tests in a hook or blocking a session.
- Every FAIL prints its fix inline.

**Non-goals**

- Model quality/latency benchmarking; prompt evals.
- Auto-repair — the `/routecheck` skill proposes and applies fixes only with the developer in the loop, via the mandated dotfiles workflow.
- Monitoring provider incidents or quota levels beyond "auth alive".

## Keystone: the route manifest

`~/dotfiles/claude/models-manifest.tsv` — single machine-readable source of truth both split policy files (`model-usage.md`, `model-selection.md`) and all tests join against. Columns:

```
# id                     provider   invocation     tier   status
gpt-5.5                  openai     codex          core   active
gpt-5.6-sol              openai     codex          full   active
composer-2.5             cursor     cursor-agent   core   active
cursor-grok-4.5-high     cursor     cursor-agent   core   active
cursor-grok-4.5-medium   cursor     cursor-agent   full   active
haiku                    anthropic  native         core   active
fable                    anthropic  native         full   active
grok-direct-xai          xai        api            full   unwired
```

`tier=core` bounds default token spend (~4 routes); `--live-all` runs `full`. `status` gives graceful retirement (`deprecated` ids may linger in prose history but fail if recommended). Id-extraction regexes for the static lint are **derived from the manifest's id column prefixes** plus a broad fallback heuristic, so newly adopted gemini/kimi/glm ids can't be invisible to the lint.

Prose claims in `model-usage.md` that depend on live CLI behavior carry verify-tags — `<!-- verify: cursor-unknown-id-hard-errors -->` — binding each claim to the live test that re-proves it (superior to a denylist: the link lives next to the claim).

## Test inventory

| Test | Checks | Method | Cost | Cadence |
|---|---|---|---|---|
| **Tier 0 — static lint** | | | | |
| `manifest-lint` | TSV well-formed, no duplicate ids | awk field count + `sort \| uniq -d` | free, <1s | every run |
| `policy-ids` | every model id in both policy files exists in manifest with `status=active` | `lint_policy.py` extracts ids (patterns derived from manifest), joins | free | every run |
| `cross-file` | every id the model-selection.md recommends has an invocation recipe in the model-usage.md; manifest ids unreferenced anywhere → WARN | same script | free | every run |
| `wrapper-flag-lint` | codex snippets carry `--dangerously-bypass-approvals-and-sandbox`; cursor snippets carry `--print --trust --force --output-format text`; `command -v codex cursor-agent` | fixed-string grep | free | every run |
| `xref-files` | every `~/.claude/*.md` path referenced in CLAUDE.md + both policy files exists and symlinks into dotfiles (fires on real dangling refs today) | grep paths; `test -L && test -e` | free | every run |
| `lint-self-test` | the linter itself still sees drift | run `lint_policy.py` on `fixtures/good.md` + `fixtures/drifted.md`; assert pass/fail | free | every run |
| **Tier 1 — live, zero-token** | | | | |
| `codex-auth` | session alive | `codex login status` contains "Logged in"; WARN if `~/.codex/auth.json` mtime >21d | free, ~5s | every run |
| `cursor-auth` | session alive | `cursor-agent status` contains "Logged in" | free | every run |
| `cursor-catalog` | every active cursor id in manifest appears **verbatim** in `cursor-agent --list-models` (extract field 1 of `id - Name` lines). Retirement aliases don't appear → the grok-4.5-xhigh class fails here at zero tokens | exact match vs live list | free | every run |
| `catalog-churn` | live list vs committed snapshot; additions WARN ("new model: …, consider policy"), removals FAIL | `diff` vs `cursor-models.snapshot`; `--accept-catalog` rewrites it (reviewed git diff) | free | every run |
| `cli-versions` | codex/cursor-agent binary changed since last run → WARN "re-run --live" | compare `--version` to `route-health.json` | free | every run |
| `xai-wiring` | if manifest marks xai route active, `XAI_API_KEY` set; skip if `unwired` | env test | free | every run |
| **Tier 2 — smoke (`--live`)** | | | | |
| `smoke-<route>` | end-to-end: id accepted, auth works in exec path, output verbatim | exact policy command per manifest row, run from throwaway dir (`codex -C /tmp/routecheck-$$`; `cd` there for cursor) — never smoke from ~/dotfiles with bypass flags. Prompt: `Output exactly this line and nothing else: ROUTE-OK-<nonce>` (fresh nonce per run); assert stdout contains it | ~100 tok/route; core ≈4 routes, <$0.01, ~2min parallel | weekly + manual |
| `model-identity-<route>` | **served** model equals requested id (catches accepted-but-aliased ids that pass `cursor-catalog`) | codex: parse session-header `model:` line; cursor: `--output-format json` model field (see Open questions) | piggybacks on smoke | weekly + manual |
| `bad-id-pin` | "unknown ids hard-error, no silent fallback" claim, **per CLI family** | invoke codex and cursor-agent with `--model definitely-not-a-model-xq7`; assert fast nonzero exit, no completion text; linked via verify-tag | ~0 tokens | weekly + manual |
| `auth-error-loudness` | policy's documented error patterns match reality | opportunistic: only when an auth check FAILed, run one live call and grep output for `Authentication required` / `insufficient_quota` / `429` | ~0 tokens | on auth FAIL |
| `smoke-claude` | native `--model` routing works | `claude -p --model haiku "$(cat fixtures/smoke.prompt)"` (cheapest only) | ~50 tok | weekly + manual |
| **Tier 3 — in-session (skill only)** | | | | |
| `wrapper-verbatim` | the actual Agent-tool wrapper contract: VERBATIM return, no self-substitution (bash tests only the CLI pipe; this is the only true FM3 enforcement) | `/routecheck` spawns one real wrapper subagent with standard "call codex, return VERBATIM" instructions on the nonce canary; assert nonce line survives unmodified, no added answer | ~1 wrapper run | manual `/routecheck` |
| `native-model-param` | Agent-tool `model` param routes | spawn `{model:'haiku'}` agent, self-id sanity check | ~50 tok | manual `/routecheck` |

## Triggers & scheduling

1. **Manual (primary):** `routecheck` (Tiers 0–1, always free) and `routecheck --live` / `--live-all`, via `aliases.sh`. Safe anytime.
2. **`/routecheck` skill:** runs the script (Tiers 0–2), performs Tier 3, then walks the failure→fix map and applies edits per the global workflow: edit in `~/dotfiles/claude/`, update README, commit, re-run `install.sh`.
3. **Weekly scheduled agent** (schedule skill, Sun 09:00 — not plain crontab): runs `routecheck --live`; notifies only on FAIL/WARN. Sole recurring token spend.
4. **SessionStart hook (`route-health-banner.sh`): never runs tests.** Reads `~/.claude/route-health.json` (<5ms, no network); if overall≠ok or report >14d stale, emits hook `additionalContext`: `ROUTING PREFLIGHT FAILING: cursor-catalog (cursor-grok-4.5-high missing) — run /routecheck`. The main session learns routing is broken at the moment it might delegate.
5. **Statusline:** `statusline-command.sh` appends `⛔route` under the same condition.

## Reporting

TAP-flavored stdout, fix inline:

```
ok   policy-ids       14 ids, all active
FAIL cursor-catalog   'cursor-grok-4.5-high' not in --list-models
     fix: retire in models-manifest.tsv + model-selection.md; pick successor; routecheck --accept-catalog
warn catalog-churn    new: gpt-5.6-terra, kimi-k3 — consider policy
routecheck: 12 ok, 1 warn, 1 fail  (tier 0+1, 12s, 0 tokens)
```

Exit code = FAIL count. Machine state: `~/.claude/route-health.json` (outside the repo — mutable state, not config): `{ts, overall, live_ts, cli_versions, checks:[{id,status,detail,fix}]}`. Single state channel consumed by hook, statusline, skill, and scheduled agent.

## File layout

```
~/dotfiles/claude/
  models-manifest.tsv                  # source of truth
  model-usage.md / model-selection.md       # split policy, with <!-- verify: --> tags
  tests/routecheck/
    routecheck                         # bash entry: tiers 0+1; --live, --live-all, --accept-catalog
    lint_policy.py                     # python3 stdlib only
    cursor-models.snapshot             # committed catalog baseline
    fixtures/{smoke.prompt,good.md,drifted.md}
  skills/routecheck/SKILL.md           # /routecheck
  hooks/route-health-banner.sh         # SessionStart, read-only
```

Installed via existing `install.sh` symlinks; hook registered in `settings.partial.json`; README gains a section per repo convention.

## Failure → fix mapping (encoded in the script, printed with each FAIL)

| Failure | Fix emitted |
|---|---|
| `policy-ids` / `cross-file` | add manifest row or fix the .md; commit |
| `xref-files` | fix path or re-run `install.sh` (dangling symlink) |
| `cursor-catalog` / `model-identity` / smoke hard-error | id retired or aliased: pick successor from `--list-models`, update manifest + model-selection.md, `--accept-catalog` |
| `catalog-churn` WARN | review new models; adopt in manifest/policy or just `--accept-catalog` |
| auth FAIL | exact command: `cursor-agent login` / `codex login` (interactive; STOP delegating until done) |
| `bad-id-pin` unexpected success | CLI regained silent fallback: update the verify-tagged claim in model-usage.md |
| `wrapper-verbatim` | tighten VERBATIM instructions in model-usage.md; retest via `/routecheck` |
| `cli-versions` WARN | `routecheck --live` |
| `lint-self-test` | policy format changed; fix `lint_policy.py` patterns before trusting green |

## Open questions

1. **Cursor served-model metadata:** does `--output-format json` actually expose the served model id? Verify during implementation; if absent, `model-identity` degrades to catalog membership + WARN-level self-id from the canary.
2. **Codex model listing:** codex has no list command — bad `-m` erroring in the smoke is the only validity check. Acceptable, or probe `codex exec --help`/config for a catalog?
3. **Bogus-id token cost:** confirm both CLIs reject unknown ids pre-inference (expected ~0 tokens); if codex bills, drop its half of `bad-id-pin` to weekly only.
4. **Scheduled-agent notification path:** confirm the schedule skill's FAIL-only notification works headlessly on this host, else fall back to the banner as sole delivery.
5. **Snapshot scope:** snapshot only ids (field 1) or full `id - Name` lines? Ids-only reduces churn noise from display-name edits.