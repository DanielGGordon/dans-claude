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
# live catalog is a FAIL; a NEWER version of a routed family (e.g. cursor-grok-4.7
# when routes.tsv stops at 4.6) is a WARN — nothing is broken, but update routes.tsv.
# Writes ~/.claude/route-health.txt for the SessionStart banner hook.
# If a route FAILs, fix bin/routes.tsv / the docs or remove the model — never
# leave a documented route broken.
set -u

DIR="$HOME/dotfiles/claude"
RUN="$DIR/bin/model-run.sh"
DRIFT="$DIR/bin/catalog-drift.sh"
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
declare -a WARNINGS=()

ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1${2:+ — $2}"; FAILURES+=("$1"); }
warn() { echo "WARN  $1${2:+ — $2}"; WARNINGS+=("$1"); }   # advisory: never fails the suite

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
expect_allow "grep 'codex exec' $RUN" "grep mentioning codex exec"
expect_allow 'ls -la && git status' "unrelated command"

# ---------- Tier 0.5: mock-backend tests of model-run.sh error taxonomy ----------
# PATH-shimmed fake codex/cursor-agent binaries — deterministic, zero tokens,
# no network. This is the fake-injection seam: failure modes (auth, transport,
# retry, prose false-positives) are provable without a live outage.
MOCKBIN="$WORK/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/codex" <<'MOCK'
#!/usr/bin/env bash
# Catalog reads (used by the catalog-drift unit tests): a fake future catalog —
# grok 4.7 / gpt-5.7 exist, cursor-grok-4.5-low is gone. MOCK_MODE=catalog-down
# simulates a logged-out/broken CLI for the fail-open test.
[ "${MOCK_MODE:-ok}" = catalog-down ] && { echo "Not logged in"; exit 1; }
if [ "${1:-}" = "--list-models" ]; then
  printf 'Available models\n\nauto - Auto (default)\n'
  for id in cursor-grok-4.7-high cursor-grok-4.7-xhigh cursor-grok-4.6-high cursor-grok-4.6-high-fast \
            cursor-grok-4.6-xhigh cursor-grok-4.6-medium cursor-grok-4.6-low cursor-grok-4.5-high \
            cursor-grok-4.5-high-fast cursor-grok-4.5-medium composer-2.5 composer-2.5-fast glm-5.2-high glm-5.2-max; do
    echo "$id - Mock"; done; exit 0
fi
if [ "${1:-}" = "debug" ]; then
  echo '{"models":[{"slug":"gpt-5.7-sol","visibility":"list"},{"slug":"gpt-5.6-sol","visibility":"list"},{"slug":"gpt-5.6-terra","visibility":"list"},{"slug":"gpt-5.6-luna","visibility":"list"},{"slug":"gpt-5.5","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}'; exit 0
fi
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
mock_run() { # $1 MOCK_MODE, $2 model id
  MOCK_MODE="$1" MOCK_STATE="$WORK/mockstate-$1-$2" MODEL_RUN_RETRY_DELAY=0 \
    PATH="$MOCKBIN:$PATH" "$RUN" "$2" "$PROMPTFILE" "$WORK" >/dev/null 2>&1; echo $?
}
[ "$(mock_run ok gpt-5.6-terra)" = 0 ]         && ok "mock:success-passthrough" || bad "mock:success-passthrough"
[ "$(mock_run auth gpt-5.6-terra)" = 75 ]      && ok "mock:auth->75" || bad "mock:auth->75"
[ "$(mock_run auth composer-2.5)" = 75 ]       && ok "mock:auth->75(cursor)" || bad "mock:auth->75(cursor)"
[ "$(mock_run transport gpt-5.6-terra)" = 73 ] && ok "mock:transport->73-after-retry" || bad "mock:transport->73-after-retry"
[ "$(mock_run flaky gpt-5.6-terra)" = 0 ]      && ok "mock:transient-retry-recovers" || bad "mock:transient-retry-recovers"
[ "$(mock_run quote-ok gpt-5.6-terra)" = 0 ]   && ok "mock:prose-quote-no-false-positive" || bad "mock:prose-quote-no-false-positive"
# catalog-drift detector against the fake future catalog above (zero tokens, no network)
mock_drift=$(CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1); mock_drift_st=$?
[ "$mock_drift_st" = 1 ] \
  && grep -q $'^newer\t.*cursor-grok-4.7-\*.*stops at cursor-grok-4.6' <<<"$mock_drift" \
  && grep -q $'^newer\t.*gpt-5.7-\*.*stops at gpt-5.6' <<<"$mock_drift" \
  && grep -q $'^vanished\t.*cursor-grok-4.5-low' <<<"$mock_drift" \
  && ! grep -q 'glm\|composer' <<<"$mock_drift" \
  && ok "mock:catalog-drift-detects-newer+vanished" \
  || bad "mock:catalog-drift-detects-newer+vanished" "exit $mock_drift_st: $(printf '%s' "$mock_drift" | tr '\n' '|')"
mock_nodrift=$(MOCK_MODE=catalog-down CATALOG_DRIFT_CACHE_DIR="$WORK/mock-drift-cache2" PATH="$MOCKBIN:$PATH" bash "$DRIFT" 2>&1); mock_nodrift_st=$?
[ "$mock_nodrift_st" = 2 ] && grep -q $'^unavailable\t' <<<"$mock_nodrift" && ! grep -q $'^newer\|^vanished' <<<"$mock_nodrift" \
  && ok "mock:catalog-drift-fail-open-when-catalogs-down" \
  || bad "mock:catalog-drift-fail-open-when-catalogs-down" "exit $mock_nodrift_st: $(printf '%s' "$mock_nodrift" | tr '\n' '|')"

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
# POSITIVE --task-type arg parsing, zero-token: with a nonexistent prompt file
# the script must fail on "prompt file missing" (proving promptfile/workdir are
# read from the right positions), NOT fall through to the usage error.
# Regression for the shift-2 positional bug (2026-07-23, found by another agent).
while IFS=$'\t' read -r _ tt _; do
  err=$("$RUN" --task-type "$tt" /nonexistent/routecheck-probe.md 2>&1)
  case "$err" in
    *"prompt file missing"*) ok "args:task-type-$tt" ;;
    *) bad "args:task-type-$tt" "expected prompt-file error, got: $(printf '%s' "$err" | head -1)" ;;
  esac
done < <(awk -F'\t' '$1=="task"' "$TABLE")

# ---------- Tier 1.5: live catalog drift (zero tokens) ----------
# bin/catalog-drift.sh: Cursor --list-models + Codex debug models vs routes.tsv.
#   vanished id  -> FAIL (the route will hard-error or silently remap)
#   newer family -> WARN (e.g. cursor-grok-4.7-* appeared; routes.tsv stops at 4.6 —
#                   nothing is broken, but add the rows + update the docs)
#   unavailable  -> WARN (fail-open; auth tier above already flags login rot)
drift_out=$(bash "$DRIFT" 2>&1); drift_st=$?
drift_found=0
while IFS=$'\t' read -r kind msg; do
  case "$kind" in
    vanished)    bad  "drift:vanished" "$msg"; drift_found=1 ;;
    newer)       warn "drift:newer" "$msg (add rows to bin/routes.tsv, update model-selection.md/model-usage.md, rerun routecheck)"; drift_found=1 ;;
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
  rm -rf "$WORK"
  [ "${#WARNINGS[@]}" -gt 0 ] && echo "WARNINGS (advisory, not failures): ${WARNINGS[*]}"
  [ "${#FAILURES[@]}" -eq 0 ] && { echo "FREE TIERS OK (live smokes skipped; route-health.txt untouched)"; exit 0; }
  echo "FAILURES (free tiers): ${FAILURES[*]}"; exit 1
fi
mapfile -t MODELS < <(awk -F'\t' '$1=="model"{print $2}' "$TABLE")
for m in "${MODELS[@]}"; do
  "$RUN" "$m" "$PROMPTFILE" "$WORK" >"$OUT/$m.txt" 2>&1 &
done
timeout 300 claude -p --model haiku "$(cat "$PROMPTFILE")" >"$OUT/claude-haiku.txt" 2>&1 &
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
  echo "Create a file named artifact.txt in the current working directory containing exactly this line and nothing else: $NONCE — then output DONE." > "$af"
  "$RUN" "$m" "$af" "$ad" >"$OUT/artifact-$be.txt" 2>&1 &
done
wait

for m in "${MODELS[@]}"; do
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

rm -rf "$WORK"
[ "${#WARNINGS[@]}" -gt 0 ] && echo "WARNINGS (advisory, not failures): ${WARNINGS[*]}"
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "$TODAY ok" > "$HEALTH"
  echo "ALL ROUTES OK"
  exit 0
fi
echo "$TODAY FAIL ${FAILURES[*]}" > "$HEALTH"
echo "ROUTE FAILURES — fix bin/routes.tsv / model-usage.md / model-selection.md (or remove the entry)"
exit 1
