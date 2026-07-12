---
name: redeploy
description: Redeploy the self-hosted T3 Code prod server (15.204.108.12:7443) to the latest origin/main. Syncs the deploy checkout to an exact copy of origin/main, rebuilds, and restarts t3code.service via a detached unit. Use when the user says "/redeploy", "redeploy T3", or wants prod updated to main. Only runs on the T3 deploy host.
---

# Redeploy T3 Code (prod)

Redeploys the self-hosted T3 Code server to the current `origin/main`.

Everything is in `redeploy.sh` next to this file. Your job is to run it and report what
it prints.

## What the script does

1. `git fetch` the deploy checkout (`/home/dgordon/projects/meta/t3code-v2`) and hard
   checkout a **detached copy of `origin/main`** — no branches to reason about, the deploy
   dir is just a snapshot of `origin/main`. It also deletes the leftover `deploy` label if
   present.
2. `pnpm install` + `pnpm build`.
3. If the build succeeds, fires a **detached** `systemctl --user restart t3code.service`
   (as a transient systemd unit, so the restart completes even though this session dies)
   and writes a health report to `/tmp/t3-redeploy-status.log`.

## CRITICAL — this session will drop

This chat runs *inside* `t3code.service`. When the service restarts, **this chat's own
session disconnects.** That is expected and unavoidable — the deploy still completes in the
background. The user should reconnect and read the status log.

## How to run

```bash
bash ~/.claude/skills/redeploy/redeploy.sh
```

Then:

- **If the script aborts before the restart** (e.g. build failure): report the error and do
  NOT restart anything. Nothing was deployed; the old server is still running untouched.
- **If it reaches "Redeploy launched"**: tell the user the connection will blip in a couple
  seconds, and that after reconnecting they can verify with:
  ```bash
  cat /tmp/t3-redeploy-status.log
  ```
  A healthy result shows `service-active=active`, `loopback-3773=200`, `public-7443=200`,
  and `served-commit` matching the target.

Never restart `t3code.service` by any other means — always go through this script so the
restart is detached and survives the session drop.
