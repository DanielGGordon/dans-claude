#!/usr/bin/env bash
# routecheck — live-verify every model route in bin/routes.tsv by invoking it
# through bin/model-run.sh (the same entrypoint agents use — the tested path IS
# the used path), plus zero-token guard and hook unit tests.
#
#   bash ~/dotfiles/claude/tests/routecheck.sh            # everything, parallel
#   bash ~/dotfiles/claude/tests/routecheck.sh --no-live  # free tiers only; does not update route-health.txt
#
# A route passes only if the model echoes a nonce back. ~100 tokens per route.
# Writes ~/.claude/route-health.txt for the SessionStart banner hook.
# If a route FAILs, fix bin/routes.tsv / the docs or remove the model — never
# leave a documented route broken.
set -u

DIR="$HOME/dotfiles/claude"
RUN="$DIR/bin/model-run.sh"
TABLE="$DIR/bin/routes.tsv"
GUARD="$DIR/hooks/route-guard.sh"
NONCE="ROUTE-OK-$RANDOM$RANDOM"
WORK=$(mktemp -d /tmp/routecheck.XXXXXX)
OUT="$WORK/out"; mkdir -p "$OUT"
git -C "$WORK" init -q 2>/dev/null || true
PROMPTFILE="$WORK/prompt.md"
echo "Output exactly this line and nothing else: $NONCE" > "$PROMPTFILE"
HEALTH="$HOME/.claude/route-health.txt"
TODAY=$(date +%F)
declare -a FAILURES=()

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1${2:+ — $2}"; FAILURES+=("$1"); }

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
expect_allow "bash $RUN gpt-5.6-terra /tmp/p.md" "model-run.sh call"
expect_allow "grep 'codex exec' $RUN" "grep mentioning codex exec"
expect_allow 'ls -la && git status' "unrelated command"

# ---------- Tier 1: zero-token model-run/auth checks ----------
cursor-agent status 2>&1 | grep -q "Logged in" && ok "auth:cursor-agent" || bad "auth:cursor-agent" "run: cursor-agent login"
codex login status 2>&1 | grep -qi "logged in" && ok "auth:codex" || bad "auth:codex" "run: codex login"
"$RUN" definitely-not-a-model-xq7 "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:unknown-id" "accepted garbage id" || ok "guard:unknown-id"
"$RUN" grok-4.5-xhigh "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:retired-id" "accepted retired id" || ok "guard:retired-id"
"$RUN" --task-type not-a-type "$PROMPTFILE" >/dev/null 2>&1 && bad "guard:unknown-task-type" "accepted garbage task type" || ok "guard:unknown-task-type"
# every task type must resolve to a model id present in the table
while IFS=$'\t' read -r _ tt mid; do
  awk -F'\t' -v m="$mid" '$1=="model" && $2==m {found=1} END {exit !found}' "$TABLE" \
    && ok "table:task-$tt->$mid" || bad "table:task-$tt->$mid" "resolves to unknown model"
done < <(awk -F'\t' '$1=="task"' "$TABLE")

# ---------- Tier 2: nonce smokes for EVERY model row ----------
if [ "${1:-}" = "--no-live" ]; then
  rm -rf "$WORK"
  [ "${#FAILURES[@]}" -eq 0 ] && { echo "FREE TIERS OK (live smokes skipped; route-health.txt untouched)"; exit 0; }
  echo "FAILURES (free tiers): ${FAILURES[*]}"; exit 1
fi
mapfile -t MODELS < <(awk -F'\t' '$1=="model"{print $2}' "$TABLE")
for m in "${MODELS[@]}"; do
  "$RUN" "$m" "$PROMPTFILE" "$WORK" >"$OUT/$m.txt" 2>&1 &
done
timeout 300 claude -p --model haiku "$(cat "$PROMPTFILE")" >"$OUT/claude-haiku.txt" 2>&1 &
wait

for m in "${MODELS[@]}"; do
  grep -q "$NONCE" "$OUT/$m.txt" 2>/dev/null && ok "route:$m" || { bad "route:$m"; tail -c 300 "$OUT/$m.txt" 2>/dev/null | sed 's/^/      /'; }
done
grep -q "$NONCE" "$OUT/claude-haiku.txt" 2>/dev/null && ok "route:claude-haiku(native)" || bad "route:claude-haiku(native)"

rm -rf "$WORK"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "$TODAY ok" > "$HEALTH"
  echo "ALL ROUTES OK"
  exit 0
fi
echo "$TODAY FAIL ${FAILURES[*]}" > "$HEALTH"
echo "ROUTE FAILURES — fix bin/routes.tsv / model-usage.md / model-selection.md (or remove the entry)"
exit 1
