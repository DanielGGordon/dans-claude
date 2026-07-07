# Playwright Visual Testing Reference

How to visually test web apps with Playwright so an AI agent can *see* and judge the rendered UI, not just curl it.

## When to use

Only when the user asks — "test visually", "take a screenshot", "check how it looks", or mentions Playwright. Do **not** proactively add Playwright testing to tasks that didn't ask for it. When the user does ask, this file is the canonical method.

## The screenshot toolkit

A standalone toolkit lives at `~/projects/meta/visual-testing/` (playwright + chromium preinstalled under mise node@24). One line screenshots any URL:

```bash
/home/dgordon/.local/bin/mise exec node@24 -- node ~/projects/meta/visual-testing/screenshot.mjs <url> <out.png> [--full-page] [--width 1440] [--height 900] [--wait <ms>]
```

Then **Read the PNG** with the Read tool — it renders visually — and judge the result: layout, theme/colors, missing elements, error pages, unstyled HTML.

If the toolkit is missing on this machine, bootstrap it:

```bash
mkdir -p ~/projects/meta/visual-testing && cd ~/projects/meta/visual-testing
mise exec node@24 -- npm init -y && mise exec node@24 -- npm install playwright
mise exec node@24 -- npx playwright install chromium   # no sudo, no --with-deps
```

then copy `screenshot.mjs` from another machine or re-generate it (plain chromium launch → `page.goto(url, {waitUntil: 'networkidle', timeout: 30000})` → optional extra wait → `page.screenshot`).

## Interaction tests (beyond a single screenshot)

For click/type/navigate flows, write an ad-hoc `.mjs` script in the scratchpad importing playwright from the toolkit dir (`import { chromium } from '/home/dgordon/projects/meta/visual-testing/node_modules/playwright/index.mjs'`), drive the page (`page.click`, `page.fill`, `page.waitForSelector`), and screenshot after each meaningful step so every state can be visually evaluated.

## Gotchas

- **`networkidle` starvation:** apps that poll or stream constantly can hold `page.goto` past its 30s timeout. If that happens, use `waitUntil: 'load'` plus a fixed `--wait` instead.
- **Auth-gated apps:** a fresh browser context is logged out — the screenshot shows the login/pairing page. Script the auth step (or use a token URL) when you need to see the app itself.
- **Sandboxed subagents may lack network reach** (e.g. tailnet/VPN-only hosts). Run screenshots from the main session, or against `127.0.0.1`.
- **Node:** always go through `mise exec node@24` — system node may be too old.
- **Evaluation is the point:** never claim a UI works from exit code 0 alone; Read the screenshot and describe what is actually visible.
