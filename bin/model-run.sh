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
#   64  usage error (bad model id / task type, missing prompt file)
#   73  transport error persisting after one automatic retry — retry later
#   75  auth/quota error — STOP and surface to the user; never substitute a model
#   124 timeout
# Claude models (sonnet/opus/haiku/fable) are NOT served here — use the Agent
# tool's `model` param (see ~/.claude/model-usage.md).
set -u

TABLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/routes.tsv"
[ -f "$TABLE" ] || { echo "model-run: routing table missing: $TABLE" >&2; exit 64; }
lookup() { awk -F'\t' -v t="$1" -v k="$2" '$1==t && $2==k {print $3; exit}' "$TABLE"; }
list()   { awk -F'\t' -v t="$1" '$1==t {printf "%s ", $2}' "$TABLE"; }

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
else
  shift 1 2>/dev/null || usage
fi
PROMPTFILE="${1:-}"; WORKDIR="${2:-$PWD}"
[ -n "$MODEL" ] && [ -n "$PROMPTFILE" ] || usage
[ -s "$PROMPTFILE" ] || { echo "model-run: prompt file missing or empty: $PROMPTFILE (always pass prompts via file, never inline)" >&2; exit 64; }
[ -d "$WORKDIR" ] || { echo "model-run: workdir does not exist: $WORKDIR" >&2; exit 64; }
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

run_codex() {
  local args=()
  [ "$MODEL" != "gpt-5.5" ] && args=(-m "$MODEL")
  timeout "$TIMEOUT" codex exec --dangerously-bypass-approvals-and-sandbox \
    -C "$WORKDIR" "${args[@]}" "$(cat "$PROMPTFILE")" 2>&1
}
run_cursor() {
  (cd "$WORKDIR" && timeout "$TIMEOUT" cursor-agent --print --trust --force \
    --output-format text --model "$MODEL" "$(cat "$PROMPTFILE")" 2>&1)
}

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
