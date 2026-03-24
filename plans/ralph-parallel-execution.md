# Plan: Ralph Parallel Phase Execution

> Source PRD: Conversation-driven design (grill-me session, 2026-03-24)

## Architectural decisions

Durable decisions that apply across all phases:

- **Plan syntax**: `<!-- PARALLEL 5,6,7 -->` comment placed before the first phase in a parallel group. Comma-separated phase numbers. Multiple parallel groups per plan are supported.
- **CLI flag**: `--phase N` restricts Ralph to tasks under `## Phase N:` header only. Exits when that phase's tasks are done.
- **Worktree convention**: `git worktree add <repo>-ralph-phase-N ralph/phase-N` — one branch per parallel phase, branched from current main HEAD.
- **Learnings**: single file in the main repo (not worktrees). All parallel instances share it via `--learnings-path` flag. Access protected by `fcntl.flock` with 1s blocking wait.
- **Merge strategy**: first phase to finish merges into main immediately. Subsequent finishers rebase onto updated main before merging. Conflicts handled by a Claude agent with context about both phases.
- **Tmux session**: `ralph-parallel` session with one window per phase, each running a full Ralph TUI instance. Main Ralph prints attach command and blocks until all finish.
- **Target file**: `~/dotfiles/claude/skills/ralph/ralph.py`

---

## Phase 1: `--phase N` flag and phase-scoped task filtering

### What to build

Add a `--phase` CLI argument to Ralph. When set, Ralph only executes tasks that fall under the matching `## Phase N:` heading (any heading matching `## Phase <N>` with optional title suffix). Tasks outside that phase are invisible — `find_next_task` skips them. When all tasks in the target phase are complete, Ralph exits normally with its summary.

Add a `phase` field to `Config`. In `parse_args`, wire up the new `--phase` argument. Modify `find_next_task` to accept an optional `phase` parameter — when set, it tracks which `## Phase` heading it's under and only returns tasks within the matching phase.

### Acceptance criteria

- [x] `--phase` argument added to argparse and `Config` dataclass — _Criterion: `ralph.py --help` shows the flag_
- [ ] `find_next_task` respects phase filtering — only returns tasks under the target phase header — _Criterion: unit test with multi-phase plan, `--phase 2` only yields phase 2 tasks_
- [ ] `count_tasks` respects phase filtering so status bar shows correct counts — _Criterion: count_tasks with phase filter returns only that phase's task counts_
- [ ] Ralph exits cleanly when phase tasks are done (not when ALL tasks are done) — _Criterion: `--phase 1 --dry-run` on a 3-phase plan completes after phase 1 tasks_

---

## Phase 2: Parallel group parsing

### What to build

Parse `<!-- PARALLEL 5,6,7 -->` annotations in plan files. Add functions to detect whether a given task line falls inside a parallel group, and to extract the full list of phase numbers from that group. The annotation appears on its own line before the first `## Phase N:` heading in the group.

### Acceptance criteria

- [ ] `parse_parallel_group(plan_path, task_line) -> list[int] | None` — returns phase numbers if task is in a parallel group, None otherwise — _Criterion: unit tests cover: task in parallel group, task not in group, multiple groups in one plan_
- [ ] `find_parallel_phases(plan_path) -> list[list[int]]` — returns all parallel groups in the plan — _Criterion: unit test parses plan with two `<!-- PARALLEL -->` annotations_
- [ ] Parsing handles edge cases: spaces in comment, phases that don't exist, already-completed parallel phases — _Criterion: unit tests pass for malformed/edge inputs_

---

## Phase 3: Locked learnings file

### What to build

Replace bare file I/O in `load_learnings` and `append_learning` with `fcntl.flock`-based locking so multiple Ralph instances can safely read/write the same learnings file concurrently. Add a `--learnings-path` CLI flag that overrides the auto-derived path (worktree instances use this to point at the main repo's learnings file).

### Acceptance criteria

- [ ] `append_learning` acquires an exclusive `fcntl.flock` before writing, with a 1-second blocking wait — _Criterion: code review confirms lock/unlock pattern_
- [ ] `load_learnings` acquires a shared lock before reading — _Criterion: code review confirms shared lock_
- [ ] `--learnings-path` flag added to argparse and Config — _Criterion: `ralph.py --help` shows the flag, and passing it overrides the auto-derived path_
- [ ] Concurrent append test: two threads appending 50 entries each produce exactly 100 entries with no corruption — _Criterion: test passes_

---

## Phase 4: Worktree and tmux orchestration

### What to build

In the main `_run_tasks` loop, before dispatching a task, check if it belongs to a parallel group. If yes, orchestrate parallel execution:

1. Create N git worktrees (one per phase in the group), each on a new branch from current HEAD
2. Copy the plan file into each worktree (or use an absolute path to the original)
3. Launch a tmux session (`ralph-parallel`) with N windows, each running `ralph.py <plan> --phase N --learnings-path <main-repo-learnings>` in its worktree directory
4. Output the `tmux attach -t ralph-parallel` command to the TUI log
5. Block (poll) until all tmux windows/processes have exited
6. After all finish, proceed to merge (Phase 5) then continue the main loop

The main Ralph TUI should update its status bar to show `Parallel: N phases running` while waiting.

### Acceptance criteria

- [ ] Worktree creation: `git worktree add` for each phase, branching from current HEAD — _Criterion: worktrees exist and are on correct branches_
- [ ] Tmux session launched with correct window names and commands — _Criterion: `tmux list-windows -t ralph-parallel` shows one window per phase_
- [ ] Plan file is accessible from each worktree (absolute path or copied) — _Criterion: ralph.py in worktree can read the plan_
- [ ] Main Ralph blocks until all parallel processes finish — _Criterion: main loop resumes only after all tmux windows exit_
- [ ] Status bar shows parallel execution state — _Criterion: status shows "Parallel: N phases running, M done"_

---

## Phase 5: Merge-back with conflict resolution

### What to build

After all parallel phases finish, merge each worktree branch back into main sequentially. The first to be merged goes clean. Subsequent branches rebase onto updated main first. If a rebase hits conflicts, spawn a Claude agent (`claude -p`) with context about the conflicting phase, the other phase's changes, and the conflict markers. If the agent resolves it, continue. If it fails, stop and alert the user.

After successful merge, clean up the worktree (`git worktree remove`) and delete the branch.

### Acceptance criteria

- [ ] First finished phase merges cleanly into main — _Criterion: `git log` shows merge commit_
- [ ] Subsequent phases rebase onto updated main before merging — _Criterion: linear history on main after all merges_
- [ ] Merge conflicts trigger a Claude agent with context about both phases and the conflict diff — _Criterion: agent prompt includes phase descriptions, conflict markers, and instructions_
- [ ] Failed conflict resolution stops Ralph with a clear error message — _Criterion: user sees which files conflict and which phases clashed_
- [ ] Worktrees and branches are cleaned up after successful merge — _Criterion: `git worktree list` shows no leftover worktrees_

---

## Phase 6: Update prd-to-plan skill

### What to build

Update the `prd-to-plan` SKILL.md to instruct the planner to identify which phases are independent and can run in parallel, and to emit `<!-- PARALLEL N,M,... -->` annotations in the generated plan. Add guidance about when phases qualify as parallel (no data dependencies, no shared state mutations, independent vertical slices).

### Acceptance criteria

- [ ] SKILL.md vertical-slice-rules section updated with parallel phase guidance — _Criterion: instructions mention independence criteria and the PARALLEL annotation syntax_
- [ ] Plan template includes an example of `<!-- PARALLEL -->` usage — _Criterion: template shows the annotation in context_
- [ ] Planner is instructed to decide autonomously (not ask the user) which phases are parallelizable — _Criterion: instructions say to determine independently, not quiz the user about it_
