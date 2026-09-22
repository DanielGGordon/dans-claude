// Orchestration smoke — non-Claude path. Proves a Workflow can delegate through
// the model-runner named agent (agentType: 'model-runner' -> bin/model-run.sh)
// for the preferred ids AND every --task-type, with 11 runners in parallel —
// which is exactly the shape that exposed the shared-temp-file cross-talk bug
// on 2026-08-24. A pass requires BOTH the nonce echo and a `MODEL: <resolved id>`
// line. ~120k subagent tokens, ~70s. Run from a Claude Code session:
//   Workflow({ scriptPath: '~/dotfiles/claude/tests/workflows/orchestration-smoke-model-runner.js',
//              args: { repo: '<checkout>' } })   // nonce: per-run random by default
// Re-run after every Claude Code, Codex CLI, or Cursor CLI update, and after
// editing agents/model-runner.md or bin/routes.tsv. Keep IDS/TASKS in sync
// with bin/routes.tsv `task` rows + the models model-selection.md recommends.
//
// Test-chat hygiene (2026-09-22): runners used to be told "Workdir: /tmp", so
// every run left 11 Codex threads + Cursor chats under /tmp that could never be
// told apart from real ones. Now a Setup agent makes ONE throwaway mktemp
// workdir, runners use it with MODEL_RUN_EPHEMERAL=1 (codex --ephemeral), and
// a Cleanup agent runs bin/test-chat-cleanup.sh for that workdir + the nonce
// (Cursor has no ephemeral mode) and removes the dir. args.repo overrides the
// checkout whose bin/ is used (default ~/dotfiles/claude) — e.g. a worktree.
export const meta = {
  name: 'orchestration-smoke-model-runner',
  description: 'Nonce echo through the preferred non-Claude models + every task type via the model-runner agent',
  phases: [
    { title: 'Setup', detail: 'throwaway workdir + start epoch' },
    { title: 'ById', detail: 'explicit model ids' },
    { title: 'ByTask', detail: '--task-type resolution' },
    { title: 'Cleanup', detail: 'delete the test chats the CLIs persisted' },
  ],
}
const REPO = (args && args.repo) || '~/dotfiles/claude'
const IDS = ['gpt-6-astra', 'gpt-6-sol', 'gpt-5.6-terra', 'composer-2.5', 'grok-4.7-high', 'glm-5.2-high']
// x-recency (grok-4.7-xsearch, the direct xAI API) is deliberately NOT here:
// grok-4.7 on the xAI API refuses "output exactly this line" nonce prompts
// (2026-09-22), and the model-runner path is the same model-run.sh call —
// tests/routecheck.sh smokes that route live with an arithmetic check instead.
const TASKS = [['bulk', 'gpt-5.6-terra'], ['cheap', 'composer-2.5'], ['recency', 'grok-4.7-high'], ['second-review', 'gpt-6-astra'], ['fable-fallback', 'gpt-6-astra']]
const SETUP = { type: 'object', properties: { workdir: { type: 'string' }, since: { type: 'integer' }, rand: { type: 'string' } }, required: ['workdir', 'since', 'rand'] }
const setup = await agent(
  'Run exactly this single Bash command and report its three output lines: ' +
  '`date +%s && W=$(mktemp -d /tmp/orch-smoke.XXXXXX) && git -C "$W" init -q && echo "$W" && od -An -N4 -tx1 /dev/urandom | tr -d " \\n"; echo`. ' +
  'Return since = the first line (integer epoch), workdir = the second line (the path) and rand = the third line (hex). Do nothing else.',
  { label: 'setup', phase: 'Setup', model: 'haiku', effort: 'low', schema: SETUP })
if (!setup || !/^\/tmp\/orch-smoke\.[A-Za-z0-9]+$/.test(setup.workdir || '') || !/^[0-9a-f]{8}$/.test(setup.rand || '')) {
  return { verdict: 'FAIL', passed: 0, total: IDS.length + TASKS.length, results: [], error: `setup failed: ${JSON.stringify(setup)}` }
}
const WORKDIR = setup.workdir
// The nonce doubles as test-chat-cleanup's --marker, which deletes any chat
// created since `since` whose first message contains it — so it must be unique
// per run. A fixed default ('ORCH-MR-SMOKE') would match an overlapping run's
// or a real session quoting it (review finding 2026-09-22).
const NONCE = (args && args.nonce) || `ORCH-MR-${setup.since}-${setup.rand}`
const prompt = (sel, tag) =>
  `Run this on ${sel}. Inline prompt text (materialize it to a temp file first): "Output exactly this line and nothing else: ${NONCE}-${tag}". ` +
  `Workdir: ${WORKDIR}. This is a test run: invoke model-run.sh with the env prefix MODEL_RUN_EPHEMERAL=1 ` +
  `(i.e. \`MODEL_RUN_EPHEMERAL=1 bash ${REPO}/bin/model-run.sh ...\`).`
const check = (text, expectId, tag) => ({
  tag, expectId,
  modelLine: (text || '').split('\n').find(l => l.startsWith('MODEL:')) || null,
  echoed: (text || '').includes(`${NONCE}-${tag}`),
  ok: !!text && text.includes(`${NONCE}-${tag}`) && text.includes(`MODEL: ${expectId}`),
  tail: (text || '').slice(-200),
})
const byId = await pipeline(IDS,
  id => agent(prompt(`model id ${id}`, id), { agentType: 'model-runner', label: `id:${id}`, phase: 'ById' }),
  (text, id) => check(text, id, id))
const byTask = await pipeline(TASKS,
  ([tt]) => agent(prompt(`task type ${tt}`, tt), { agentType: 'model-runner', label: `task:${tt}`, phase: 'ByTask' }),
  (text, [tt, expect]) => check(text, expect, tt))
const all = [...byId, ...byTask].filter(Boolean)
const passed = all.filter(r => r.ok).length
const total = IDS.length + TASKS.length
log(`model-runner path: ${passed}/${total} passed`)
// Always runs, pass or fail: the runners have already created whatever they created.
const cleanup = await agent(
  'Run exactly this single Bash command and return its full output verbatim (stdout and stderr), nothing else: ' +
  `\`bash ${REPO}/bin/test-chat-cleanup.sh --since ${setup.since} --marker '${NONCE}' --workdir '${WORKDIR}' 2>&1; ` +
  `st=$?; rm -rf '${WORKDIR}'; echo "cleanup-exit=$st"\``,
  { label: 'cleanup', phase: 'Cleanup', model: 'haiku', effort: 'low' })
log(`cleanup: ${(cleanup || 'cleanup agent failed').split('\n').filter(l => /deleted|note|exit/.test(l)).join(' | ')}`)
return { verdict: passed === total ? 'ALL OK' : 'FAIL', passed, total, results: all, workdir: WORKDIR, cleanup }
