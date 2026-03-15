# Plan Review Requirements

A plan is only approvable if it satisfies ALL of the following requirements.

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

## 4. Agent-Loop Compatible Task Lists

The plan must include one or more structured task lists suitable for execution by an automated agent loop. This means:

- Tasks are discrete, unambiguous, and independently actionable.
- Each task has a clear completion criterion (how do you know it's done?).
- Tasks are granular enough that an agent can execute one at a time without ambiguity.
- If the plan has narrative prose but no structured task list, it fails this requirement.

---

## 5. Parallelism

Within the task list(s), tasks that can be executed concurrently must be explicitly marked. Use any consistent notation such as `[PARALLEL]`, a `parallel: true` field, or grouping under a "Can run in parallel" heading.

If the plan has no parallel markers at all, the reviewer must analyze the task list and identify which tasks have no dependencies on each other and could safely run concurrently. If any are found, the plan fails this requirement and must be revised to mark them.

---

## 6. Task List Completeness

The task list(s) must cover the full lifecycle of the work:

- **Setup**: Environment setup, dependency installation, credential/tool provisioning.
- **Development**: Feature implementation, schema changes, configuration, etc.
- **Testing**: Running the test suite, verifying results.
- **Deployment**: Build, deploy, post-deploy verification (smoke test, health check).

A plan that only covers development tasks and omits setup, testing, or deployment tasks fails this requirement.
