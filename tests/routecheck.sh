#!/usr/bin/env bash
# routecheck — live-verify every model route documented in model-usage.md /
# model-selection.md by invoking it through bin/model-run.sh (the same
# entrypoint agents use — the tested path IS the used path).
#
#   bash ~/dotfiles/claude/tests/routecheck.sh          # all routes, parallel
#
# A route passes only if the model echoes a nonce back. ~100 tokens per route.
# Writes ~/.claude/route-health.txt for the SessionStart banner hook.
# If a route FAILs, the policy markdown is wrong: fix the id/syntax or remove
# the model from the docs — never leave a documented route broken.
set -u

RUN="$HOME/dotfiles/claude/bin/model-run.sh"
NONCE="ROUTE-OK-$RANDOM$RANDOM"
WORK=$(mktemp -d /tmp/routecheck.XXXXXX)
OUT="$WORK/out"; mkdir -p "$OUT"
git -C "$WORK" init -q 2>/dev/null || true
PROMPTFILE="$WORK/prompt.md"
echo "Output exactly this line and nothing else: $NONCE" > "$PROMPTFILE"
HEALTH="$HOME/.claude/route-health.txt"
TODAY=$(date +%F)

# ---------- Tier 1: zero-token checks ----------
declare -a FAILURES=()
if cursor-agent status 2>&1 | grep -q "Logged in"; then
  echo "PASS  auth:cursor-agent"
else
  echo "FAIL  auth:cursor-agent — run: cursor-agent login"; FAILURES+=("auth:cursor")
fi
if codex login status 2>&1 | grep -qi "logged in"; then
  echo "PASS  auth:codex"
else
  echo "FAIL  auth:codex — run: codex login"; FAILURES+=("auth:codex")
fi
# model-run.sh must reject garbage and retired ids without spending tokens
"$RUN" definitely-not-a-model-xq7 "$PROMPTFILE" >/dev/null 2>&1 && { echo "FAIL  guard:unknown-id (model-run accepted garbage id)"; FAILURES+=("guard:unknown-id"); } || echo "PASS  guard:unknown-id"
"$RUN" grok-4.5-xhigh "$PROMPTFILE" >/dev/null 2>&1 && { echo "FAIL  guard:retired-id (model-run accepted grok-4.5-xhigh)"; FAILURES+=("guard:retired-id"); } || echo "PASS  guard:retired-id"

# ---------- Tier 2: nonce smokes through model-run.sh ----------
MODELS=(gpt-5.5 gpt-5.6-terra gpt-5.6-sol gpt-5.6-luna composer-2.5 cursor-grok-4.5-high glm-5.2-high)
for m in "${MODELS[@]}"; do
  "$RUN" "$m" "$PROMPTFILE" "$WORK" >"$OUT/$m.txt" 2>&1 &
done
# Native Claude route (not model-run.sh's job — verified via claude -p)
timeout 300 claude -p --model haiku "$(cat "$PROMPTFILE")" >"$OUT/claude-haiku.txt" 2>&1 &
wait

report() { # $1 label, $2 file
  if grep -q "$NONCE" "$2" 2>/dev/null; then
    echo "PASS  $1"
  else
    FAILURES+=("$1")
    echo "FAIL  $1 — output tail:"
    tail -c 400 "$2" 2>/dev/null | sed 's/^/      /'
  fi
}
for m in "${MODELS[@]}"; do report "route:$m" "$OUT/$m.txt"; done
report "route:claude-haiku(native)" "$OUT/claude-haiku.txt"

rm -rf "$WORK"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "$TODAY ok" > "$HEALTH"
  echo "ALL ROUTES OK"
  exit 0
fi
echo "$TODAY FAIL ${FAILURES[*]}" > "$HEALTH"
echo "ROUTE FAILURES — fix or remove the corresponding entry in model-usage.md / model-selection.md"
exit 1
