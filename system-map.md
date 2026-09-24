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
- **State of this file:** units, timers and ports re-verified **2026-09-16** against
  `systemctl --user list-units --type=service`, `systemctl --user list-timers` and
  `ss -ltn`. Anything marked *(planned)* does not exist yet; *(unverified)* means it
  could not be checked. **All three Alfred surfaces are live as of 2026-09-16**:
  voice, the web app (**primary origin now `https://15.204.108.12:7443/alfred/`**,
  mirrored unchanged at `:6443` — see "Public origin" below), and the Android app
  (v1.0.0, sideloaded).

## The shape

```
   phone +1 224 300 7842    Android app (v1.0.0, live)   web at the desk (live)
            | PSTN                     | HTTPS                   | HTTPS
            v                          v                         v
   Twilio Elastic SIP trunk
            | sip:<e164>@sip.voice.x.ai (TLS)
            v
   xAI Grok realtime  --POST /xai/incoming (HMAC)-->  cloudflared quick tunnel
                                                              |
  ========================== ~/projects/alfred ===============|================
   voice-tunnel  (cloudflared + watchdog: re-registers the xAI webhook URL)
            v
   voice-gateway :8790  ---- realtime WS (audio + tool calls) ---- xAI
            |  SELECT call card                | POST /v1/<verb> + caller_id
            v                                  v
        (Postgres)                     brain-actions :8791  --Bearer--> T3 Code
                                               |                       :3773
   todo-service :4821      web/ (static SPA)       android/ (APK downloads)
            ^                         |                        |
            |__ Caddy :6443 https://15.204.108.12:6443 --------+--------|
            |__ Caddy :7443 mirrors the same routes under /alfred/* -----|
            |     (PRIMARY: https://15.204.108.12:7443/alfred/ -- Dan's phone
            |      content filter allows :7443, not :6443)
                 /todo/* | /actions/* | /downloads/* | everything else -> web SPA
  ============================================================================
            |                                  |
            v                                  v
   second-brain  Postgres `second_brain` (pgvector) + HTTP :4820 + MCP `brain`
            ^                    ^                         ^
            |                    |                         |
  second-brain-callcards.timer  second-brain-ingest.timer  Claude Code SessionEnd
   (5 min: call cards)          (5 min: transcripts)        hook -> /api/ingest

   alive-ping.timer (5 min) -- curls the shim's aggregate /healthz -> journal

   Slack --> slackcc --> T3 Code :3773 --> Claude Code sessions in project repos
              (screened by pps :8642 -> llama-guard :8641)
```

## Components

### Alfred hub — `~/projects/alfred`

The voice surface **and** the integration hub. Monorepo, settled: the restructure
is done, so these paths are the paths (older docs and the unit *names* still say
`spike-a/` and "voice-", which is noted under FUTURE-WORK there and is cosmetic).

```
services/{gateway,brain-actions,lib,todo}   the four server pieces
web/                                        Vite + Preact SPA (desk surface)
android/                                    native Kotlin app (com.dgordon.alfred)
contracts/                                  fixtures + the grouping contract both clients assert against
caddy/                                      the :6443 site block + an idempotent installer
bin/                                        tunnel watchdog, xAI repointer, client CLI, pair links, alive-ping
systemd/                                    unit templates + install.sh
docs/                                       CADDY.md, COSTS.md, RESTORE.md, migrations/, research/
```

| Piece | Port | Unit | Purpose |
|---|---|---|---|
| `services/gateway` | 8790 (127.0.0.1) | `voice-gateway` | Verifies the xAI Direct-SIP webhook, opens the realtime WS, injects the precomputed call card + tool defs, proxies tool calls, writes transcripts + `call_sessions` |
| `bin/tunnel-watchdog.sh`, `bin/repoint-xai-webhook.sh` | — | `voice-tunnel` | cloudflared **quick** tunnel (URL rotates on every restart — never hard-code it) plus a watchdog that re-registers the new URL as the xAI webhook |
| `services/brain-actions` | 8791 (127.0.0.1) | `brain-actions` | The **only** holder of the T3 Code bearer token, and the app's front door. **Nine** function tools (see below), plus the inbox (`POST /v1/note`) and the notification feed (`GET /v1/briefings`). Enforces per-caller grants; watches T3 turns and writes `pending_briefings`. `/healthz` |
| `services/lib` | — | — | Shared modules: env, db pool, bearer auth |
| `services/todo` | 4821 (127.0.0.1) | `todo-service` | Owns second-brain's widened `todos` table. Node/`node:http`/`pg`. `GET/POST /v1/todos*`, the five to-do function tools at `GET /v1/tools` + `POST /v1/tools/:name`, one `gpt-5.6-luna` parse per capture. `/healthz` |
| `web/` | 7443/alfred (primary) + 6443 via Caddy | (static) | **LIVE** — desk surface, Vite + Preact SPA, built to `web/dist` and deployed to **`/var/lib/alfred-web`** by `web/scripts/deploy.sh`; Caddy serves it as the SPA fallback at both `https://15.204.108.12:7443/alfred/` (**primary** — Dan's phone content filter allows `:7443`, not `:6443`) and unchanged at `:6443` |
| `android/` | — | (no unit) | **LIVE** — native Kotlin app `com.dgordon.alfred` on **android-framework**, **v1.0.0 / versionCode 2**, debug-signed, published to `/var/lib/alfred-apk` and sideloaded from `…:7443/alfred/downloads/` (primary; `…:6443/downloads/` still live). Deploy rules: `~/.claude/android.md` ("Alfred") |

- **Outbound calls (PR pending, alfred #19).** `brain-actions/callbacks.mjs` owns
  scheduled calls ("call me tomorrow at 6"): a `scheduled_calls` table in
  `second_brain` (migration 006), a 10 s sweep, and **Twilio REST** (creds from
  `~/.profile`) ringing Dan's number then bridging `<Dial><Sip>` into
  `sip.voice.x.ai`, so xAI sees an ordinary inbound call; the gateway
  (`gateway/scheduled.mjs`) recognises the leg by From = Alfred's own number.
  Three owner-only tools bring the tool surface to **twelve**. Kill switch
  `ALFRED_CALLBACKS=off`. No new port or unit.

- **The tool surface is nine verbs (twelve with the call tools above), merged from two files.** The four T3 verbs
  (`summarize_recent`, `continue_chat`, `kick_off_task`, `new_project_and_chat`)
  are defined in `services/brain-actions/tools.json` and executed there; the five
  to-do tools (`todo_add`, `todo_list`, `todo_complete`, `todo_update`,
  `todo_find`) are defined in `services/todo/tools.json` and executed by
  todo-service. **Whoever defines a tool executes it**; the shim only forwards the
  to-do five, keeping the caller/grant check on its own side. Both
  `services/gateway/tools.mjs` (for the voice model) and brain-actions'
  `GET /v1/tools` (for the app) merge the same two files, so every surface sees an
  identical list. Add a tool by editing the owning `tools.json` — nothing else.

- **Data store:** none of its own — everything lives in second-brain's Postgres
  (`second_brain`): `callers`, `caller_identities`, `caller_project_grants`,
  `todos`, `summary_cache`, `call_sessions`, `pending_briefings`.
- **Own timer:** `alive-ping.timer` → `alive-ping.service` (oneshot,
  `bin/alive-ping.sh`), every 5 minutes against the shim's aggregate `/healthz`.
- **Call path:** phone `+1 224 300 7842` → Twilio Elastic SIP trunk →
  `sip.voice.x.ai` → xAI Grok realtime → webhook → gateway.
- **Talks to:** Postgres (direct SQL), brain-actions (loopback HTTP),
  and through brain-actions to T3 Code's orchestration API.
- **Public origin — PRIMARY `https://15.204.108.12:7443/alfred/`,** mirrored
  unchanged at `https://15.204.108.12:6443/`, both via **Caddy** (system unit
  `caddy.service`, config `/etc/caddy/Caddyfile`, restart with `systemctl
  restart caddy` — `reload` does not work, see "Caddy" below). Dan's phone
  content filter resets connections to any host:port he has not individually
  allowed; `:7443` is allowed and `:6443` is not, so the whole origin is
  mirrored inside the T3 Code `:7443` site under `/alfred/*`, between the
  `# --- BEGIN alfred-on-7443` / `# --- END alfred-on-7443 ---` markers in
  `/etc/caddy/Caddyfile` (managed by `~/projects/alfred/caddy/install.sh`,
  which also manages the top-level `# --- BEGIN alfred` `:6443` site). Both
  sites route the same way — `handle_path` strips the prefix (`/alfred` on
  `:7443`, none on `:6443`) so each service sees `/v1/…` + `/healthz` at its
  root: `/todo/*` → `todo-service` (127.0.0.1:4821), `/actions/*` →
  `brain-actions` (127.0.0.1:8791), `/downloads/*` → `file_server` on
  `/var/lib/alfred-apk` (the APKs + a generated install page), everything else
  → the static web app in `/var/lib/alfred-web` (SPA fallback). All routes are
  live on both origins. `/var/lib/alfred-web/p/` (short-lived pairing pages
  handed to a phone out of band) is a human-owned area inside that web root,
  excluded from `web/scripts/deploy.sh`'s `rsync --delete`. Anyone editing the
  `:7443` site (e.g. T3 redeploy tooling) must leave both markers intact and
  keep the Alfred handlers above that site's catch-all `handle`.
- **Pairing a device — one long-lived bearer token each, and three files to know:**
  - `bin/alfred-client.mjs issue --label <name> --caller <id>` mints the token and
    writes a row in the spine's **`api_clients`** table. The token is **shown once**
    and only its SHA-256 is stored, so it cannot be recovered — reissue instead.
    `bin/alfred-client.mjs list` / `revoke <id>`; a revoke takes effect within 60 s.
  - `bin/alfred-pair-link.mjs issue --label <name> --caller <id>` does the same and
    wraps it in a one-tap **`alfred://pair?base=…&token=…&t3=…&phone=…`** deep link,
    so the token is never typed. `link --token -` wraps a token that already exists;
    `--bare` prints just the link.
  - Alfred's own link lives at `~/projects/alfred/.pair-link.txt` (mode 600,
    gitignored). **The link is exactly as secret as the token** — hand it over on the
    device, never post it, never print either in a transcript or a Slack message.
  - `services/lib` verifies the bearer on every request except the `/healthz` probes.
- **Docs:** `README.md` (status + layout), `FUTURE-WORK.md`, `CLAUDE.md`,
  `android/README.md` (the app, its four test layers and the manual checklist),
  `web/README.md`, `docs/{CADDY.md,COSTS.md,RESTORE.md}`,
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
  of `project.create`, `thread.create`, `thread.turn.start`. The daily model scout
  (see "Claude config") also dispatches `thread.delete` / `project.delete` via
  `~/dotfiles/claude/bin/t3-purge-test-threads.sh`, only for imported test threads.
- **Also on the box:** `~/projects/meta/t3code` (older checkout) and the test
  pool units `t3-test-7446` / `t3-test-7448` (ports 3776/3778 HTTP, 7446/7448
  HTTPS). Don't point production traffic at those.

### Caddy — the shared public HTTPS front

This box has no domain name (Techloq filters new hostnames), so every public
surface is a bare-IP HTTPS site with one pinned self-signed cert. Not an Alfred
component, but Alfred's `:6443` origin is one of its sites, and Alfred is now
also mirrored **inside** the T3 Code `:7443` site under `/alfred/*` (Dan's
phone content filter allows `:7443`, not `:6443` — see "Public origin" under
"Alfred hub" above), so a Caddyfile edit for Alfred, or for T3 Code's `:7443`
site, can take down T3/DanCode/Abba Bank/Alfred if done wrong.

- **Unit:** **system** unit `caddy.service` (not `--user`), config
  `/etc/caddy/Caddyfile` (root-owned, needs `sudo`; passwordless `sudo -n`
  works for `dgordon`). `auto_https off`, `admin off`.
- **Restart, not reload:** `systemctl reload caddy` fails on this box (`admin
  off` breaks Caddy's reload API) — always `sudo -n systemctl restart caddy`
  after `sudo -n caddy validate --config /etc/caddy/Caddyfile`. A restart is
  sub-second but drops in-flight connections on **every** site.
- **Cert:** `/etc/caddy/dancode-server.crt`/`.key`, self-signed, `CN=`/SAN
  `15.204.108.12`, shared by all sites — the Android app ships it once as its
  trust anchor.
- **Sites:** DanCode `:8443`, Abba Bank `:9443`, T3 Code `:7443` — which now
  also carries Alfred's `/alfred/*` mirror between the `# --- BEGIN
  alfred-on-7443` / `# --- END alfred-on-7443 ---` markers, spliced above the
  site's catch-all `handle` and never touching the rest of the T3 block — T3
  test-deploy pool `:7444`-`:7453` (generated by
  `~/projects/meta/t3code/scripts/test-deploy-caddy.ts`, appended at the file's
  end — don't touch), Alfred `:6443` (its own top-level site, marked `# ---
  BEGIN alfred` / `# --- END alfred`, inserted above that generated section;
  see its route map under "Alfred hub" above). Both Alfred regions are managed
  idempotently by `~/projects/alfred/caddy/install.sh`.
- **Docs:** `~/projects/alfred/docs/CADDY.md` (Alfred's block in detail).

### slackcc — `~/projects/slack`

Bridges Slack threads to T3 Code sessions (a Slack thread == a T3 thread).

- **Unit:** `slackcc` (`Wants=pps.service`) → **pps** `:8642` (Prompt Protection
  Service) → **llama-guard** `:8641` (local Qwen3-4B judge). Non-owner messages
  are screened before they reach an agent.
- **Config:** `config/channels.json` maps a Slack channel → project, cwd,
  `t3_project_id`, model. The **alfred** channel maps to `~/projects/alfred` and
  T3 project `alfred`.
- **CLI:** `/home/dgordon/projects/slack/.venv/bin/{slack-send,slack-upload,slack-wait-reply}`.
- **Direction:** Slack is **retired as Alfred's notification path** — the Android
  app shipped (v1.0.0, 2026-09-16) and `pending_briefings` + local notifications
  are the channel now. Don't build new Alfred notification features on Slack.
  slackcc itself is unaffected; it still bridges Slack threads to T3 sessions.

### whatsapp-bot — `~/projects/whatsapp-bot`

WhatsApp automation; *(planned)* tap that ingests its conversations into
second-brain. No Alfred wiring yet.

### Claude config — `~/dotfiles/claude` (this repo)

Global `CLAUDE.md`, hooks, agents, skills, model-routing layer, and the reference
docs symlinked into `~/.claude/`: `android.md`, `model-selection.md`,
`model-usage.md`, `t3-conversations.md`, `playwright.md`, **`system-map.md`**
(this file). Its SessionEnd hook feeds second-brain; its SessionStart hooks print
the route-health, `[model-scout]` and `[alfred]` banners. See `README.md` there.

- **Daily model scout (user crontab, not systemd):** one line tagged
  `# claude-model-scout`, installed idempotently by `install.sh` (opt out:
  `MODEL_SCOUT_CRON=0`, remembered in `~/.claude/model-scout/cron-disabled`), runs `bin/model-scout.sh` at 11:30 UTC. It researches
  new model releases (grok via `bin/model-run.sh` — X + web search on the
  direct xAI API, `--task-type x-recency`, key `XAI_API_KEY` from `~/.profile`,
  which the cron line sources — + headless `claude -p` opus),
  updates the routing table/docs in its own worktree under
  `~/.cache/model-scout/`, and opens (or updates) ONE `claude/model-scout-*` PR
  against this repo's master — never pushes to master. State
  `~/.claude/model-scout/last-run.json` (read by the `[model-scout]` banner),
  logs `~/.claude/model-scout/logs/` (30 days), cron output
  `~/.claude/model-scout/cron.log`.
- **How it touches T3 Code:** only as cleanup. Its test chats are
  non-persisted/ephemeral; at the END of each run (up to ~90 min, so the
  15-min `t3-claude-import.timer` may already have imported a leaked
  transcript) `bin/test-chat-cleanup.sh` removes any Codex / Cursor / Claude
  session left in the run's throwaway workdirs, and
  `bin/t3-purge-test-threads.sh --apply` deletes any already-imported thread
  whose first message carries the run marker (plus the empty `/tmp` projects
  the importer made) through T3's orchestration dispatch (`thread.delete` /
  `project.delete`, with a short-lived session from T3's own CLI) — never SQL.
  If either fails (e.g. `t3code` down: purge exit 3) the run is marked failed
  and its marker/window is queued in `~/.claude/model-scout/pending-cleanup.tsv`,
  retried at the start of every later run's cleanup until it succeeds.

### android-framework — `~/projects/android-framework`

Native-Kotlin app framework + emulator/test layer; the canonical base for new
Android apps on this machine, and what **Alfred's Android app is built on** — it is
the framework's first adopter to reach a real phone. Deployment rules live in
`~/.claude/android.md` (see its "Alfred" section). The emulator layer is
machine-level: SDK at `~/Android/Sdk`, AVD `test35`, driven only through
`scripts/emu.sh` / `flow.sh`; adopting repos own no emulator tooling. One runner per
AVD — the cross-agent lock convention is `mkdir /tmp/alfred-emu.lock`.

## Ports & units at a glance

| Port | Bind | Owner |
|---|---|---|
| 3773 | 127.0.0.1 | T3 Code (`t3code`) — HTTPS front on 7443 |
| 3776 / 3778 | * | T3 test pool (`t3-test-7446` / `t3-test-7448`; HTTPS 7446/7448) |
| 4820 | 127.0.0.1 | second-brain HTTP API |
| 4821 | 127.0.0.1 | Alfred `todo-service` (`services/todo`), public via Caddy `/todo/*` |
| 5432 | 127.0.0.1 | Postgres (`second_brain`) |
| 6443 | — | Caddy — Alfred public origin (mirror) `https://15.204.108.12:6443`: `/todo/*`, `/actions/*`, `/downloads/*` (APKs) and the web SPA — **all live** |
| 7443 | — | Caddy — T3 Code public origin, **and Alfred's PRIMARY public origin** under `/alfred/*` (same three routes + web SPA; see "Public origin" under "Alfred hub") |
| 8443 | — | Caddy — DanCode public origin |
| 8641 | 127.0.0.1 | llama-guard (pps judge model) |
| 8642 | 127.0.0.1 | pps |
| 8790 | 127.0.0.1 | Alfred voice-gateway |
| 8791 | 127.0.0.1 | Alfred brain-actions, public via Caddy `/actions/*` |
| 9443 | — | Caddy — Abba Bank public origin |

Services (`systemctl --user`): `t3code`, `second-brain`, `slackcc`, `pps`,
`llama-guard`, `voice-gateway`, `voice-tunnel`, `brain-actions`,
`todo-service`, `t3-test-7446`, `t3-test-7448`.
Timers: `second-brain-ingest.timer`, `second-brain-callcards.timer`,
**`alive-ping.timer`** (Alfred's own, every 5 min: curls the shim's aggregate
`/healthz` and logs a journald WARNING when it is not ok — `bin/alive-ping.sh`
also pings `HEALTHCHECKS_URL` when that lands), `t3-claude-import.timer`.
Cron (user crontab): `# claude-model-scout` — daily 11:30 UTC
`~/dotfiles/claude/bin/model-scout.sh` (see "Claude config").
System (`sudo systemctl`, not `--user`): `caddy` — public HTTPS front for
`:6443`/`:7443`/`:8443`/`:9443`/`:7444`-`:7453` (see "Caddy" above); `restart`,
not `reload`.
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
