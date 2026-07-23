#!/usr/bin/env bash
# model-run — THE single deterministic entrypoint for routing a prompt to a
# non-Claude model. Owns all flags, timeouts, and error detection so callers
# (and agents) never improvise CLI syntax.
#
#   bash ~/dotfiles/claude/bin/model-run.sh <model-id> <promptfile> [workdir]
#
# Prints the model's output to stdout. Exit codes:
#   0   success
#   64  usage error (bad model id, missing prompt file)
#   75  auth/quota error — STOP and surface to the user; never substitute a model
#   124 timeout
# Claude models (sonnet/opus/haiku/fable) are NOT served here — use the Agent
# tool's `model` param (see ~/.claude/model-usage.md).
set -u

usage() { echo "usage: model-run.sh <model-id> <promptfile> [workdir]" >&2; exit 64; }
MODEL="${1:-}"; PROMPTFILE="${2:-}"; WORKDIR="${3:-$PWD}"
[ -n "$MODEL" ] && [ -n "$PROMPTFILE" ] || usage
[ -s "$PROMPTFILE" ] || { echo "model-run: prompt file missing or empty: $PROMPTFILE (always pass prompts via file, never inline)" >&2; exit 64; }
[ -d "$WORKDIR" ] || { echo "model-run: workdir does not exist: $WORKDIR" >&2; exit 64; }
TIMEOUT="${MODEL_RUN_TIMEOUT:-600}"

# ---- Routing table: model id -> backend. Keep in sync with model-selection.md.
case "$MODEL" in
  gpt-5.5|gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna)
    BACKEND=codex ;;
  composer-2.5|composer-2.5-fast|cursor-grok-4.5-high|cursor-grok-4.5-high-fast|cursor-grok-4.5-medium|cursor-grok-4.5-low|glm-5.2-high|glm-5.2-max)
    BACKEND=cursor ;;
  sonnet|opus|haiku|fable|claude-*)
    echo "model-run: '$MODEL' is a Claude model — use the Agent tool's model param, not this script (see model-usage.md)" >&2; exit 64 ;;
  grok-4.5-xhigh|grok-4.5-fast-xhigh)
    echo "model-run: '$MODEL' is a RETIRED id — use cursor-grok-4.5-high" >&2; exit 64 ;;
  *)
    echo "model-run: unknown model id '$MODEL'. Known ids: gpt-5.5 gpt-5.6-{sol,terra,luna} composer-2.5[-fast] cursor-grok-4.5-{high[-fast],medium,low} glm-5.2-{high,max}. Check model-selection.md or cursor-agent --list-models." >&2; exit 64 ;;
esac

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

OUTPUT=$("run_$BACKEND"); STATUS=$?
printf '%s\n' "$OUTPUT"

if printf '%s' "$OUTPUT" | grep -qiE 'authentication required|not logged in|insufficient_quota|rate limit exceeded|billing hard limit'; then
  echo "model-run: AUTH/QUOTA ERROR on backend '$BACKEND' — STOP and surface this to the user verbatim. Do NOT substitute another model. Fix: ${BACKEND} login ($([ "$BACKEND" = cursor ] && echo cursor-agent login || echo codex login))" >&2
  exit 75
fi
if [ "$STATUS" -eq 124 ]; then
  echo "model-run: TIMEOUT after ${TIMEOUT}s on $BACKEND/$MODEL (override with MODEL_RUN_TIMEOUT=<secs>)" >&2
  exit 124
fi
exit "$STATUS"
