# Ralph

Ralph is a task-by-task plan executor for Claude Code. It reads a markdown plan file, dispatches each unchecked task to a fresh `claude -p` subprocess with zero context carryover, and checks tasks off as they complete. A learnings file accumulates gotchas across iterations so each fresh context window inherits institutional knowledge.

Named after Ralph Wiggum — he's doing his best.

## How It Works

![Ralph Execution Flow](diagrams/execution-flow.png)

## TUI Interface

Ralph runs as a Textual terminal app with three regions:

![Ralph TUI Layout](diagrams/tui-layout.png)

### Commands

| Command    | Description                                     |
|------------|-------------------------------------------------|
| `/skip`    | Kill current task, move to next                 |
| `/stop`    | Kill current task, stash changes, exit           |
| `/kill`    | Kill current task, stash changes, pause          |
| `/pause`   | Pause after current task finishes                |
| `/resume`  | Unpause, pop stash, move to next task            |
| `/retry`   | Unpause, pop stash, re-run same task             |
| `/plan`    | Show plan progress                               |
| `/help`    | Show command help                                |

Type anything else to queue guidance for the next task.

### State Machine

![Ralph State Machine](diagrams/state-machine.png)

## Usage

### Via Claude Code skill

```
/ralph                          # auto-find plan.md
/ralph path/to/plan.md          # explicit plan
/ralph plan.md --model sonnet   # use Sonnet
```

### Direct invocation

```bash
python3 ~/.claude/skills/ralph/ralph.py [plan_path] [options]
```

### Options

| Flag              | Default | Description                              |
|-------------------|---------|------------------------------------------|
| `--dry-run`       | off     | Preview tasks without running claude      |
| `--delay`         | 5       | Seconds between tasks                    |
| `--batch`         | off     | Execute `<!-- BATCH -->` groups together |
| `--review`        | off     | Code review after each task              |
| `--model`         | —       | Model preset or raw model ID             |
| `--reviewer`      | auto    | Reviewer: `auto`, `codex`, or `claude`   |
| `--task-timeout`  | 3600    | Kill stuck tasks after N seconds (0 to disable) |

Environment variables: `RALPH_MODEL`, `RALPH_DELAY`, `RALPH_REVIEWER`, `RALPH_TASK_TIMEOUT`.

### Model Presets

| Preset        | Model              | Effort |
|---------------|--------------------|--------|
| `opus-max`    | Claude Opus 4.6    | max    |
| `opus-high`   | Claude Opus 4.6    | high   |
| `opus-med`    | Claude Opus 4.6    | medium |
| `opus`        | Claude Opus 4.6    | —      |
| `sonnet-high` | Claude Sonnet 4.6  | high   |
| `sonnet`      | Claude Sonnet 4.6  | —      |
| `haiku`       | Claude Haiku 4.5   | —      |

## Plan Format

Plans are standard markdown with checkbox tasks:

```markdown
# My Plan

## System Tools & Dependencies
- Python 3, pytest, git

## Phase 1: Setup
- [ ] Verify dependencies are installed — _Criterion: commands exit 0_

## Phase 2: Build
- [ ] Create the widget — _Criterion: tests pass, committed_
- [ ] Add error handling — _Criterion: edge cases covered_

## Phase 3: Polish
- [ ] Write documentation — _Criterion: README exists_
```

### Task format

```
- [ ] Task description — _Criterion: what success looks like_
```

The criterion after the em dash tells the agent how to verify completion. If omitted, Ralph defaults to "Task is complete and working correctly."

### Batch tasks

Mark consecutive tasks for single-shot execution:

```markdown
<!-- BATCH -->
- [ ] Task A — criterion
- [ ] Task B — criterion
- [ ] Task C — criterion
```

All three run in one `claude -p` invocation with `--batch`.

## Guidance

Three ways to send guidance to the next task:

1. **TUI input** — type in the input bar, hit enter
2. **Inbox file** — `echo "use the new API" > .ralph-inbox` from any terminal
3. **During countdown** — type while the countdown timer is running

## Learnings File

Ralph automatically maintains a learnings file alongside your plan. If your plan is `plans/my-project.md`, the learnings file will be `plans/my-project-learnings.md`.

**How it works:**
- Each task prompt includes the full learnings file, so every fresh context window sees gotchas from prior iterations
- Claude is instructed to append a learning only when it discovers something surprising — a workaround, environment quirk, non-obvious dependency, or dead end worth avoiding
- Ralph also appends a fallback one-liner (task name + timestamp + pass/fail) as a safety net if Claude forgets

**Example entries:**
```
[done 2026-03-23 14:30] Set up auth middleware. ⚠️ Learning: bcrypt rounds must be ≥12 on this ARM host or tests timeout
[FAILED 2026-03-23 14:45] Add rate limiting
[done 2026-03-23 15:10] Add rate limiting. ⚠️ Learning: redis must be running locally — tests don't mock it
```

The file is append-only. Delete it between projects or when it gets stale.

## Task Timeout & Auto-Rescue

Ralph monitors how long each task has been running (visible in the status bar). If a task exceeds the timeout (default: 1 hour), Ralph:

1. Kills the stuck agent process
2. **Keeps all code changes** in the working tree (no stash, no revert)
3. Launches a fresh "rescue" agent with context about what happened
4. The rescue agent runs `git diff`/`git status`, assesses the partial work, and finishes (or restarts) the task

If the rescue agent also fails or times out, Ralph counts it as a failure and moves on.

Configure with `--task-timeout <seconds>` or `RALPH_TASK_TIMEOUT`. Set to `0` to disable.

## Gemini Fallback (Review Only)

If Claude hits a usage or rate limit during the **review step**, Ralph automatically retries the review using Gemini CLI (`gemini -p "" --yolo`).

If Claude hits a usage limit during **task execution**, Ralph stops the loop — there's no point continuing without the primary model.

Requires [Gemini CLI](https://github.com/google-gemini/gemini-cli) to be installed and authenticated.

## Log File

All TUI output is mirrored to a log file alongside your plan. If your plan is `plans/my-project.md`, the log is `plans/my-project-ralph.log`.

- Every line is timestamped (`[HH:MM:SS] ...`)
- The log persists across runs (append mode) so you have a complete history
- Includes tool calls, agent output, task results, cost, and the final summary
- When Ralph terminates, the log file path is printed in the final summary

## Failure Handling

- If a task fails (not checked off after execution), Ralph moves on and increments a counter
- After 3 consecutive failures, Ralph stops — fix the issue manually, then re-run
- Re-running Ralph picks up from the first unchecked task automatically
- `/kill` + `/retry` lets you re-run a task with guidance after reviewing what went wrong

## Dependencies

- Python 3
- [Textual](https://github.com/Textualize/textual) (`pip install textual`)
- Claude Code CLI (`claude`)
