---
name: prd-to-plan
description: Turn a PRD into a multi-phase implementation plan using tracer-bullet vertical slices, saved as a local Markdown file in ./plans/. Use when user wants to break down a PRD, create an implementation plan, plan phases from a PRD, or mentions "tracer bullets".
---

# PRD to Plan

Break a PRD into a phased implementation plan using vertical slices (tracer bullets). Output is a Markdown file in `./plans/`.

Plans are executed by Ralph v2 -- a phase-level build/evaluate harness. Each phase gets one generator invocation (implements the whole phase) followed by an evaluator (tests against acceptance criteria). The plan describes WHAT to build; the generator decides HOW.

## Process

### 1. Confirm the PRD is in context

The PRD should already be in the conversation. If it isn't, ask the user to paste it or point you to the file.

### 2. Explore the codebase

If you have not already explored the codebase, do so to understand the current architecture, existing patterns, and integration layers.

### 3. Pick an agentic-first tech stack

Every plan should prefer technologies that make it easy for an AI agent to run, test, and deploy:

- CLI-friendly tooling (Vite, FastAPI, SQLite for dev, pytest)
- One-command dev server (`npm run dev`, `uvicorn main:app --reload`)
- Hot reload by default
- Test suites the evaluator can run without manual setup
- Simple deployment (Docker, single binary, static export)

Even at the cost of some additional complexity, prefer stacks that are agent-friendly over ones that are slightly simpler but harder to automate.

### 4. Design AI self-modification surface

Every app plan should include a surface for AI-assisted modification:

- A chat panel / command interface where users can ask for new features
- An `/ai` endpoint or command that accepts natural language requests
- The app should be easy to modify by pointing an agent at it

This makes the app its own harness -- users can iterate on it without returning to the terminal.

### 5. Identify durable architectural decisions

Before slicing, identify high-level decisions that are unlikely to change:

- Route structures / URL patterns
- Database schema shape
- Key data models
- Authentication / authorization approach
- Third-party service boundaries

These go in the plan header so every phase can reference them.

### 6. Draft vertical slices

Break the PRD into **tracer bullet** phases. Each phase is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
- Describe outcomes and acceptance criteria, NOT implementation steps
- The acceptance criteria become the evaluator's contract -- they must be testable
- Do NOT include specific file names, function names, or implementation details
- DO include durable decisions: route paths, schema shapes, data model names
- Identify which phases are independent and can run in parallel. Phases qualify as parallel when they have no data dependencies, no shared state mutations, and represent independent vertical slices. Annotate parallel groups with `<!-- PARALLEL N,M,... -->` on the line before the first phase in the group. Determine this independently -- do not ask the user which phases are parallelizable.
</vertical-slice-rules>

### 7. Quiz the user

Present the proposed breakdown as a numbered list. For each phase show:

- **Title**: short descriptive name
- **Delivers**: 1-2 sentence summary of what the user can see/use after this phase

Ask the user:

- Does the phase breakdown make sense? Anything to add/remove?

One round of feedback, not a deep interrogation. The planner fills gaps autonomously. The user's role is vision and specific requirements; the planner's role is structure and technical enhancement.

### 8. Write the plan file

Create `./plans/` if it doesn't exist. Write the plan as a Markdown file named after the feature (e.g. `./plans/user-onboarding.md`). Use the template below.

### 9. Auto-review the plan (always)

After writing the plan file, automatically validate it before returning control to the user.

`/review-plan`'s default search does not cover `./plans/` — so do not invoke that skill. Instead, run the `plan-reviewer` agent directly with the explicit path you just wrote, mirroring `/review-plan`'s logic locally. The flow:

1. Launch the `plan-reviewer` named agent with: `Review the plan at {ABSOLUTE_PLAN_PATH}`.
2. If it returns `{"ok": true}`, report `Plan written and review passed: {PLAN_PATH}` and stop.
3. If it returns `{"ok": false, "reason": "..."}`, edit the plan to address every listed issue substantively (no filler). Then re-run the agent.
4. If still failing, perform one more revision round and re-run the agent. **Cap at 2 revision rounds** — never loop more than twice.
5. If the second round still fails, report the remaining issues to the user and ask them to address them manually:
   > Plan written but still has issues after 2 auto-review rounds. Remaining feedback:
   > {reason}
   >
   > Please review and address these manually in {PLAN_PATH}.

Always use the `plan-reviewer` agent for the actual judgment — do not evaluate requirements yourself. Preserve passing sections; only modify what's needed to resolve the reviewer's feedback.

<plan-template>
# Plan: <Feature Name>

> Source: <PRD identifier or link>

## Project config

- **Tech stack**: <chosen stack -- agentic-first>
- **Eval approach**: <playwright + pytest / CLI testing / etc.>
- **AI surface**: <how the app exposes self-modification -- chat panel, /ai command, etc.>

## Architectural decisions

- **Routes**: ...
- **Schema**: ...
- **Key models**: ...
- (add/remove sections as appropriate)

---

## Phase 1: <Title>

**Delivers**: 2-3 sentence description of what this phase produces.
The user should be able to see/use something concrete after this phase.

**Acceptance criteria**:
- Criterion 1 (evaluator tests this)
- Criterion 2
- Criterion 3

**AI opportunity**: Optional. AI-integrated features to add in this phase.

---

<!-- PARALLEL 2,3 -->

## Phase 2: <Title>

**Delivers**: ...

**Acceptance criteria**:
- ...

---

## Phase 3: <Title>

**Delivers**: ...

**Acceptance criteria**:
- ...

<!-- Repeat for each phase. Use <!-- PARALLEL N,M,... --> before a group of independent phases. -->
</plan-template>

## Key differences from v1 plans

- **No checkbox tasks**: Phases describe outcomes and acceptance criteria, not implementation steps. The generator decides how to implement.
- **Acceptance criteria are the contract**: The evaluator tests each criterion independently. Make them concrete and testable.
- **Plan evolution**: Generators can write to `{plan_stem}-proposed-changes.md` to suggest changes to future phases. Ralph reads this before each phase.
- **AI self-modification**: Every plan includes a surface for AI-assisted modification.
- **Project config section**: Explicitly states tech stack, eval approach, and AI surface.
