#!/usr/bin/env bash
# model-run — THE single deterministic entrypoint for routing a prompt to a
# non-Claude model. Owns all flags, timeouts, and error detection so callers
# (and agents) never improvise CLI syntax. Routing data lives in routes.tsv
# (same directory) — the single source of truth for ids, backends, task types.
#
#   bash ~/dotfiles/claude/bin/model-run.sh <model-id> <promptfile> [workdir]
#   bash ~/dotfiles/claude/bin/model-run.sh --task-type <type> <promptfile> [workdir]
#
# Prints the model's output to stdout. Exit codes:
#   0   success
#   64  usage error (bad model id / task type, missing or >128 KiB prompt file)
#   73  transport error persisting after one automatic retry — retry later
#   75  auth/quota error — STOP and surface to the user; never substitute a model
#   124 timeout
# Env: MODEL_RUN_TIMEOUT=<secs> (default 600) · MODEL_RUN_EFFORT=<low|medium|
# high|xhigh|max> overrides the codex reasoning effort pinned in routes.tsv ·
# MODEL_RUN_EPHEMERAL=1 marks a TEST call: codex gets `--ephemeral` (no session
# files / thread rows, so nothing shows in `codex resume` or the Codex app).
# Cursor has no equivalent flag — test callers must pass a throwaway mktemp
# workdir and run bin/test-chat-cleanup.sh for it afterwards. Unset = normal,
# persisted delegations (their history is useful; only tests opt out).
# Claude models (sonnet/opus/haiku/fable) are NOT served here — use the Agent
# tool's `model` param (see ~/.claude/model-usage.md).
#
# Backend `xai` (e.g. grok-4.7-xsearch, --task-type x-recency) is the DIRECT xAI
# Responses API over curl — the only route with REAL X (Twitter) search: grok
# via cursor-agent has web search only. Request: the routes.tsv 4th column as
# the API model, tools web_search + x_search, `store: false` (xAI keeps no
# conversation). Stdout = the answer + a Sources list (every cited URL); stderr
# gets ONE line `model-run: xai-tools x_search=<n> web_search=<n> ...` (from the
# response's usage) so callers can prove X was actually searched. Key:
# XAI_API_KEY from the env, else extracted from ~/.profile exactly the way the
# cron line gets it (`. ~/.profile`) — never printed, never put in argv.
# Missing/rejected key, 402/429 credits/rate limit -> 75; 5xx/network
# (including a connect that never completes) -> one retry, then 73; a response
# that doesn't arrive within the timeout -> 124. xai-only env: MODEL_RUN_XSEARCH_FROM /
# MODEL_RUN_XSEARCH_TO=<YYYY-MM-DD> set x_search's from_date / to_date.
#   bash model-run.sh --xai-models   # zero-token xAI catalog read (GET /v1/models;
#                                    # catalog-drift.sh uses it). Exit 69 = no key;
#                                    # 75 = key rejected / out of credits; 73 = a
#                                    # plain 429 rate limit or network error.
set -u

TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/routes.tsv"
[ -f "$TABLE" ] || { echo "model-run: routing table missing: $TABLE" >&2; exit 64; }
lookup() { awk -F'\t' -v t="$1" -v k="$2" '$1==t && $2==k {print $3; exit}' "$TABLE"; }
# 4th field of a `model` row: codex -> optional pinned reasoning effort;
# xai -> the xAI API model id the route calls (required).
lookup_col4() { awk -F'\t' -v k="$1" '$1=="model" && $2==k {print $4; exit}' "$TABLE"; }
list()   { awk -F'\t' -v t="$1" '$1==t {printf "%s ", $2}' "$TABLE"; }

# XAI_API_KEY: the env first; else the value ~/.profile exports, read in a
# throwaway subshell (the cron line does `. ~/.profile` too — a Claude Code
# session not started from a login shell lacks it). Only that one variable is
# taken; nothing is exported or printed. MODEL_RUN_XAI_ENV_FILE overrides the
# file (tests point it at /dev/null to simulate "no key").
load_xai_key() {
  [ -n "${XAI_API_KEY:-}" ] && return 0
  local f="${MODEL_RUN_XAI_ENV_FILE:-$HOME/.profile}" k
  [ -r "$f" ] || return 1
  k=$(bash -c '. "$1" >/dev/null 2>&1 </dev/null; printf %s "${XAI_API_KEY:-}"' _ "$f" 2>/dev/null)
  [ -n "$k" ] || return 1
  XAI_API_KEY="$k"
}
XAI_BASE="https://api.x.ai/v1"
# curl with the key as a header read from a process-substitution fd, so it is
# never in argv (ps) or on disk. Sets HTTP (000 on no response), CURL_RC and
# XAI_TIMED_OUT=1 only for a REAL timeout: curl exits 28 for --connect-timeout
# too, but a connection that never completed (time_connect 0) is a transport
# failure — retried, then 73 — not a 124 that misstates the time.
xai_curl() { # xai_curl <outfile> <max-secs> <curl args...>
  local out="$1" secs="$2" w tconn; shift 2
  w=$(curl -sS --connect-timeout 20 -m "$secs" -o "$out" -w '%{http_code} %{time_connect}' \
    -H @<(printf 'Authorization: Bearer %s\n' "$XAI_API_KEY") "$@" 2>"$out.err")
  CURL_RC=$?
  read -r HTTP tconn <<<"$w"
  [ -n "$HTTP" ] || HTTP=000
  XAI_TIMED_OUT=0
  # time_connect is 0.000000 until the TCP connect completes.
  [ "$CURL_RC" -eq 28 ] && [[ "${tconn:-0}" =~ [1-9] ]] && XAI_TIMED_OUT=1
}

if [ "${1:-}" = "--xai-models" ]; then
  load_xai_key || { echo "model-run: XAI_API_KEY not set (env or ~/.profile)" >&2; exit 69; }
  XT=$(mktemp -d /tmp/model-run-xai.XXXXXX) || exit 73; trap 'rm -rf "$XT"' EXIT
  xai_curl "$XT/models.json" "${MODEL_RUN_TIMEOUT:-30}" "$XAI_BASE/models"
  [ "$XAI_TIMED_OUT" = 1 ] && { echo "model-run: xAI catalog read timed out" >&2; exit 124; }
  body=$(head -c 300 "$XT/models.json" 2>/dev/null | tr '\n' ' ')
  # Only a verdict about the KEY/credits is 75 (callers turn it into a hard
  # auth FAIL): 401/402/403, or a 400/429 whose body says so. A plain 429 rate
  # limit on this zero-token read is transient — 73, which routecheck WARNs on.
  case "$HTTP" in
    200) python3 -c 'import json,sys
ids=[m.get("id") for m in json.load(open(sys.argv[1])).get("data",[]) if m.get("id")]
print("\n".join(ids)) if ids else sys.exit(65)' "$XT/models.json" || { echo "model-run: xAI catalog unparseable" >&2; exit 65; } ;;
    401|402|403) echo "model-run: xAI catalog read HTTP $HTTP — XAI_API_KEY rejected or out of credits: $body" >&2; exit 75 ;;
    400|429)
      if printf '%s' "$body" | grep -qiE 'api key|credits|spending limit|quota|permission'; then
        echo "model-run: xAI catalog read HTTP $HTTP — XAI_API_KEY rejected or out of credits: $body" >&2; exit 75
      fi
      echo "model-run: xAI catalog read failed (HTTP $HTTP, likely a transient rate limit): $body" >&2; exit 73 ;;
    *) echo "model-run: xAI catalog read failed (HTTP $HTTP, curl exit $CURL_RC)" >&2; exit 73 ;;
  esac
  exit 0
fi

usage() {
  echo "usage: model-run.sh <model-id>|--task-type <type> <promptfile> [workdir]" >&2
  echo "  model ids:  $(list model)" >&2
  echo "  task types: $(list task)" >&2
  exit 64
}

# Consume the model/task-type args, then read promptfile/workdir positionally —
# both invocation forms leave $1=promptfile, $2=workdir after the shifts.
MODEL="${1:-}"
if [ "$MODEL" = "--task-type" ]; then
  TT="${2:-}"; shift 2 2>/dev/null || usage
  MODEL=$(lookup task "$TT")
  [ -n "$MODEL" ] || { echo "model-run: unknown task type '$TT'. Task types: $(list task)" >&2; exit 64; }
  # Tell the caller (e.g. the model-runner agent's MODEL: line) which concrete id ran.
  echo "model-run: --task-type $TT -> $MODEL" >&2
else
  shift 1 2>/dev/null || usage
fi
PROMPTFILE="${1:-}"; WORKDIR="${2:-$PWD}"
[ -n "$MODEL" ] && [ -n "$PROMPTFILE" ] || usage
[ -s "$PROMPTFILE" ] || { echo "model-run: prompt file missing or empty: $PROMPTFILE (always pass prompts via file, never inline)" >&2; exit 64; }
[ -d "$WORKDIR" ] || { echo "model-run: workdir does not exist: $WORKDIR" >&2; exit 64; }
# Both backends get the prompt as ONE argv string, and Linux caps a single
# argument at 128 KiB (MAX_ARG_STRLEN): a bigger prompt dies in execve (E2BIG,
# exit 126) with no useful message — e.g. a big diff pasted inline into a
# second-review prompt (2026-09-22). Reference large inputs by path instead.
PROMPT_BYTES=$(wc -c <"$PROMPTFILE")
[ "$PROMPT_BYTES" -lt 131000 ] || { echo "model-run: prompt file is $PROMPT_BYTES bytes — over the 128 KiB single-argument limit. Put large inputs (diffs, logs) in files inside the workdir and reference them by relative path in the prompt." >&2; exit 64; }
TIMEOUT="${MODEL_RUN_TIMEOUT:-600}"

case "$MODEL" in
  sonnet|opus|haiku|fable|claude-*)
    echo "model-run: '$MODEL' is a Claude model — use the Agent tool's model param, not this script (see model-usage.md)" >&2; exit 64 ;;
esac
BACKEND=$(lookup model "$MODEL")
if [ -z "$BACKEND" ]; then
  SUCCESSOR=$(lookup retired "$MODEL")
  if [ -n "$SUCCESSOR" ]; then
    echo "model-run: '$MODEL' is a RETIRED id — use $SUCCESSOR" >&2; exit 64
  fi
  echo "model-run: unknown model id '$MODEL'. Known ids: $(list model)(see bin/routes.tsv, or cursor-agent --list-models for the live catalog)" >&2; exit 64
fi
COL4=$(lookup_col4 "$MODEL")
API_MODEL=""
if [ "$BACKEND" = xai ]; then
  API_MODEL="$COL4"; EFFORT="${MODEL_RUN_EFFORT:-}"
  [ -n "$API_MODEL" ] || { echo "model-run: routes.tsv row for '$MODEL' (backend xai) lacks the xAI API model id in column 4" >&2; exit 64; }
else
  EFFORT="${MODEL_RUN_EFFORT:-$COL4}"
fi
if [ -n "$EFFORT" ] && [ "$BACKEND" != codex ]; then
  echo "model-run: reasoning effort ('$EFFORT') is a codex-only knob — ignored for backend '$BACKEND'" >&2
  EFFORT=""
fi

run_codex() {
  local args=()
  [ "$MODEL" != "gpt-5.5" ] && args=(-m "$MODEL")
  # Reasoning effort: routes.tsv 4th column, overridable per call with
  # MODEL_RUN_EFFORT. Codex otherwise uses each model's catalog default, which
  # for the frontier tiers (gpt-6-astra, gpt-5.6-sol) is "low".
  [ -n "$EFFORT" ] && args+=(-c "model_reasoning_effort=\"$EFFORT\"")
  # Test runs (routecheck, the daily model scout) must not leave chats behind:
  # before 2026-09-22 every routecheck left ~5 rollouts + state_5 thread rows
  # (97 ROUTE-OK threads had piled up). `--ephemeral` = "Run without persisting
  # session files to disk" (codex-cli 0.155.1).
  [ "${MODEL_RUN_EPHEMERAL:-0}" = 1 ] && args+=(--ephemeral)
  timeout "$TIMEOUT" codex exec --dangerously-bypass-approvals-and-sandbox \
    -C "$WORKDIR" "${args[@]}" "$(cat "$PROMPTFILE")" 2>&1
}
run_cursor() {
  (cd "$WORKDIR" && timeout "$TIMEOUT" cursor-agent --print --trust --force \
    --output-format text --model "$MODEL" "$(cat "$PROMPTFILE")" 2>&1)
}

# Direct xAI Responses API (see header). Owns its whole exit contract — HTTP
# status codes classify errors precisely, so the text-grep classifier below
# (built for CLI output) is not used for it.
run_xai() {
  local fr to d
  for d in "${MODEL_RUN_XSEARCH_FROM:-}" "${MODEL_RUN_XSEARCH_TO:-}"; do
    [ -z "$d" ] || [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "model-run: MODEL_RUN_XSEARCH_FROM/TO must be YYYY-MM-DD (got '$d')" >&2; return 64; }
  done
  if ! load_xai_key; then
    echo "model-run: AUTH/QUOTA ERROR on backend 'xai' — XAI_API_KEY not set (neither in the environment nor exported by ~/.profile). STOP and surface this to the user. Do NOT substitute another model." >&2
    return 75
  fi
  XT=$(mktemp -d /tmp/model-run-xai.XXXXXX) || return 73
  trap 'rm -rf "$XT"' EXIT
  python3 - "$PROMPTFILE" "$API_MODEL" "${MODEL_RUN_XSEARCH_FROM:-}" "${MODEL_RUN_XSEARCH_TO:-}" >"$XT/req.json" <<'PY' || { echo "model-run: could not build the xAI request" >&2; return 64; }
import json, sys
pf, model, frm, to = sys.argv[1:5]
x = {"type": "x_search"}
if frm: x["from_date"] = frm
if to: x["to_date"] = to
print(json.dumps({"model": model,
                  "input": [{"role": "user", "content": open(pf, encoding="utf-8", errors="replace").read()}],
                  "tools": [{"type": "web_search"}, x],
                  "store": False}))
PY
  local attempt=1 body
  while :; do
    xai_curl "$XT/resp.json" "$TIMEOUT" -H 'Content-Type: application/json' --data-binary @"$XT/req.json" "$XAI_BASE/responses"
    if [ "$XAI_TIMED_OUT" = 1 ]; then
      echo "model-run: TIMEOUT after ${TIMEOUT}s on xai/$MODEL (override with MODEL_RUN_TIMEOUT=<secs>)" >&2; return 124
    fi
    # 5xx or no HTTP response at all (DNS, refused, reset, TLS, connect
    # timeout): transport.
    if [ "$HTTP" = 000 ] || [ "${HTTP:0:1}" = 5 ]; then
      if [ "$attempt" -eq 1 ]; then
        echo "model-run: transport error on xai/$MODEL (HTTP $HTTP, curl exit $CURL_RC) — retrying once in ${MODEL_RUN_RETRY_DELAY:-5}s" >&2
        sleep "${MODEL_RUN_RETRY_DELAY:-5}"; attempt=2; continue
      fi
      echo "model-run: TRANSPORT ERROR on xai/$MODEL persisted after retry (HTTP $HTTP, curl exit $CURL_RC: $(head -c 200 "$XT/resp.json.err" 2>/dev/null | tr '\n' ' ')) — likely provider/network degradation. Retry later; do NOT substitute another model without asking the user." >&2
      return 73
    fi
    break
  done
  body=$(head -c 400 "$XT/resp.json" 2>/dev/null | tr '\n' ' ')
  case "$HTTP" in
    200) ;;
    401|403)
      echo "model-run: AUTH/QUOTA ERROR on backend 'xai' (HTTP $HTTP) — XAI_API_KEY rejected: $body — STOP and surface this to the user verbatim. Do NOT substitute another model. Fix: the key exported in ~/.profile / team permissions at console.x.ai" >&2
      return 75 ;;
    402|429)
      echo "model-run: AUTH/QUOTA ERROR on backend 'xai' (HTTP $HTTP) — xAI credits, spending limit or rate limit exhausted: $body — STOP and surface this to the user verbatim. Do NOT substitute another model. Fix: console.x.ai billing" >&2
      return 75 ;;
    400)
      # xAI answers a bad key with 400 "Incorrect API key provided" (verified 2026-09-22).
      if printf '%s' "$body" | grep -qiE 'api key|credits|spending limit|quota|permission'; then
        echo "model-run: AUTH/QUOTA ERROR on backend 'xai' (HTTP 400) — XAI_API_KEY rejected: $body — STOP and surface this to the user verbatim. Do NOT substitute another model. Fix: the key exported in ~/.profile / console.x.ai" >&2
        return 75
      fi
      echo "model-run: xAI rejected the request (HTTP 400): $body" >&2; return 1 ;;
    *)
      echo "model-run: xAI request failed (HTTP $HTTP): $body" >&2; return 1 ;;
  esac
  # Answer text + every cited URL (inline url_citation annotations and the
  # root `citations` list) on stdout; tool-call counts on stderr.
  python3 - "$XT/resp.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"model-run: xAI returned HTTP 200 but unparseable JSON ({e})", file=sys.stderr); sys.exit(1)
texts, urls = [], []
def add(u):
    if isinstance(u, str) and u and u not in urls: urls.append(u)
out = d.get("output") or []
for o in out:
    if o.get("type") == "message":
        for c in o.get("content") or []:
            if c.get("type") == "output_text":
                texts.append(c.get("text") or "")
                for a in c.get("annotations") or []:
                    if a.get("type") == "url_citation": add(a.get("url"))
for u in d.get("citations") or []:
    add(u if isinstance(u, str) else (u or {}).get("url"))
usage = d.get("usage") or {}
det = usage.get("server_side_tool_usage_details") or {}
calls = [o for o in out if o.get("type") in ("custom_tool_call", "function_call", "web_search_call", "x_search_call")]
xs = det.get("x_search_calls")
if xs is None: xs = sum(1 for o in calls if o.get("type") == "x_search_call" or str(o.get("name", "")).startswith("x_"))
ws = det.get("web_search_calls")
if ws is None: ws = sum(1 for o in calls if o.get("type") == "web_search_call" or str(o.get("name", "")).startswith(("web_", "browse")))
cost = usage.get("cost_in_usd_ticks")
cost = "%.4f" % (cost / 1e10) if isinstance(cost, (int, float)) else "?"
text = "\n".join(t for t in texts if t).strip()
tools = (f"x_search={xs} web_search={ws} x_posts={det.get('x_posts_fetched', '?')} "
         f"cited_urls={len(urls)} status={d.get('status', '?')} cost_usd={cost} store={str(d.get('store')).lower()}")
if not text:
    print(f"model-run: xAI returned no output text ({tools}; error {d.get('error')})", file=sys.stderr); sys.exit(1)
# Printed ONLY for a usable answer: callers (the model scout) treat this line
# as proof the call succeeded, and its x_search count as proof X was searched.
print(f"model-run: xai-tools {tools}", file=sys.stderr)
print(text)
if urls:
    print("\nSources:")
    for u in urls: print(f"- {u}")
PY
}
if [ "$BACKEND" = xai ]; then
  run_xai; exit $?
fi

# Transient transport failures (connection drops, gateway errors) get ONE
# automatic retry after a short backoff — provider degradations are common
# enough that a single blip shouldn't hard-fail a delegation. Persistent
# transport failure exits 73 (distinct from auth 75: retrying later may help,
# switching models won't fix the network).
is_transport() {
  printf '%s' "$1" | grep -qiE 'connection (reset|refused|closed|lost|error)|ECONNRESET|ETIMEDOUT|ENETUNREACH|stream (error|disconnected)|network error|50[234] (bad gateway|service unavailable|gateway timeout)|TLS handshake|temporary failure in name resolution'
}

ATTEMPT=1
while :; do
  OUTPUT=$("run_$BACKEND"); STATUS=$?
  if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ] && [ "$ATTEMPT" -eq 1 ] && is_transport "$OUTPUT"; then
    echo "model-run: transport error on $BACKEND/$MODEL — retrying once in ${MODEL_RUN_RETRY_DELAY:-5}s" >&2
    sleep "${MODEL_RUN_RETRY_DELAY:-5}"; ATTEMPT=2; continue
  fi
  break
done
printf '%s\n' "$OUTPUT"

# Auth/quota classification is gated on a nonzero exit: model output legitimately
# QUOTING these phrases (e.g. a task about this script) must not trip the detector.
if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ] && printf '%s' "$OUTPUT" | grep -qiE 'authentication required|not logged in|insufficient_quota|rate limit exceeded|billing hard limit'; then
  echo "model-run: AUTH/QUOTA ERROR on backend '$BACKEND' — STOP and surface this to the user verbatim. Do NOT substitute another model. Fix: $([ "$BACKEND" = cursor ] && echo cursor-agent login || echo codex login)" >&2
  exit 75
fi
if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ] && is_transport "$OUTPUT"; then
  echo "model-run: TRANSPORT ERROR on $BACKEND/$MODEL persisted after retry — likely provider/network degradation. Retry later; do NOT substitute another model without asking the user." >&2
  exit 73
fi
if [ "$STATUS" -eq 124 ]; then
  echo "model-run: TIMEOUT after ${TIMEOUT}s on $BACKEND/$MODEL (override with MODEL_RUN_TIMEOUT=<secs>)" >&2
  exit 124
fi
exit "$STATUS"
