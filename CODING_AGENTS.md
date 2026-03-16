# Coding Agent Rules

These rules apply to every AI agent working on this project. Read and follow them completely before writing any code. They are non-negotiable.

---

## 1. Read Before You Write

Before making any changes, read:
- This file (`ALL_AGENTS.md`)
- `README.md` — project purpose, architecture, tech stack
- `PROJECT_STRUCTURE.md` — file tree, module boundaries, data flows
- Any module-level `README.md` in the directory you're about to touch

Do not guess at architecture. If a doc exists, read it.

---

## 2. Documentation Is Not Optional

### PROJECT_STRUCTURE.md
Every commit that adds, moves, or removes files or directories **must** update `PROJECT_STRUCTURE.md`. The file tree and descriptions must always reflect reality.

### README.md (root)
The root `README.md` must stay accurate. If your changes add features, change behavior, or alter the tech stack, update it. If you are unsure whether a README change is appropriate, ask the user rather than silently editing or silently leaving it stale.

### Module-level READMEs
Every module (directory containing source code) must have a `README.md` that describes:
- What the module does
- What its public interface is (key functions, classes, endpoints)
- How it relates to the rest of the project

When you modify a module, update its `README.md` to reflect the current state. When you create a new module, create a `README.md` for it before committing.

---

## 3. Commits

### Commit after every task
Each discrete unit of work gets its own commit. Do not batch unrelated changes. Do not leave uncommitted work at the end of a task.

### Commit messages must include
- A clear summary of what was implemented or changed
- What remains to be done (if working from a task list)
- Current test count and pass/fail status

### Never commit with
- Failing tests
- Linter errors you introduced
- Missing documentation updates (see section 2)
- Secrets, credentials, or API keys

---

## 4. Testing

### Write tests for everything you touch
- Every new function, class, endpoint, or code path must have tests
- Every bug fix must include a regression test that would have caught the bug
- Modified code must have its existing tests updated if behavior changed

### Run the full test suite
Run the project's test suite **before and after** your changes:
```
pytest tests/ -v
```
(Adjust the command to match the project's test runner.)

If any test fails after your changes, fix it before committing. If a pre-existing test fails before your changes, note it but do not silently ignore it.

### Test quality
- Tests must be deterministic (no flaky tests)
- Tests must not depend on external services, network access, or secrets (mock them)
- Tests must run fast enough that skipping them is never tempting

---

## 5. Code Quality

### Do not break what works
If existing tests fail after your changes, that is your problem to fix. Never commit broken code on the assumption someone else will clean it up.

### Follow existing patterns
Match the project's existing style: naming conventions, file organization, error handling patterns, logging approach. When in doubt, look at adjacent code and do what it does.

### No dead code
Do not leave commented-out code, unused imports, or unreachable branches. Remove what is not needed.

### No secrets in code
Secrets go in environment variables or secret management — never in source files, comments, commit messages, or logs.

---

## 6. Working From a Task List

If the project has a prioritized task list (in a `for-ai.md`, issue tracker, or similar):
1. Work through it in order. Do not skip ahead or invent new work unless a listed item is blocked.
2. After completing each task, update the task list to reflect the new state.
3. If a task is blocked, document why and move to the next one.

---

## 7. When You're Done

Before ending a session or handing off, confirm:
- [ ] All tests pass
- [ ] All documentation is updated (`README.md`, `PROJECT_STRUCTURE.md`, module READMEs)
- [ ] All changes are committed with proper messages
- [ ] No temporary files, debug prints, or TODO hacks left behind
- [ ] The project builds/runs cleanly
