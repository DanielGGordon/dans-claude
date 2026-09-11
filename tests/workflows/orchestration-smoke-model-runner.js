// Orchestration smoke — non-Claude path. Proves a Workflow can delegate through
// the model-runner named agent (agentType: 'model-runner' -> bin/model-run.sh)
// for the preferred ids AND every --task-type, with 9 runners in parallel —
// which is exactly the shape that exposed the shared-temp-file cross-talk bug
// on 2026-08-24. A pass requires BOTH the nonce echo and a `MODEL: <resolved id>`
// line. ~100k subagent tokens, ~70s. Run from a Claude Code session:
//   Workflow({ scriptPath: '~/dotfiles/claude/tests/workflows/orchestration-smoke-model-runner.js',
//              args: { nonce: 'ORCH-MR-<date>' } })
// Re-run after every Claude Code, Codex CLI, or Cursor CLI update, and after
// editing agents/model-runner.md or bin/routes.tsv. Keep IDS/TASKS in sync
// with bin/routes.tsv `task` rows + the models model-selection.md recommends.
export const meta = {
  name: 'orchestration-smoke-model-runner',
  description: 'Nonce echo through the preferred non-Claude models + every task type via the model-runner agent',
  phases: [{ title: 'ById', detail: 'explicit model ids' }, { title: 'ByTask', detail: '--task-type resolution' }],
}
const NONCE = (args && args.nonce) || 'ORCH-MR-SMOKE'
const IDS = ['gpt-5.6-terra', 'gpt-5.6-sol', 'gpt-6-astra', 'composer-2.5', 'cursor-grok-4.6-high', 'glm-5.2-high']
const TASKS = [['bulk', 'gpt-5.6-terra'], ['cheap', 'composer-2.5'], ['recency', 'cursor-grok-4.6-high'], ['second-review', 'gpt-5.6-sol']]
const prompt = (sel, tag) =>
  `Run this on ${sel}. Inline prompt text (materialize it to a temp file first): "Output exactly this line and nothing else: ${NONCE}-${tag}". Workdir: /tmp.`
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
return { verdict: passed === total ? 'ALL OK' : 'FAIL', passed, total, results: all }
