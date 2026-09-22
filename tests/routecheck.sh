#!/usr/bin/env bash
# routecheck — live-verify every model route in bin/routes.tsv by invoking it
# through bin/model-run.sh (the same entrypoint agents use — the tested path IS
# the used path), plus zero-token guard and hook unit tests.
#
#   bash ~/dotfiles/claude/tests/routecheck.sh            # everything, parallel
#   bash ~/dotfiles/claude/tests/routecheck.sh --no-live  # free tiers only; does not update route-health.txt
#
# A route passes only if the model echoes a nonce back. ~100 tokens per route.
# Also runs bin/catalog-drift.sh (zero tokens): a routed id missing from its
# live catalog is a FAIL; a NEWER version of a routed family (e.g. grok-4.8
# when routes.tsv stops at 4.7) is a WARN — nothing is broken, but update routes.tsv.
# Writes ~/.claude/route-health.txt for the SessionStart banner hook
# (ROUTE_HEALTH_FILE / ROUTE_HEALTH_TOOLS override the paths).
# If a route FAILs, fix bin/routes.tsv / the docs or remove the model — never
# leave a documented route broken.
#
# Test-chat hygiene (2026-09-22: 97 Codex threads, 238 Cursor chats and several
# T3 Code threads had piled up from earlier runs): every live call runs with
# MODEL_RUN_EPHEMERAL=1 (codex --ephemeral), claude runs as `claude -p
# --no-session-persistence` inside $WORK (never the caller's cwd, which T3's
# importer would pick up), every prompt carries a per-run marker, and
# bin/test-chat-cleanup.sh removes whatever the CLIs still persisted (Cursor has
# no ephemeral mode) — explicitly before the verdict, and again from the EXIT
# trap if the run dies early. A caller (the daily model scout) can share its own
# marker via ROUTECHECK_MARKER=<string>.
#
# The xai backend (direct xAI API, e.g. grok-4.7-xsearch / --task-type x-recency)
# needs XAI_API_KEY. It is looked up exactly the way the scout's cron line gets
# it — the environment, else what `. ~/.profile` exports (model-run.sh does the
# same lookup itself). No key anywhere = those routes are SKIPPED with a WARN,
# not a FAIL; a key that is present but rejected is a FAIL. Its live smoke is
# NOT a nonce echo: grok-4.7 on the xAI API refuses "output exactly this
# token" requests (2026-09-22: 6 of 7 attempts refused, e.g. "I won't output
# exact phrases or tokens on demand"), so it asks for the sum of two per-run
# random numbers instead — same proof that THIS prompt was processed. It tells
# grok not to search (~$0.006); xAI keeps nothing (`store: false`), so there is
# no chat to clean up.
# ROUTECHECK_XAI_SOFT=1 turns the xai route's failures (auth:xai and its live
# smoke) into WARNs. Only the model scout's publish gate sets it: a rejected /
# out-of-credit / rate-limited XAI_API_KEY is an account problem, not a defect
# in the tree under review, and must not stop verified routing edits from
# being published (the scout records such a run "degraded" instead).
set -u

# Resolve the repo from this script's location (not ~/dotfiles/claude) so a
# worktree/branch checkout tests ITS copy of the routing layer, not master's.
DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
RUN="$DIR/bin/model-run.sh"
DRIFT="$DIR/bin/catalog-drift.sh"
FINGERPRINT="$DIR/bin/cli-fingerprint.sh"
TABLE="$DIR/bin/routes.tsv"
GUARD="$DIR/hooks/route-guard.sh"
AGENT_MD="$DIR/agents/model-runner.md"
CLEANUP="$DIR/bin/test-chat-cleanup.sh"
NONCE="ROUTE-OK-$RANDOM$RANDOM"
RUN_START=$(date +%s)
MARKER="${ROUTECHECK_MARKER:-ROUTECHECK-$(date +%Y%m%d)-$RANDOM$RANDOM}"
export MODEL_RUN_EPHEMERAL=1
WORK=$(mktemp -d /tmp/routecheck.XXXXXX)
OUT="$WORK/out"; mkdir -p "$OUT"
git -C "$WORK" init -q 2>/dev/null || true
PROMPTFILE="$WORK/prompt.md"
printf 'Output exactly this line and nothing else: %s\n\n[test-run marker: %s]\n' "$NONCE" "$MARKER" > "$PROMPTFILE"
# xai routes: an arithmetic "nonce" (see header) and no web/X searches.
XAI_A=$((RANDOM * 7 + 1000)); XAI_B=$((RANDOM * 3 + 1000)); XAI_SUM=$((XAI_A + XAI_B))
XAI_PROMPTFILE="$WORK/prompt-xai.md"
printf 'Quick arithmetic check, no search needed: what is %s + %s? Reply with just the number.\n\n[test-run marker: %s]\n' "$XAI_A" "$XAI_B" "$MARKER" > "$XAI_PROMPTFILE"
# XAI_API_KEY available? The env, else ~/.profile, like cron's `. ~/.profile`.
# Only a yes/no leaves the subshell — the key itself is never captured here.
XAI_KEY_SRC=""
if [ -n "${XAI_API_KEY:-}" ]; then XAI_KEY_SRC="env"
elif [ "$(bash -c '. "$HOME/.profile" >/dev/null 2>&1 </dev/null; printf %s "${XAI_API_KEY:+1}"' 2>/dev/null)" = 1 ]; then XAI_KEY_SRC="~/.profile"
fi
# Every dir a live smoke runs in — cleanup matches chats by exact cwd.
TEST_WORKDIRS=("$WORK" "$WORK/artifact-codex" "$WORK/artifact-cursor")
CHATS_CLEANED=0
clean_chats() { # runs at most once; prints test-chat-cleanup's lines + summary
  [ "$CHATS_CLEANED" = 1 ] && return 0; CHATS_CLEANED=1
  local wd=() w
  for w in "${TEST_WORKDIRS[@]}"; do wd+=(--workdir "$w"); done
  bash "$CLEANUP" --since "$RUN_START" --marker "$MARKER" "${wd[@]}" 2>&1
}
# Interrupted mid-Tier-2: stop EVERY smoke process before sweeping, or a CLI
# still running writes its chat after the sweep. `kill $(jobs -p)` alone only
# hit the subshells: model-run's inner `timeout` makes its own process group
# and, once its parent dies, is reparented out of our tree with codex /
# cursor-agent still running (review finding 2026-09-22). Every live prompt
# carries this run's unique NONCE in argv, so `pgrep -f` finds them wherever
# they were reparented to; TERM, wait up to 10s, then KILL.
stop_smokes() {
  local pids alive p i
  pids=$( { jobs -p; pgrep -f -- "$NONCE"; } 2>/dev/null | grep -vx "$$" | sort -u)
  [ -n "$pids" ] || return 0
  kill -TERM $pids 2>/dev/null
  for i in $(seq 1 20); do
    alive=""; for p in $pids; do kill -0 "$p" 2>/dev/null && alive+=" $p"; done
    [ -z "$alive" ] && return 0
    sleep 0.5
  done
  kill -KILL $alive 2>/dev/null
  sleep 0.5
}
on_exit() {
  local st=$?
  stop_smokes
  clean_chats | grep -v 'deleted cursor=0 codex=0 claude=0$' | sed 's/^/CLEANUP  /'
  rm -rf "$WORK"
  exit "$st"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP
# ROUTE_HEALTH_FILE / ROUTE_HEALTH_TOOLS redirect the result files: the model
# scout checks UNDEPLOYED trees (its worktree), whose verdict must not become
# the live banner's.
HEALTH="${ROUTE_HEALTH_FILE:-$HOME/.claude/route-health.txt}"
TOOLS="${ROUTE_HEALTH_TOOLS:-$HOME/.claude/route-health-tools.txt}"   # CLI versions this run verified against (SessionStart banner diffs them)
TODAY=$(date +%F)
declare -a FAILURES=()
declare -a WARNINGS=()

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1${2:+ — $2}"; FAILURES+=("$1"); }
warn() { echo "WARN  $1${2:+ — $2}"; WARNINGS+=("$1"); }   # advisory: never fails the suite
# xai-route failures: FAIL, or WARN under ROUTECHECK_XAI_SOFT=1 (see header)
xbad() { if [ "${ROUTECHECK_XAI_SOFT:-0}" = 1 ]; then warn "$1" "${2:+$2 }(soft: ROUTECHECK_XAI_SOFT=1)"; else bad "$@"; fi; }

# ---------- Tier 0: hook unit tests (free) ----------
guard() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | bash "$GUARD"; }
expect_deny()  { guard "$1" | grep -q '"deny"' && ok "guard-deny: $2" || bad "guard-deny: $2" "was allowed"; }
expect_allow() { [ -z "$(guard "$1")" ] && ok "guard-allow: $2" || bad "guard-allow: $2" "was denied"; }
expect_deny  'codex exec --dangerously-bypass-approvals-and-sandbox -C /tmp "hi"' "raw codex exec"
expect_deny  'cursor-agent --print --trust --model composer-2.5 "hi"' "raw headless cursor"
expect_deny  'true model-run.sh; codex exec -C /tmp "hi"' "chained bypass (regression)"
expect_deny  'MODEL_RUN_TIMEOUT=60 codex exec -C /tmp "hi"' "env-prefixed codex"
expect_deny  'cursor-agent --model grok-4.5-xhigh --print "hi"' "retired id"
expect_deny  'bash -c "codex exec -C /tmp hi"' "bash -c smuggling"
expect_allow 'git commit -m "quotes chained: true model-run.sh; codex exec -C /tmp hi"' "prose in quotes (regression)"
expect_allow 'cursor-agent status' "cursor status"
expect_allow 'cursor-agent --list-models' "list-models"
expect_allow 'codex login status' "codex login status"
expect_allow 'codex debug models' "codex debug models (catalog read)"
expect_allow "bash $DRIFT --cached" "catalog-drift.sh call"
expect_allow "bash $RUN gpt-5.6-terra /tmp/p.md" "model-run.sh call"
expect_allow "bash $CLEANUP --since 1 --marker ROUTECHECK-x1 --workdir /tmp/routecheck.x" "test-chat-cleanup.sh call"
expect_allow 'codex delete --force 01a0caf4-1d77-7590-910e-c3b8e692f185' "codex delete (test-chat cleanup)"
expect_allow "grep 'codex exec' $RUN" "grep mentioning codex exec"
expect_allow 'ls -la && git status' "unrelated command"
expect_deny  'curl -s https://api.x.ai/v1/responses -H "Authorization: Bearer $XAI_API_KEY" -d @req.json' "raw xAI responses call"
expect_deny  'X=1 curl -s "https://api.x.ai/v1/chat/completions" -d @r.json' "raw xAI chat call (quoted url)"
expect_allow 'curl -s https://api.x.ai/v1/models -H @h.txt' "xAI catalog read (GET /v1/models)"
expect_allow 'curl -s https://example.com/v1/responses' "curl to another host"
expect_allow "grep -n 'api.x.ai/v1/responses' $RUN" "grep mentioning the xAI endpoint"
expect_allow "curl -s https://example.com/health && grep -n 'api.x.ai/v1/responses' $RUN" "curl + unrelated grep of the xAI endpoint (regression)"
expect_deny  $'curl -s \\\n  "https://api.x.ai/v1/responses" -d @r.json' "raw xAI call across a line continuation"
expect_deny  'R=$(curl -s -d @r.json "https://api.x.ai/v1/responses"; echo) && echo "$R"' "raw xAI call in \$( )"
# model-runner agent contract lints (free). Regression for 2026-08-24: the agent
# was told to Write inline prompts to the literal path /tmp/model-run-$$.md —
# the Write tool does not expand $$, so parallel runners in a workflow fan-out
# shared ONE prompt file and one runner returned another runner's answer.
grep -qF 'mktemp' "$AGENT_MD" && ! grep -qE '(Write|write) (it )?to `/tmp/model-run-\$\$' "$AGENT_MD" \
  && ok "agent-contract:unique-temp-prompt-file" || bad "agent-contract:unique-temp-prompt-file" "model-runner.md must get the prompt path from mktemp, never a literal \$\$ path"
grep -q -- '--task-type <type> -> <model-id>' "$AGENT_MD" && ok "agent-contract:reports-resolved-id" || bad "agent-contract:reports-resolved-id" "model-runner.md must use the resolved id from model-run's stderr in its MODEL: line"

# ---------- Tier 0.5: mock-backend tests of model-run.sh error taxonomy ----------
# PATH-shimmed fake codex/cursor-agent binaries — deterministic, zero tokens,
# no network. This is the fake-injection seam: failure modes (auth, transport,
# retry, prose false-positives) are provable without a live outage.
MOCKBIN="$WORK/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/codex" <<'MOCK'
#!/usr/bin/env bash
# Catalog reads (used by the catalog-drift unit tests): a fake future catalog —
# grok 4.8 / gpt-7-nova exist, cursor-grok-4.5-low is gone. gpt-6-astra is
# present (so a routed id is NOT reported vanished); gpt-5.7-sol is included
# deliberately and must NOT be "newer" — routed gpt-6 outranks 5.7 under the
# detector's family-max semantics — but MUST be "unrouted" (that finding closes
# the gap: a gpt-5.x point release or a new gpt-6 tier is still surfaced). auto,
# grok-4.8-* and gpt-7-nova are the other unrouted ids. All grok-4.7-* ids
# actually routed in routes.tsv are included so they are NOT reported vanished
# — grok-4.8 is the hypothetical next bump used to exercise "newer".
# MOCK_MODE=catalog-down simulates a logged-out/broken CLI for the fail-open test.
[ "${MOCK_MODE:-ok}" = catalog-down ] && { echo "Not logged in"; exit 1; }
if [ "${1:-}" = "--list-models" ]; then
  printf 'Available models\n\nauto - Auto (default)\n'
  for id in grok-4.8-high grok-4.8-xhigh grok-4.7-high grok-4.7-high-fast grok-4.7-xhigh grok-4.7-medium grok-4.7-low \
            cursor-grok-4.6-high cursor-grok-4.6-high-fast \
            cursor-grok-4.6-xhigh cursor-grok-4.6-medium cursor-grok-4.6-low cursor-grok-4.5-high \
            cursor-grok-4.5-high-fast cursor-grok-4.5-medium composer-2.5 composer-2.5-fast glm-5.2-high glm-5.2-max; do
    echo "$id - Mock"; done; exit 0
fi
if [ "${1:-}" = "debug" ]; then
  echo '{"models":[{"slug":"gpt-7-nova","visibility":"list"},{"slug":"gpt-6-astra","visibility":"list"},{"slug":"gpt-5.7-sol","visibility":"list"},{"slug":"gpt-5.6-sol","visibility":"list"},{"slug":"gpt-5.6-terra","visibility":"list"},{"slug":"gpt-5.6-luna","visibility":"list"},{"slug":"gpt-5.5","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}'; exit 0
fi
printf '%s\n' "$*" > "${MOCK_ARGS:-/dev/null}"
case "${MOCK_MODE:-ok}" in
  ok)        echo "mock response OK"; exit 0 ;;
  auth)      echo "Error: authentication required — run codex login"; exit 1 ;;
  transport) echo "error sending request: connection reset by peer"; exit 1 ;;
  flaky)     if [ -f "$MOCK_STATE" ]; then echo "mock response OK after retry"; exit 0
             else touch "$MOCK_STATE"; echo "error: connection reset by peer"; exit 1; fi ;;
  quote-ok)  echo "this task discusses rate limit exceeded and authentication required"; exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/codex"; cp "$MOCKBIN/codex" "$MOCKBIN/cursor-agent"
# Fake curl for the xai backend: -o gets the body, stdout gets -w's
# "<http code> <time_connect>", like the real one (time_connect 0 = the TCP
# connect never completed). Records the request body, the Authorization header it was
# handed (via -H @fd) and its argv to MOCK_ARGS. MOCK_XAI_CATALOG = the model
# ids GET /v1/models returns.
cat > "$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env bash
argv="$*"; out=/dev/stdout; url=""; data=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -H) case "$2" in @*) auth=$(cat "${2#@}");; esac; shift 2 ;;
    -w|-m|--connect-timeout) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "${MOCK_ARGS:-}" ]; then
  { echo "URL $url"; echo "AUTH $auth"; echo "ARGV $argv"; [ -n "$data" ] && cat "$data"; echo; } > "$MOCK_ARGS"
fi
reply() { printf '%s' "$2" > "$out"; printf '%s 0.012000' "$1"; exit 0; }
[ "${MOCK_MODE:-ok}" = catalog-down ] && reply 401 '{"code":"unauthenticated","error":"mock"}'
case "$url" in */models)
  case "${MOCK_MODE:-ok}" in
    ratelimit) reply 429 '{"code":"resource-exhausted","error":"Too many requests, slow down"}' ;;
    quota)     reply 429 '{"code":"resource-exhausted","error":"Your team has used all available credits"}' ;;
    connect-timeout) echo "curl: (28) Connection timed out after 20001 milliseconds" >&2; printf '000 0.000000'; exit 28 ;;
  esac
  ids=""; for i in ${MOCK_XAI_CATALOG:-grok-4.6 grok-4.7 grok-4.20-0309-reasoning}; do ids+="${ids:+,}{\"id\":\"$i\"}"; done
  reply 200 "{\"data\":[$ids]}" ;;
esac
ok_body() { printf '{"status":"completed","store":false,"output":[{"type":"custom_tool_call","name":"x_keyword_search"},{"type":"message","content":[{"type":"output_text","text":"%s","annotations":[{"type":"url_citation","url":"https://x.com/i/status/123"}]}]}],"usage":{"cost_in_usd_ticks":1000000000,"server_side_tool_usage_details":{"x_search_calls":2,"web_search_calls":1,"x_posts_fetched":7}}}' "$1"; }
case "${MOCK_MODE:-ok}" in
  ok)        reply 200 "$(ok_body 'mock response OK')" ;;
  auth)      reply 400 '{"code":"invalid-argument","error":"Incorrect API key provided."}' ;;
  quota)     reply 429 '{"code":"resource-exhausted","error":"credits exhausted"}' ;;
  transport) echo "curl: (7) Failed to connect" >&2; printf '000 0.000000'; exit 7 ;;
  flaky)     if [ -f "$MOCK_STATE" ]; then reply 200 "$(ok_body 'mock response OK after retry')"
             else touch "$MOCK_STATE"; reply 503 'upstream unavailable'; fi ;;
  quote-ok)  reply 200 "$(ok_body 'this task discusses Incorrect API key and rate limit exceeded')" ;;
  timeout)   echo "curl: (28) Operation timed out" >&2; printf '000 0.042000'; exit 28 ;;
  connect-timeout) echo "curl: (28) Connection timed out after 20001 milliseconds" >&2; printf '000 0.000000'; exit 28 ;;
esac
MOCK
chmod +x "$MOCKBIN/curl"
mock_run() { # $1 MOCK_MODE, $2 model id
  MOCK_MODE="$1" MOCK_STATE="$WORK/mockstate-$1-$2" MODEL_RUN_RETRY_DELAY=0 XAI_API_KEY=mock-key \
    PATH="$MOCKBIN:$PATH" "$RUN" "$2" "$PROMPTFILE" "$WORK" >/dev/null 2>&1; echo $?
}
[ "$(mock_run ok gpt-5.6-terra)" = 0 ]         && ok "mock:success-passthrough" || bad "mock:success-passthrough"
[ "$(mock_run auth gpt-5.6-terra)" = 75 ]      && ok "mock:auth->75" || bad "mock:auth->75"
[ "$(mock_run auth composer-2.5)" = 75 ]       && ok "mock:auth->75(cursor)" || bad "mock:auth->75(cursor)"
[ "$(mock_run transport gpt-5.6-terra)" = 73 ] && ok "mock:transport->73-after-retry" || bad "mock:transport->73-after-retry"
[ "$(mock_run flaky gpt-5.6-terra)" = 0 ]      && ok "mock:transient-retry-recovers" || bad "mock:transient-retry-recovers"
[ "$(mock_run quote-ok gpt-5.6-terra)" = 0 ]   && ok "mock:prose-quote-no-false-positive" || bad "mock:prose-quote-no-false-positive"
# xai backend (direct xAI API via curl): same exit contract, driven by HTTP status.
XID=$(awk -F'\t' '$1=="model" && $3=="xai" {print $2; exit}' "$TABLE")
if [ -n "$XID" ]; then
  XAPI=$(awk -F'\t' -v k="$XID" '$1=="model" && $2==k {print $4; exit}' "$TABLE")
  for pair in ok:0 auth:75 quota:75 transport:73 flaky:0 quote-ok:0 timeout:124 connect-timeout:73; do
    mode="${pair%%:*}" want="${pair##*:}"
    got=$(mock_run "$mode" "$XID")
    [ "$got" = "$want" ] && ok "mock:xai-$mode->$want" || bad "mock:xai-$mode->$want" "got exit $got"
  done
  st=$(env -u XAI_API_KEY MODEL_RUN_XAI_ENV_FILE=/dev/null PATH="$MOCKBIN:$PATH" "$RUN" "$XID" "$PROMPTFILE" "$WORK" 2>&1 >/dev/null; echo "exit=$?")
  grep -q 'XAI_API_KEY not set' <<<"$st" && grep -q 'exit=75' <<<"$st" \
    && ok "mock:xai-no-key->75" || bad "mock:xai-no-key->75" "$(tr '\n' '|' <<<"$st")"
  # --xai-models (the zero-token catalog read behind auth:xai): only a verdict
  # about the key/credits is 75 — a plain 429 rate limit is transient (73).
  for pair in ok:0 catalog-down:75 quota:75 ratelimit:73 connect-timeout:73; do
    mode="${pair%%:*}" want="${pair##*:}"
    got=$(MOCK_MODE="$mode" XAI_API_KEY=mock-key PATH="$MOCKBIN:$PATH" "$RUN" --xai-models >/dev/null 2>&1; echo $?)
    [ "$got" = "$want" ] && ok "mock:xai-models-$mode->$want" || bad "mock:xai-models-$mode->$want" "got exit $got"
  done
  # Request shape + key hygiene + output contract, in one call.
  MOCK_MODE=ok MOCK_ARGS="$WORK/args-xai.txt" XAI_API_KEY=mock-key MODEL_RUN_XSEARCH_FROM=2026-09-01 PATH="$MOCKBIN:$PATH" \
    "$RUN" "$XID" "$PROMPTFILE" "$WORK" >"$WORK/xai-out.txt" 2>"$WORK/xai-err.txt"
  xreq=$(python3 - "$WORK/args-xai.txt" "$XAPI" "$NONCE" <<'PY'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
req = json.loads(next(l for l in lines if l.startswith("{")))
tools = {t["type"]: t for t in req.get("tools", [])}
checks = {"model": req.get("model") == sys.argv[2], "store:false": req.get("store") is False,
          "web_search": "web_search" in tools, "x_search": "x_search" in tools,
          "from_date": tools.get("x_search", {}).get("from_date") == "2026-09-01",
          "prompt": sys.argv[3] in json.dumps(req.get("input")),
          "endpoint": any(l == "URL https://api.x.ai/v1/responses" for l in lines),
          "auth-header": "AUTH Authorization: Bearer mock-key" in lines,
          "key-not-in-argv": not any(l.startswith("ARGV") and "mock-key" in l for l in lines)}
print(" ".join(k for k, v in checks.items() if not v))
PY
)
  [ -z "$xreq" ] && ok "mock:xai-request(store:false,web+x_search,from_date,key-off-argv)" || bad "mock:xai-request" "failed: $xreq"
  grep -q 'mock response OK' "$WORK/xai-out.txt" && grep -q '^- https://x.com/i/status/123$' "$WORK/xai-out.txt" \
    && grep -q '^model-run: xai-tools x_search=2 web_search=1 ' "$WORK/xai-err.txt" \
    && ok "mock:xai-output(text+sources, tool-count line)" \
    || bad "mock:xai-output" "out: $(tr '\n' '|' <"$WORK/xai-out.txt" | head -c 200) err: $(tr '\n' '|' <"$WORK/xai-err.txt" | head -c 200)"
fi
# reasoning effort (routes.tsv 4th column / MODEL_RUN_EFFORT) must reach the codex
# CLI as -c model_reasoning_effort, and must never be passed to cursor.
mock_args() { # $1 outfile, $2 model id; extra env in $3.. as KEY=VAL
  local out="$1" model="$2"; shift 2
  env "$@" MOCK_MODE=ok MOCK_ARGS="$out" MODEL_RUN_RETRY_DELAY=0 PATH="$MOCKBIN:$PATH" \
    "$RUN" "$model" "$PROMPTFILE" "$WORK" >/dev/null 2>&1
}
mock_args "$WORK/args-astra.txt" gpt-6-astra
grep -q 'model_reasoning_effort="high"' "$WORK/args-astra.txt" \
  && ok "mock:effort-from-table(gpt-6-astra=high)" \
  || bad "mock:effort-from-table(gpt-6-astra=high)" "codex argv: $(cat "$WORK/args-astra.txt" 2>/dev/null)"
mock_args "$WORK/args-astra-env.txt" gpt-6-astra MODEL_RUN_EFFORT=xhigh
grep -q 'model_reasoning_effort="xhigh"' "$WORK/args-astra-env.txt" \
  && ok "mock:effort-env-override" \
  || bad "mock:effort-env-override" "codex argv: $(cat "$WORK/args-astra-env.txt" 2>/dev/null)"
mock_args "$WORK/args-terra.txt" gpt-5.6-terra
grep -q 'model_reasoning_effort' "$WORK/args-terra.txt" \
  && bad "mock:no-effort-when-table-blank" "unpinned model got an effort flag" \
  || ok "mock:no-effort-when-table-blank"
mock_args "$WORK/args-cursor.txt" composer-2.5 MODEL_RUN_EFFORT=high
grep -q 'model_reasoning_effort' "$WORK/args-cursor.txt" \
  && bad "mock:effort-not-passed-to-cursor" "cursor got a codex-only flag" \
  || ok "mock:effort-not-passed-to-cursor"
# MODEL_RUN_EPHEMERAL=1 (exported above for this whole run) -> codex --ephemeral;
# unset/0 -> normal persisted delegation; never a flag for cursor.
grep -q -- '--ephemeral' "$WORK/args-terra.txt" \
  && ok "mock:ephemeral-reaches-codex" || bad "mock:ephemeral-reaches-codex" "codex argv: $(cat "$WORK/args-terra.txt" 2>/dev/null)"
mock_args "$WORK/args-terra-persist.txt" gpt-5.6-terra MODEL_RUN_EPHEMERAL=0
grep -q -- '--ephemeral' "$WORK/args-terra-persist.txt" \
  && bad "mock:no-ephemeral-by-default" "MODEL_RUN_EPHEMERAL=0 still got --ephemeral" || ok "mock:no-ephemeral-by-default"
grep -q -- '--ephemeral' "$WORK/args-cursor.txt" \
  && bad "mock:ephemeral-not-passed-to-cursor" "cursor got a codex-only flag" || ok "mock:ephemeral-not-passed-to-cursor"

# catalog-drift detector against the fake future catalog above (zero tokens, no network)
mock_drift=$(XAI_API_KEY=mock-key CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1); mock_drift_st=$?
mock_nv=$(grep $'^newer\t\|^vanished\t' <<<"$mock_drift")
[ "$mock_drift_st" = 1 ] \
  && grep -q $'^newer\t.*grok-4.8-\*.*stops at grok-4.7' <<<"$mock_nv" \
  && grep -q $'^newer\t.*gpt-7-\*.*stops at gpt-6' <<<"$mock_nv" \
  && grep -q $'^vanished\t.*cursor-grok-4.5-low' <<<"$mock_nv" \
  && ! grep -q 'gpt-5.7' <<<"$mock_nv" \
  && ! grep -q $'^vanished\t.*gpt-6-astra' <<<"$mock_nv" \
  && ! grep -q 'glm\|composer\|xAI' <<<"$mock_nv" \
  && ok "mock:catalog-drift-detects-newer+vanished" \
  || bad "mock:catalog-drift-detects-newer+vanished" "exit $mock_drift_st: $(printf '%s' "$mock_drift" | tr '\n' '|')"
# unrouted: ids no model/retired/ignore row accounts for. gpt-5.7-sol is exactly
# the tier-at-an-old-version case version-max can't see; auto has no version.
grep -q $'^unrouted\tCodex catalog has 2 unrouted ids: gpt-5.7-sol, gpt-7-nova' <<<"$mock_drift" \
  && grep -q $'^unrouted\tCursor catalog has 3 unrouted ids: .*auto.*grok-4.8-high' <<<"$mock_drift" \
  && ok "mock:catalog-drift-unrouted-summary" \
  || bad "mock:catalog-drift-unrouted-summary" "$(grep unrouted <<<"$mock_drift" | tr '\n' '|')"
mock_unr=$(XAI_API_KEY=mock-key CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache" PATH="$MOCKBIN:$PATH" bash "$DRIFT" --unrouted 2>/dev/null); mock_unr_st=$?
[ "$mock_unr_st" = 1 ] \
  && [ "$(sort <<<"$mock_unr" | tr '\n' ' ')" = "$(printf 'codex\tgpt-5.7-sol\ncodex\tgpt-7-nova\ncursor\tauto\ncursor\tgrok-4.8-high\ncursor\tgrok-4.8-xhigh\n' | sort | tr '\n' ' ')" ] \
  && ok "mock:catalog-drift--unrouted-lists-ids" \
  || bad "mock:catalog-drift--unrouted-lists-ids" "exit $mock_unr_st: $(tr '\n' '|' <<<"$mock_unr")"
# ignore rows: bare glob matches any backend; "<backend>:<glob>" only that one
# (cursor:gpt-7-* must NOT hide Codex's gpt-7-nova). Needs its own routes.tsv,
# so run a copy of the detector next to a patched table.
IGN="$WORK/ignore-repo/bin"; mkdir -p "$IGN"; cp "$DRIFT" "$RUN" "$IGN/"
{ cat "$TABLE"; printf 'ignore\tauto\tCursor meta-router, not a model\nignore\tcursor:grok-4.8-*\tmock: seen, not yet routed\nignore\tcursor:gpt-7-*\tmock: wrong-backend scope\n'; } > "$IGN/routes.tsv"
mock_ign=$(XAI_API_KEY=mock-key CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache" PATH="$MOCKBIN:$PATH" bash "$IGN/catalog-drift.sh" --unrouted 2>/dev/null)
[ "$(sort <<<"$mock_ign" | tr '\n' ' ')" = "$(printf 'codex\tgpt-5.7-sol\ncodex\tgpt-7-nova\n' | tr '\n' ' ')" ] \
  && ok "mock:catalog-drift-ignore-rows(+backend-scope)" \
  || bad "mock:catalog-drift-ignore-rows(+backend-scope)" "$(tr '\n' '|' <<<"$mock_ign")"
mock_nodrift=$(MOCK_MODE=catalog-down XAI_API_KEY=mock-key CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache2" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1); mock_nodrift_st=$?
[ "$mock_nodrift_st" = 2 ] && grep -q $'^unavailable\t' <<<"$mock_nodrift" && ! grep -q $'^newer\|^vanished' <<<"$mock_nodrift" \
  && ok "mock:catalog-drift-fail-open-when-catalogs-down" \
  || bad "mock:catalog-drift-fail-open-when-catalogs-down" "exit $mock_nodrift_st: $(printf '%s' "$mock_nodrift" | tr '\n' '|')"
# xai catalog: vanished-only, by the API model id (column 4); no key = skipped silently.
if [ -n "$XID" ]; then
  mock_xv=$(MOCK_XAI_CATALOG="grok-4.6 grok-9.9" XAI_API_KEY=mock-key CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache3" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1)
  mock_xn=$(env -u XAI_API_KEY MODEL_RUN_XAI_ENV_FILE=/dev/null CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache4" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1)
  grep -q $'^vanished\t'"routes.tsv id $XID (xAI API model $XAPI) is gone from the xAI catalog" <<<"$mock_xv" \
    && ! grep -q 'grok-9.9\|grok-4.6' <<<"$mock_xv" && ! grep -qi 'xai' <<<"$mock_xn" \
    && ok "mock:catalog-drift-xai(vanished-by-api-id, no-key-silent)" \
    || bad "mock:catalog-drift-xai" "with key: $(grep -i xai <<<"$mock_xv" | tr '\n' '|') / no key: $(grep -i xai <<<"$mock_xn" | tr '\n' '|')"
fi

# test-chat-cleanup against a FAKE home (TEST_CHAT_CLEANUP_HOME): records that
# match (created >= since AND (cwd == a workdir OR marker in the FIRST user
# message)) must go; look-alikes that fail either half must survive. Mock codex
# has no `delete` subcommand, so this also covers the rollout-file fallback.
FH="$WORK/fakehome"; FW="$WORK/fake-workdir"; FM="MOCKMARK-$RANDOM$RANDOM"
python3 - "$FH" "$FW" "$FM" "$RUN_START" <<'PYEOF'
import hashlib, json, os, re, sys, time
from datetime import datetime, timezone
fh, fw, fm, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
iso = lambda t: datetime.fromtimestamp(t, timezone.utc).isoformat().replace("+00:00", "Z")
now, old = start + 5, start - 3600
def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True); open(path, "w").write(text)
def cursor_chat(cid, cwd, created, first_user):
    w(f"{fh}/.cursor/chats/{hashlib.md5(cwd.encode()).hexdigest()}/{cid}/meta.json", json.dumps({"cwd": cwd, "createdAtMs": created * 1000}))
    slug = re.sub(r"[^A-Za-z0-9]+", "-", cwd).strip("-")
    w(f"{fh}/.cursor/projects/{slug}/agent-transcripts/{cid}/{cid}.jsonl", json.dumps({"role": "user", "message": {"content": [{"type": "text", "text": first_user}]}}) + "\n")
    w(f"{fh}/.cursor/projects/{slug}/.workspace-trusted", json.dumps({"workspacePath": cwd}))
cursor_chat("c-wd-new", fw, now, "hi")                       # DELETE (cwd)
cursor_chat("c-wd-old", "/x/older-wd", old, fm)              # keep (too old)
cursor_chat("c-mark", "/x/other", now, f"say {fm}")          # DELETE (marker)
cursor_chat("c-plain", "/x/other", now, "unrelated")         # keep
def rollout(name, cwd, created, user):
    w(f"{fh}/.codex/sessions/2026/01/01/rollout-{name}.jsonl",
      json.dumps({"type": "session_meta", "timestamp": iso(created), "payload": {"id": name, "timestamp": iso(created), "cwd": cwd}}) + "\n"
      + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": user}]}}) + "\n")
rollout("x-wd", fw, now, "hi")                               # DELETE (cwd)
rollout("x-mark", "/x/other", now, fm)                       # DELETE (marker)
rollout("x-plain", "/x/other", now, "unrelated")             # keep
rollout("x-old", fw, old, fm)                                # keep (too old, though mtime is new)
def transcript(sid, created, lines):
    body = "".join(json.dumps({"type": "user", "timestamp": iso(created), "cwd": "/x/other", "message": {"role": "user", "content": t}}) + "\n" for t in lines)
    w(f"{fh}/.claude/projects/-x-other/{sid}.jsonl", body)
transcript("s-mark", now, [f"Output {fm}"])                  # DELETE (marker in first user msg)
os.makedirs(f"{fh}/.claude/projects/-x-other/s-mark/subagents", exist_ok=True)
transcript("s-later", now, ["real work", f"later mention {fm}"])  # keep (marker not in FIRST msg)
transcript("s-old", old, [f"Output {fm}"])                   # keep (session predates since)
enc = lambda p: re.sub(r"[^A-Za-z0-9]", "-", p)
os.makedirs(f"{fh}/.claude/projects/{enc(fw)}/memory", exist_ok=True)   # DELETE (workdir's file-less dir)
w(f"{fh}/.claude/projects/{enc(fw + '-kept')}/memory/MEMORY.md", "note") # keep (not a workdir)
PYEOF
tcc() { TEST_CHAT_CLEANUP_HOME="$FH" PATH="$MOCKBIN:$PATH" bash "$CLEANUP" --since "$RUN_START" --marker "$FM" --workdir "$FW" "$@" 2>/dev/null; }
tcc_dry=$(tcc --dry-run); tcc_dry_st=$?
survivors() { (cd "$FH" && find . -name meta.json -o -name 'rollout-*.jsonl' -o -path './.claude/projects/*' -name '*.jsonl' | sort | tr '\n' ' '); }
before=$(survivors)
[ "$tcc_dry_st" = 0 ] && [ "$(grep -c $'^would-delete\t' <<<"$tcc_dry")" = 7 ] && [ "$(survivors)" = "$before" ] \
  && ok "mock:test-chat-cleanup-dry-run" || bad "mock:test-chat-cleanup-dry-run" "exit $tcc_dry_st: $(tr '\n' '|' <<<"$tcc_dry")"
tcc_out=$(tcc); tcc_st=$?
want=$(printf '%s\n' ./.claude/projects/-x-other/s-later.jsonl ./.claude/projects/-x-other/s-old.jsonl \
  ./.codex/sessions/2026/01/01/rollout-x-old.jsonl ./.codex/sessions/2026/01/01/rollout-x-plain.jsonl \
  "./.cursor/chats/$(printf %s /x/older-wd | md5sum | cut -c1-32)/c-wd-old/meta.json" \
  "./.cursor/chats/$(printf %s /x/other | md5sum | cut -c1-32)/c-plain/meta.json" | sort | tr '\n' ' ')
got=$(survivors)
[ "$tcc_st" = 0 ] && [ "$got" = "$want" ] && [ ! -e "$FH/.claude/projects/-x-other/s-mark" ] \
  && [ ! -e "$FH/.claude/projects/$(printf %s "$FW" | sed 's/[^A-Za-z0-9]/-/g')" ] \
  && [ -f "$FH/.claude/projects/$(printf %s "$FW-kept" | sed 's/[^A-Za-z0-9]/-/g')/memory/MEMORY.md" ] \
  && [ ! -d "$FH/.cursor/projects/$(printf %s "$FW" | sed -E 's/[^A-Za-z0-9]+/-/g; s/^-//')" ] && [ -d "$FH/.cursor/projects/x-other/agent-transcripts/c-plain" ] \
  && grep -q $'^note\tcodex\t.*unavailable' <<<"$tcc_out" \
  && ok "mock:test-chat-cleanup-deletes-only-matches" \
  || bad "mock:test-chat-cleanup-deletes-only-matches" "exit $tcc_st; left: $got; out: $(tr '\n' '|' <<<"$tcc_out")"
TEST_CHAT_CLEANUP_HOME="$FH" bash "$CLEANUP" --since 1 --marker "$FM" --workdir /tmp >/dev/null 2>&1; [ $? = 64 ] \
  && ok "mock:test-chat-cleanup-refuses-broad-workdir" || bad "mock:test-chat-cleanup-refuses-broad-workdir"

# ---------- Tier 1: zero-token model-run/auth checks ----------
cursor-agent status 2>&1 | grep -q "Logged in" && ok "auth:cursor-agent" || bad "auth:cursor-agent" "run: cursor-agent login"
codex login status 2>&1 | grep -qi "logged in" && ok "auth:codex" || bad "auth:codex" "run: codex login"
# xAI: zero-token key check (GET /v1/models via model-run.sh --xai-models).
if [ -n "$XID" ]; then
  if [ -z "$XAI_KEY_SRC" ]; then
    warn "auth:xai" "XAI_API_KEY is not set (env or ~/.profile) — xai routes ($XID, task x-recency) SKIPPED"
  else
    xm=$("$RUN" --xai-models 2>&1); xst=$?
    case "$xst" in
      0)  grep -qxF "$XAPI" <<<"$xm" && ok "auth:xai (key from $XAI_KEY_SRC)" \
            || bad "auth:xai" "key works but API model $XAPI is not in the xAI catalog" ;;
      75) xbad "auth:xai" "XAI_API_KEY rejected / out of credits: $(tail -1 <<<"$xm")" ;;
      *)  warn "auth:xai" "xAI catalog read failed (exit $xst: $(tail -1 <<<"$xm"))" ;;
    esac
  fi
fi
"$RUN" definitely-not-a-model-xq7 "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:unknown-id" "accepted garbage id" || ok "guard:unknown-id"
"$RUN" grok-4.5-xhigh "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:retired-id" "accepted retired id" || ok "guard:retired-id"
"$RUN" --task-type not-a-type "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:unknown-task-type" "accepted garbage task type" || ok "guard:unknown-task-type"
# 4th column: codex -> a valid reasoning level (optional); xai -> the API model
# id (required); every other backend -> empty
bad_effort=$(awk -F'\t' '$1=="model" && (($3=="codex" && $4!="" && $4 !~ /^(low|medium|high|xhigh|max)$/) || ($3=="xai" && $4 !~ /^grok-[a-z0-9.-]+$/) || ($3!="codex" && $3!="xai" && $4!="")) {print $2"="$4"("$3")"}' "$TABLE")
[ -z "$bad_effort" ] && ok "table:col4-valid(codex effort / xai api id)" || bad "table:col4-valid" "$bad_effort"
# ignore rows: exactly <ignore> <glob> <reason>, reason mandatory (an ignore
# row silences catalog-drift's `unrouted` finding — it has to say why)
bad_ignore=$(awk -F'\t' '$1=="ignore" && (NF!=3 || $2=="" || $3 !~ /[^[:space:]]/) {print "line " NR ": " $0}' "$TABLE")
[ -z "$bad_ignore" ] && ok "table:ignore-rows-valid" || bad "table:ignore-rows-valid" "$bad_ignore (want ignore<TAB><glob><TAB><reason>)"
# every task type must resolve to a model id present in the table
while IFS=$'\t' read -r _ tt mid; do
  awk -F'\t' -v m="$mid" '$1=="model" && $2==m {found=1} END {exit !found}' "$TABLE" \
    && ok "table:task-$tt->$mid" || bad "table:task-$tt->$mid" "resolves to unknown model"
done < <(awk -F'\t' '$1=="task"' "$TABLE")
# POSITIVE --task-type arg parsing, zero-token: with a nonexistent prompt file
# the script must fail on "prompt file missing" (proving promptfile/workdir are
# read from the right positions), NOT fall through to the usage error.
# Regression for the shift-2 positional bug (2026-07-23, found by another agent).
while IFS=$'\t' read -r _ tt mid; do
  err=$("$RUN" --task-type "$tt" /nonexistent/routecheck-probe.md 2>&1)
  case "$err" in
    *"prompt file missing"*) ok "args:task-type-$tt" ;;
    *) bad "args:task-type-$tt" "expected prompt-file error, got: $(printf '%s' "$err" | head -1)" ;;
  esac
  # the resolved id must be announced on stderr — the model-runner agent's MODEL: line reads it
  grep -qF -- "model-run: --task-type $tt -> $mid" <<<"$err" && ok "args:task-type-$tt-announces-id" || bad "args:task-type-$tt-announces-id" "stderr lacks 'model-run: --task-type $tt -> $mid'"
done < <(awk -F'\t' '$1=="task"' "$TABLE")

# ---------- Tier 1.5: live catalog drift (zero tokens) ----------
# bin/catalog-drift.sh: Cursor --list-models + Codex debug models vs routes.tsv.
#   vanished id  -> FAIL (the route will hard-error or silently remap)
#   newer family -> WARN (e.g. grok-4.8-* appeared; routes.tsv stops at 4.7 —
#                   nothing is broken, but add the rows + update the docs)
#   unrouted     -> WARN (catalog ids no model/retired/ignore row accounts for —
#                   route them or add `ignore` rows; the daily scout triages these)
#   unavailable  -> WARN (fail-open; auth tier above already flags login rot)
drift_out=$(bash "$DRIFT" 2>&1); drift_st=$?
drift_found=0
while IFS=$'\t' read -r kind msg; do
  case "$kind" in
    vanished)    bad  "drift:vanished" "$msg"; drift_found=1 ;;
    newer)       warn "drift:newer" "$msg (add rows to bin/routes.tsv, update model-selection.md/model-usage.md, rerun routecheck)"; drift_found=1 ;;
    unrouted)    warn "drift:unrouted" "$msg"; drift_found=1 ;;
    stale)       warn "drift:stale-catalog" "$msg" ;;
    unavailable) warn "drift:unavailable" "$msg" ;;
    "") ;;
    *)           warn "drift:unexpected-output" "$kind $msg" ;;
  esac
done <<<"$drift_out"
if [ "$drift_st" -eq 0 ]; then ok "drift:routes.tsv-matches-live-catalogs"
elif [ "$drift_st" -eq 2 ]; then warn "drift:no-catalog-readable" "drift check skipped entirely"
elif [ "$drift_found" -eq 0 ]; then bad "drift:script-error" "exit $drift_st: $(printf '%s' "$drift_out" | tr '\n' '|' | tail -c 300)"
fi

# ---------- Tier 2: nonce smokes for EVERY model row ----------
if [ "${1:-}" = "--no-live" ]; then
  [ "${#WARNINGS[@]}" -gt 0 ] && echo "WARNINGS (advisory, not failures): ${WARNINGS[*]}"
  [ "${#FAILURES[@]}" -eq 0 ] && { echo "FREE TIERS OK (live smokes skipped; route-health.txt untouched)"; exit 0; }
  echo "FAILURES (free tiers): ${FAILURES[*]}"; exit 1
fi
mapfile -t MODELS < <(awk -F'\t' '$1=="model"{print $2}' "$TABLE")
backend_of() { awk -F'\t' -v k="$1" '$1=="model" && $2==k {print $3; exit}' "$TABLE"; }
for m in "${MODELS[@]}"; do
  if [ "$(backend_of "$m")" = xai ]; then
    [ -n "$XAI_KEY_SRC" ] || continue   # already WARNed in Tier 1
    "$RUN" "$m" "$XAI_PROMPTFILE" "$WORK" >"$OUT/$m.txt" 2>&1 &
    continue
  fi
  "$RUN" "$m" "$PROMPTFILE" "$WORK" >"$OUT/$m.txt" 2>&1 &
done
# In $WORK, never the caller's cwd, and never persisted: a transcript would be
# imported into T3 Code as a visible thread within 15 min (it happened: the
# Aug-19/Sep-11/Sep-15 ROUTE-OK threads). Cleanup still sweeps $WORK's cwd.
(cd "$WORK" && timeout 300 claude -p --no-session-persistence --model haiku "$(cat "$PROMPTFILE")") >"$OUT/claude-haiku.txt" 2>&1 &
# One live smoke THROUGH --task-type (cheapest mapping) so the resolution path
# is exercised end-to-end, not just at the arg-parsing layer.
"$RUN" --task-type cheap "$PROMPTFILE" "$WORK" >"$OUT/task-cheap.txt" 2>&1 &
# Artifact smokes: one per backend. A text echo proves the chat path; these
# prove the backend can still WRITE FILES (tool execution / sandbox health —
# the failure class text round-trips cannot see). One codex + one cursor model.
for pair in "codex:gpt-5.6-terra" "cursor:composer-2.5"; do
  be="${pair%%:*}"; m="${pair##*:}"
  ad="$WORK/artifact-$be"; mkdir -p "$ad"; git -C "$ad" init -q 2>/dev/null || true
  af="$WORK/artifact-$be-prompt.md"
  printf 'Create a file named artifact.txt in the current working directory containing exactly this line and nothing else: %s — then output DONE.\n\n[test-run marker: %s]\n' "$NONCE" "$MARKER" > "$af"
  "$RUN" "$m" "$af" "$ad" >"$OUT/artifact-$be.txt" 2>&1 &
done
wait

DIGIT_SEP=$'(,| |\u2009|\u202f|\u00a0)'   # , space, thin / narrow no-break / no-break space
for m in "${MODELS[@]}"; do
  if [ "$(backend_of "$m")" = xai ]; then
    [ -n "$XAI_KEY_SRC" ] || { warn "route:$m" "skipped — no XAI_API_KEY"; continue; }
    # the per-run sum answered AND the response parsed (the xai-tools usage line
    # exists). Digit-group separators (231,456 / 231 456 / thin or no-break
    # space) are dropped first — only BETWEEN digits, so word boundaries survive.
    sed -E "s/([0-9])$DIGIT_SEP([0-9]{3})/\1\3/g" "$OUT/$m.txt" 2>/dev/null | grep -qw "$XAI_SUM" \
      && grep -q '^model-run: xai-tools ' "$OUT/$m.txt" \
      && ok "route:$m ($(grep -m1 -o 'x_search=[0-9]* web_search=[0-9]*.*cost_usd=[0-9.?]*' "$OUT/$m.txt"))" \
      || { xbad "route:$m"; tail -c 400 "$OUT/$m.txt" 2>/dev/null | sed 's/^/      /'; }
    continue
  fi
  grep -q "$NONCE" "$OUT/$m.txt" 2>/dev/null && ok "route:$m" || { bad "route:$m"; tail -c 300 "$OUT/$m.txt" 2>/dev/null | sed 's/^/      /'; }
done
grep -q "$NONCE" "$OUT/claude-haiku.txt" 2>/dev/null && ok "route:claude-haiku(native)" || bad "route:claude-haiku(native)"
grep -q "$NONCE" "$OUT/task-cheap.txt" 2>/dev/null && ok "route:--task-type-cheap(e2e)" || { bad "route:--task-type-cheap(e2e)"; tail -c 300 "$OUT/task-cheap.txt" 2>/dev/null | sed 's/^/      /'; }
for be in codex cursor; do
  if [ -f "$WORK/artifact-$be/artifact.txt" ] && grep -q "$NONCE" "$WORK/artifact-$be/artifact.txt"; then
    ok "artifact:$be"
  else
    bad "artifact:$be" "backend responded but wrote no verifiable file (tool-execution/sandbox may be broken)"
    tail -c 300 "$OUT/artifact-$be.txt" 2>/dev/null | sed 's/^/      /'
  fi
done

# ---------- Test-chat hygiene ----------
# Delete what the CLIs persisted for this run, then prove nothing is left.
# Expected: only Cursor chats (no ephemeral mode). A Codex or Claude deletion
# means prevention regressed (e.g. a CLI update renamed --ephemeral /
# --no-session-persistence) — cleaned anyway, but WARN so it gets fixed.
clean_out=$(clean_chats); clean_st=$?
grep -E $'^(deleted|note)\t' <<<"$clean_out" | awk -F'\t' '{c[$1" "$2]++} END {for (k in c) printf "      %s: %d\n", k, c[k]}' | sort
[ "$clean_st" -eq 0 ] && ok "hygiene:test-chat-cleanup" || bad "hygiene:test-chat-cleanup" "exit $clean_st: $(tail -c 300 <<<"$clean_out" | tr '\n' '|')"
grep -q $'^deleted\tcodex\t' <<<"$clean_out" && warn "hygiene:codex-not-ephemeral" "codex persisted test sessions despite MODEL_RUN_EPHEMERAL=1 — check model-run.sh --ephemeral against the installed codex"
# (claude's file-less ~/.claude/projects/<enc($WORK)>/ dir is expected litter, not a transcript)
grep -q $'^deleted\tclaude\ttranscript ' <<<"$clean_out" && warn "hygiene:claude-persisted" "claude -p --no-session-persistence still wrote a transcript — check the flag against the installed claude"
# Independent re-check (not just the cleanup script's own matcher): no Codex
# rollout since RUN_START mentions the marker, no Cursor chat store exists for
# a test workdir, and a dry-run sweep finds nothing further.
left=""
for w in "${TEST_WORKDIRS[@]}"; do
  [ -e "$HOME/.cursor/chats/$(printf %s "$w" | md5sum | cut -c1-32)" ] && left+="cursor:$w "
done
left+=$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -newermt "@$RUN_START" -exec grep -lF "$MARKER" {} + 2>/dev/null | sed 's/^/codex:/' | tr '\n' ' ')
wd_args=(); for w in "${TEST_WORKDIRS[@]}"; do wd_args+=(--workdir "$w"); done
left+=$(bash "$CLEANUP" --since "$RUN_START" --marker "$MARKER" "${wd_args[@]}" --dry-run 2>/dev/null | grep $'^would-delete\t' | cut -f2,3 | tr '\n' ' ')
[ -z "$left" ] && ok "hygiene:no-test-chats-left" || bad "hygiene:no-test-chats-left" "$left"

[ "${#WARNINGS[@]}" -gt 0 ] && echo "WARNINGS (advisory, not failures): ${WARNINGS[*]}"
# Record which CLI builds this run verified against; the SessionStart banner
# nags to re-run when claude / codex / cursor-agent changes underneath them.
bash "$FINGERPRINT" --versions > "$TOOLS" 2>/dev/null || true
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "$TODAY ok" > "$HEALTH"
  echo "ALL ROUTES OK"
  echo "(verified against: $(awk -F'\t' '{printf "%s %s; ", $1, $3}' "$TOOLS" 2>/dev/null))"
  echo "Next: from a Claude Code session, run tests/workflows/orchestration-smoke-{claude,model-runner}.js (Workflow scriptPath) to cover the Agent/Workflow layer."
  exit 0
fi
echo "$TODAY FAIL ${FAILURES[*]}" > "$HEALTH"
echo "ROUTE FAILURES — fix bin/routes.tsv / model-usage.md / model-selection.md (or remove the entry)"
exit 1
