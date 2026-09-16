# Alfred System Map

Canonical map of **Alfred** — Dan's multi-surface AI assistant (talk to it on the
phone while driving, in the Android app on the go, on the web at his desk) — and
of every repo, service, port and systemd unit it is wired into on this machine.

## Meta-rules

- **Consult first.** Any task that touches more than one component below — or that
  adds or moves a service, port, systemd unit, repo, or Slack channel — MUST read
  this file before planning or changing anything.
- **Update on change.** The agent making such a change updates this file **in the
  same PR/commit** (source: `~/dotfiles/claude/system-map.md`, symlinked to
  `~/.claude/system-map.md`; see "How to add a component").
- **No volatile values here.** Tunnel URLs, tokens, ports that get picked at
  runtime, project UUIDs, session ids — keep them OUT; name the config file or
  service that holds them instead.
- **State of this file:** units and ports verified 2026-09-16 against
  `systemctl --user list-units --type=service` + `ss -ltn`. Anything marked
  *(planned)* does not exist yet; *(unverified)* means it could not be checked.

## The shape

```
   phone +1 224 300 7842      Android app (planned)      web at the desk (planned)
            | PSTN                     | HTTPS                   | HTTPS
            v                          v                         v
   Twilio Elastic SIP trunk
            | sip:<e164>@sip.voice.x.ai (TLS)
            v
   xAI Grok realtime  --POST /xai/incoming (HMAC)-->  cloudflared quick tunnel
                                                              |
  =========================== ~/projects/alfred ==============|================
   voice-tunnel  (cloudflared + watchdog: re-registers the xAI webhook URL)
            v
   voice-gateway :8790  ---- realtime WS (audio + tool calls) ---- xAI
            |  SELECT call card                | POST /v1/<verb> + caller_id
            v                                  v
        (Postgres)                     brain-actions :8791  --Bearer--> T3 Code
                                               |                       :3773
   todo :4821 (planned)   web/ Caddy :6443 (planned)   android/ (planned)
  ============================================================================
            |                                  |
            v                                  v
   second-brain  Postgres `second_brain` (pgvector) + HTTP :4820 + MCP `brain`
            ^                    ^                         ^
            |                    |                         |
  second-brain-callcards.timer  second-brain-ingest.timer  Claude Code SessionEnd
   (5 min: call cards)          (5 min: transcripts)        hook -> /api/ingest

   Slack --> slackcc --> T3 Code :3773 --> Claude Code sessions in project repos
              (screened by pps :8642 -> llama-guard :8641)
```

## Components

### Alfred hub — `~/projects/alfred`

The voice surface **and** the integration hub. Monorepo; **being restructured
right now** (2026-09-16) into `services/{gateway,brain-actions,lib,todo}`,
`web/`, `android/`, `systemd/`, `bin/`, `docs/research/` — older docs and the
units still say `spike-a/` (gateway) and `brain-actions/`. Do not assume a path;
`ls` first.

| Piece | Port | Unit | Purpose |
|---|---|---|---|
| `services/gateway` (was `spike-a/`) | 8790 (127.0.0.1) | `voice-gateway` | Verifies the xAI Direct-SIP webhook, opens the realtime WS, injects the precomputed call card + tool defs, proxies tool calls, writes transcripts + `call_sessions` |
| `bin/tunnel-watchdog.sh`, `bin/repoint-xai-webhook.sh` | — | `voice-tunnel` | cloudflared **quick** tunnel (URL rotates on every restart — never hard-code it) plus a watchdog that re-registers the new URL as the xAI webhook |
| `services/brain-actions` | 8791 (127.0.0.1) | `brain-actions` | The **only** holder of the T3 Code bearer token. Verbs: `continue_chat`, `new_project_and_chat`, `kick_off_task`, `summarize_recent`, `todos_*`. Enforces per-caller grants; watches T3 turns and writes `pending_briefings`. `/healthz` |
| `services/lib` | — | — | Shared modules |
| `services/todo` | 4821 *(planned)* | *(planned)* | Todo service |
| `web/` | 6443 via Caddy *(planned)* | *(planned)* | Desk surface |
| `android/` | — | — | Native Kotlin app *(planned)*, built on **android-framework** |

- **Data store:** none of its own — everything lives in second-brain's Postgres
  (`second_brain`): `callers`, `caller_identities`, `caller_project_grants`,
  `todos`, `summary_cache`, `call_sessions`, `pending_briefings`.
- **Call path:** phone `+1 224 300 7842` → Twilio Elastic SIP trunk →
  `sip.voice.x.ai` → xAI Grok realtime → webhook → gateway.
- **Talks to:** Postgres (direct SQL), brain-actions (loopback HTTP),
  and through brain-actions to T3 Code's orchestration API.
- **Docs:** `README.md`, `FUTURE-WORK.md`, `CLAUDE.md`,
  `docs/research/{REPORT.md,UPDATE-2026-09.md,APP-DESIGN.md,APP-IMPLEMENTATION-PLAN.md}`.
- **Slack channel:** `alfred` (see slackcc below).

### second-brain — `~/projects/meta/second-brain`

Memory spine for every agent on this box, and the store Alfred answers from.

- **Data store:** Postgres + pgvector, database `second_brain` (PG on :5432).
- **HTTP API:** `127.0.0.1:4820`, bearer auth; config + token in
  `~/.second-brain/config.json` (never print it). `GET /api/voice/staleness`
  reports how fresh the voice call cards are. `POST /api/ingest` = quick ingest.
- **MCP:** stdio server `brain` (`bin/brain-mcp`) registered **globally** via
  `install.sh` → tools `brain_projects`, `brain_search`, `brain_ask`,
  `brain_remember`.
- **Units:** `second-brain` (API), `second-brain-ingest.timer` (5 min: scan
  projects, ingest Claude transcripts, embed, roll up summaries),
  `second-brain-callcards.timer` (5 min fast lane, on `gpt-5.6-luna`: re-renders
  the spoken call cards Alfred opens a call with).
- **Shared ownership:** the spine tables listed under Alfred are **read and
  written by Alfred's gateway and brain-actions shim** — a migration here can
  break a phone call. Coordinate schema changes across both repos.
- **Docs:** `README.md`.

### T3 Code — `~/projects/meta/t3code-v2` (live checkout)

The agent UI/runtime every other surface dispatches into.

- **Unit:** `t3code` → `127.0.0.1:3773`, fronted by HTTPS on
  `https://15.204.108.12:7443`.
- **State:** `~/.t3/userdata/state.sqlite` — query it through
  `~/.claude/t3-conversations.md` (read-only helper, projection tables, raw
  transcript paths).
- **Orchestration API** (used by brain-actions): `/api/orchestration/shell` for
  the workspace snapshot — **not** `/snapshot`, which is ~194 MB — plus dispatch
  of `project.create`, `thread.create`, `thread.turn.start`.
- **Also on the box:** `~/projects/meta/t3code` (older checkout) and the test
  pool units `t3-test-7446` / `t3-test-7448` (ports 3776/3778 HTTP, 7446/7448
  HTTPS). Don't point production traffic at those.

### slackcc — `~/projects/slack`

Bridges Slack threads to T3 Code sessions (a Slack thread == a T3 thread).

- **Unit:** `slackcc` (`Wants=pps.service`) → **pps** `:8642` (Prompt Protection
  Service) → **llama-guard** `:8641` (local Qwen3-4B judge). Non-owner messages
  are screened before they reach an agent.
- **Config:** `config/channels.json` maps a Slack channel → project, cwd,
  `t3_project_id`, model. The **alfred** channel maps to `~/projects/alfred` and
  T3 project `alfred`.
- **CLI:** `/home/dgordon/projects/slack/.venv/bin/{slack-send,slack-upload,slack-wait-reply}`.
- **Direction:** Slack is being **retired as Alfred's notification path** in
  favour of the Android app; don't build new Alfred notification features on it.

### whatsapp-bot — `~/projects/whatsapp-bot`

WhatsApp automation; *(planned)* tap that ingests its conversations into
second-brain. No Alfred wiring yet.

### Claude config — `~/dotfiles/claude` (this repo)

Global `CLAUDE.md`, hooks, agents, skills, model-routing layer, and the reference
docs symlinked into `~/.claude/`: `android.md`, `model-selection.md`,
`model-usage.md`, `t3-conversations.md`, `playwright.md`, **`system-map.md`**
(this file). Its SessionEnd hook feeds second-brain; its SessionStart hooks print
the route-health and `[alfred]` banners. See `README.md` there.

### android-framework — `~/projects/android-framework`

Native-Kotlin app framework + emulator/test layer; the canonical base for new
Android apps on this machine, and what Alfred's Android app will be built on.
Deployment rules live in `~/.claude/android.md`.

## Ports & units at a glance

| Port | Bind | Owner |
|---|---|---|
| 3773 | 127.0.0.1 | T3 Code (`t3code`) — HTTPS front on 7443 |
| 3776 / 3778 | * | T3 test pool (`t3-test-7446` / `t3-test-7448`; HTTPS 7446/7448) |
| 4820 | 127.0.0.1 | second-brain HTTP API |
| 4821 | — | Alfred todo service *(planned)* |
| 5432 | 127.0.0.1 | Postgres (`second_brain`) |
| 6443 | — | Alfred web via Caddy *(planned)* |
| 8641 | 127.0.0.1 | llama-guard (pps judge model) |
| 8642 | 127.0.0.1 | pps |
| 8790 | 127.0.0.1 | Alfred voice-gateway |
| 8791 | 127.0.0.1 | Alfred brain-actions |

Services (`systemctl --user`): `t3code`, `second-brain`, `slackcc`, `pps`,
`llama-guard`, `voice-gateway`, `voice-tunnel`, `brain-actions`,
`t3-test-7446`, `t3-test-7448`.
Timers: `second-brain-ingest.timer`, `second-brain-callcards.timer`,
`t3-claude-import.timer`.
(Also on the box, unrelated to Alfred: `abba-bank`, `dancode-server`,
`dancode-shellhost`.)

## How to add a component

1. **Claim a port** — check this file's table and `ss -ltn` first; bind
   `127.0.0.1` unless it must be reachable off-box.
2. **Ship a `--user` systemd unit** in the owning repo's `systemd/` with an
   `install.sh`, and a `/healthz` (or `/health`) endpoint if it's an HTTP service.
3. **Name the data store** — reuse `second_brain` if it's memory/spine data
   (migrations go in `~/projects/meta/second-brain/migrations/`); say so here if
   you add a new store.
4. **Keep secrets in one place** — a token belongs to exactly one process (the
   T3 token lives only in brain-actions). Config files, not code, not this file.
5. **Update this file** — component entry (repo path, purpose, data store,
   port/unit, who it talks to, where its docs are), the port table, and the
   diagram if you added an edge.
6. **Add it to the banner** — if it's a long-running unit, add it to `UNITS` in
   `~/dotfiles/claude/bin/system-map-probe.sh` so every session sees it up/down.
7. **Wire Slack only if a human needs to talk to it** — `config/channels.json`
   in `~/projects/slack` (and remember Slack is being retired for Alfred).
8. **Re-verify** — `systemctl --user list-units --type=service --no-pager` and
   `ss -ltn`, then update the "verified" date at the top.
