// Orchestration smoke — native Claude path. Proves Workflow agent({model}) +
// pipeline() reach every Claude tier (haiku/sonnet/opus/fable) and that each
// returns structured output. ~50k subagent tokens, ~3s. Run from a Claude Code
// session (workflows only exist inside the harness):
//   Workflow({ scriptPath: '~/dotfiles/claude/tests/workflows/orchestration-smoke-claude.js',
//              args: { nonce: 'ORCH-<date>' } })
// Re-run after every Claude Code update or Claude model change.
export const meta = {
  name: 'orchestration-smoke-claude',
  description: 'Nonce echo through every native Claude model tier via agent({model}) + pipeline()',
  phases: [{ title: 'Echo', detail: 'one agent per Claude model tier' }, { title: 'Check', detail: 'plain-code nonce comparison' }],
}
const NONCE = (args && args.nonce) || 'ORCH-SMOKE'
const MODELS = ['haiku', 'sonnet', 'opus', 'fable']
const SCHEMA = { type: 'object', properties: { echo: { type: 'string' } }, required: ['echo'] }
const results = await pipeline(
  MODELS,
  m => agent(`Do not use any tools. Return exactly this string in the echo field and nothing else: ${NONCE}-${m}`,
             { model: m, effort: 'low', label: `echo:${m}`, phase: 'Echo', schema: SCHEMA }),
  (r, m) => ({ model: m, ok: r?.echo === `${NONCE}-${m}`, got: r?.echo ?? null })
)
const passed = results.filter(r => r && r.ok).length
log(`native Claude tiers: ${passed}/${MODELS.length} echoed the nonce`)
return { verdict: passed === MODELS.length ? 'ALL OK' : 'FAIL', passed, total: MODELS.length, results }
