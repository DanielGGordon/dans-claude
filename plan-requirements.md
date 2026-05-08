# Plan Review Requirements

A plan is only approvable if it satisfies ALL of the following requirements.

## Plan styles accepted

Two plan styles are recognized. **Either** style may be used; reviewers must apply the appropriate variant of each requirement based on which style the plan declares (or which it most clearly resembles).

- **v1 — Task-list style.** Plans decomposed into discrete checkboxed tasks (`- [ ]` / `- [x]`). Each task has a completion criterion. Designed for the original Ralph loop, which dispatches one task per subagent invocation. Granularity is at the task level.
- **v2 — Phase + acceptance-criteria style.** Plans organized into vertical-slice phases. Each phase has a `**Delivers**:` paragraph and explicit, testable `**Acceptance criteria**:` bullets. Designed for Ralph v2, which dispatches one *phase* per generator + evaluator pair — the generator decides how to implement; the evaluator independently tests each acceptance criterion. Granularity is at the phase level. **Implementation steps are intentionally omitted.** Phase-level parallelism is marked with `<!-- PARALLEL N,M,... -->` comments. Plans produced by the `prd-to-plan` skill are v2.

A plan that mixes the two styles must satisfy both variants for the relevant sections.

---

## 1. Testing Strategy

The plan must include a dedicated testing section that specifies:

- **Test framework(s)**: Name the specific testing framework(s) and libraries to be used (e.g., Jest, Pytest, Playwright, Cypress, Vitest). "We will write tests" is not sufficient.
- **Types of tests**: Indicate which types of tests apply (unit, integration, end-to-end, smoke, contract, etc.) and what each covers.
- **Test coverage targets or rationale**: What is being tested and why.

---

## 2. System Tools and External Dependencies for Testing

The plan must enumerate any system-level tools or external services required to run the test suite. This includes but is not limited to:

- Browser automation tools (Playwright, Puppeteer, Selenium, etc.)
- Cloud service accounts (AWS, GCP, Azure, Vercel, etc.)
- Local infrastructure (Docker, database instances, mock servers)
- API keys or credentials required during testing
- Any CLI tools that must be installed

For each, state whether it needs to be provisioned once (initial setup) or is required on every test run.

---

## 3. Human-in-the-Loop Policy

The testing strategy must be fully automated and executable without human intervention during a test run. Specifically:

- **No manual steps during tests**: No "manually verify X", "click the button and confirm", or similar.
- **Human steps are allowed ONLY for initial one-time setup** (e.g., creating an AWS account, generating an API key, approving a certificate). These must be:
  - Explicitly listed as a separate "Initial Setup (Human Required)" section or clearly labeled step.
  - Each step must state: what action is required, who performs it, and when (one-time vs. recurring).
- If the plan has zero human steps, it must say so explicitly.

---

## 4. Agent-Loop Compatible Work Units

The plan must expose work units that an automated agent loop can execute. Apply the variant matching the plan's declared style:

**v1 (task-list) variant**: The plan must include one or more structured task lists. Tasks are discrete, unambiguous, and independently actionable. Each task has a clear completion criterion (how do you know it's done?). Tasks are granular enough that an agent can execute one at a time without ambiguity. Narrative prose without a structured task list fails this requirement.

**v2 (phase + acceptance-criteria) variant**: The plan must include one or more phases. Each phase has a `**Delivers**:` paragraph describing the demoable outcome and a `**Acceptance criteria**:` bullet list. Each acceptance criterion must be **independently testable by an evaluator agent** — concrete, observable, and unambiguous. "Implements X correctly" or "is well designed" fails. "GET /foo returns 200 with a JSON body containing `bar`" passes. Implementation steps must NOT be enumerated; the v2 generator decides implementation. Phases must cut vertically through layers (not be horizontal slices of one layer).

---

## 5. Parallelism

Apply the variant matching the plan's declared style:

**v1 variant**: Within the task list(s), tasks that can be executed concurrently must be explicitly marked. Use any consistent notation such as `[PARALLEL]`, a `parallel: true` field, or grouping under a "Can run in parallel" heading. If the plan has no parallel markers at all, the reviewer must analyze the task list and identify tasks with no dependencies on each other; if any are found, the plan fails this requirement.

**v2 variant**: Phases that can be executed concurrently (no data dependencies, no shared state mutations, independent vertical slices) must be marked with `<!-- PARALLEL N,M,... -->` comments before the first phase in the parallel group. Per-task parallel markers within a phase are NOT required (and must NOT be added) — the v2 generator decides intra-phase concurrency. If the plan has more than one phase, it must either have at least one `<!-- PARALLEL ... -->` group OR include a brief justification of why all phases are strictly sequential.

---

## 6. Lifecycle Completeness

The plan must cover the full lifecycle of the work, regardless of style:

- **Setup**: Environment setup, dependency installation, credential/tool provisioning. v1 plans express this as setup tasks; v2 plans express it as a top-level `## Initial Setup (Human Required)` section listing each one-time human action plus a top-level enumeration of system tools and external dependencies (see Requirement 2). v2 plans must explicitly state that during a normal test run there are zero human steps.
- **Development**: Feature implementation, schema changes, configuration, etc. v1: tasks. v2: phases.
- **Testing**: Running the test suite, verifying results. Coverage targets, layered strategy (unit/integration/E2E), and what is intentionally NOT tested must be stated.
- **Deployment**: Build, deploy, post-deploy verification (smoke test, health check), and rollback. v1: deployment tasks. v2: a top-level `## Deployment` section describing the deploy pipeline at the same level of concreteness as the phases.

A plan that omits any of these phases of the lifecycle fails this requirement.
