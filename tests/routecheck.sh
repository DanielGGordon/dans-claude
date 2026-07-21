#!/usr/bin/env bash
# routecheck — live-verify every model route documented in model-usage.md /
# model-selection.md by actually invoking it with a nonce prompt.
#
#   bash ~/dotfiles/claude/tests/routecheck.sh          # all routes, parallel
#
# Each route runs the EXACT canonical invocation from model-usage.md. A route
# passes only if the model echoes the nonce back. Costs ~100 tokens per route.
# If a route FAILs here, the policy markdown is wrong: fix the id/syntax or
# remove the model from the docs — never leave a documented route broken.
set -u

NONCE="ROUTE-OK-$RANDOM$RANDOM"
PROMPT="Output exactly this line and nothing else: $NONCE"
WORK=$(mktemp -d /tmp/routecheck.XXXXXX)
OUT="$WORK/out"
mkdir -p "$OUT"
git -C "$WORK" init -q 2>/dev/null || true
TIMEOUT=300

# ---------- Tier 1: zero-token auth checks ----------
auth_fail=0
if cursor-agent status 2>&1 | grep -q "Logged in"; then
  echo "PASS  auth:cursor-agent"
else
  echo "FAIL  auth:cursor-agent — run: cursor-agent login"; auth_fail=1
fi
if codex login status 2>&1 | grep -qi "logged in"; then
  echo "PASS  auth:codex"
else
  echo "FAIL  auth:codex — run: codex login"; auth_fail=1
fi

# ---------- Tier 2: nonce smokes (exact canonical invocations) ----------
smoke_cursor() { # $1 = model id
  timeout "$TIMEOUT" cursor-agent --print --trust --force --output-format text \
    --model "$1" "$PROMPT" >"$OUT/cursor-$1.txt" 2>&1
}
smoke_codex() { # $1 = model id ("" = CLI default)
  local args=()
  [ -n "$1" ] && args=(-m "$1")
  timeout "$TIMEOUT" codex exec --dangerously-bypass-approvals-and-sandbox \
    -C "$WORK" "${args[@]}" "$PROMPT" >"$OUT/codex-${1:-default}.txt" 2>&1
}
smoke_claude() { # $1 = model alias
  timeout "$TIMEOUT" claude -p --model "$1" "$PROMPT" >"$OUT/claude-$1.txt" 2>&1
}

CURSOR_MODELS=(composer-2.5 cursor-grok-4.5-high glm-5.2-high)
CODEX_MODELS=("" gpt-5.6-terra gpt-5.6-sol gpt-5.6-luna)
CLAUDE_MODELS=(haiku)

for m in "${CURSOR_MODELS[@]}"; do smoke_cursor "$m" & done
for m in "${CODEX_MODELS[@]}";  do smoke_codex  "$m" & done
for m in "${CLAUDE_MODELS[@]}"; do smoke_claude "$m" & done
wait

fail=0
report() { # $1 = label, $2 = output file
  if grep -q "$NONCE" "$2" 2>/dev/null; then
    echo "PASS  $1"
  else
    fail=1
    echo "FAIL  $1 — output tail:"
    tail -c 400 "$2" 2>/dev/null | sed 's/^/      /'
  fi
}
for m in "${CURSOR_MODELS[@]}"; do report "cursor:$m" "$OUT/cursor-$m.txt"; done
for m in "${CODEX_MODELS[@]}";  do report "codex:${m:-default(gpt-5.5)}" "$OUT/codex-${m:-default}.txt"; done
for m in "${CLAUDE_MODELS[@]}"; do report "claude:$m" "$OUT/claude-$m.txt"; done

rm -rf "$WORK"
[ "$fail" -eq 0 ] && [ "$auth_fail" -eq 0 ] && { echo "ALL ROUTES OK"; exit 0; }
echo "ROUTE FAILURES — fix or remove the corresponding entry in model-usage.md / model-selection.md"
exit 1
