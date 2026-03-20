# Ralph

Ralph is a task-by-task plan executor for Claude Code. It reads a markdown plan file, dispatches each unchecked task to a fresh `claude -p` subprocess with zero context carryover, and checks tasks off as they complete. The plan file on disk is the single source of truth.

Named after Ralph Wiggum — he's doing his best.

## How It Works

```
                          +------------------+
                          |    plan.md       |
                          |  - [x] Task 1   |
                          |  - [ ] Task 2  <-------- find next unchecked
                          |  - [ ] Task 3   |
                          +--------+---------+
                                   |
                                   v
                    +-----------------------------+
                    |  Build prompt               |
                    |  - task text + criterion    |
                    |  - trimmed plan context     |
                    |  - recent git commits       |
                    |  - coding agent rules       |
                    |  - user guidance (if any)   |
                    +-------------+---------------+
                                  |
                                  v
                    +-----------------------------+
                    |  claude -p (subprocess)     |
                    |  - isolated context         |
                    |  - stream-json output       |
                    |  - tool use displayed live  |
                    +-------------+---------------+
                                  |
                        +---------+---------+
                        |                   |
                        v                   v
                   Task checked?       Task still
                   - [x] on disk       unchecked
                        |                   |
                        v                   v
                   +----------+      +------------+
                   | Success  |      |  Failure   |
                   | count++  |      |  fails++   |
                   +----+-----+      +------+-----+
                        |                   |
                        |      3 in a row?  |
                        |         +---------+
                        |         v         |
                        |      STOP         |
                        v                   v
                  +------------+     next unchecked
                  | COUNTDOWN  |         task
                  | (delay s)  |
                  +-----+------+
                        |
                        v
                   next unchecked
                       task
                        |
                    all done?
                        |
                        v
                      DONE
```

## TUI Interface

Ralph runs as a Textual terminal app with three regions:

```
+--------------------------------------------------+
|                                                  |
|  Scrollable output log                           |
|  - task headers, tool calls, results             |
|  - success/failure messages                      |
|                                                  |
+--------------------------------------------------+
| status bar: time | cost | 2/5 | RUNNING | task  |
+--------------------------------------------------+
| input: type guidance or /command...              |
+--------------------------------------------------+
```

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

```
START --> RUNNING ---> COUNTDOWN ---> RUNNING --> ... --> DONE
              |             |
              +-- /kill ----+---> PAUSED
                                    |
                          /resume --+--> RUNNING (next task)
                          /retry  --+--> RUNNING (same task)
```

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

| Flag           | Default | Description                              |
|----------------|---------|------------------------------------------|
| `--dry-run`    | off     | Preview tasks without running claude      |
| `--max-turns`  | 50      | Max agentic turns per task               |
| `--delay`      | 5       | Seconds between tasks                    |
| `--batch`      | off     | Execute `<!-- BATCH -->` groups together |
| `--review`     | off     | Code review after each task              |
| `--model`      | —       | Model preset or raw model ID             |
| `--reviewer`   | auto    | Reviewer: `auto`, `codex`, or `claude`   |

Environment variables: `RALPH_MODEL`, `RALPH_MAX_TURNS`, `RALPH_DELAY`, `RALPH_REVIEWER`.

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

## Failure Handling

- If a task fails (not checked off after execution), Ralph moves on and increments a counter
- After 3 consecutive failures, Ralph stops — fix the issue manually, then re-run
- Re-running Ralph picks up from the first unchecked task automatically
- `/kill` + `/retry` lets you re-run a task with guidance after reviewing what went wrong

## Dependencies

- Python 3
- [Textual](https://github.com/Textualize/textual) (`pip install textual`)
- Claude Code CLI (`claude`)
