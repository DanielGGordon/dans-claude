---
name: ralph
description: Execute a plan file task-by-task in isolated subagents, resetting context between each task. Adds checkboxes to tasks if missing, checks them off as they complete.
user_invocable: true
arguments:
  - name: plan_path
    description: Path to the plan file (defaults to plan.md in the current working directory, then checks ~/.claude/plans/)
    required: false
---

You are the Ralph loop orchestrator. Your job is to launch `ralph.py` which executes a plan file **one task at a time**, dispatching each task to a fresh `claude -p` subprocess so context doesn't accumulate.

## Prerequisites

Ralph requires the `textual` TUI framework:

```
pip install textual
```

## Launch

Tell the user to run in their terminal:

```
python3 ~/.claude/skills/ralph/ralph.py [plan_path] [options]
```

If a plan_path argument was provided to this skill, pass it through:

```
python3 ~/.claude/skills/ralph/ralph.py {plan_path}
```

## Options

All options are passed through to ralph.py:

- `--delay N` — seconds for interactive countdown (default: 5)
- `--max-turns N` — max agentic turns per task (default: 50)
- `--dry-run` — preview without executing
- `--batch` — process `<!-- BATCH -->` groups as single invocations
- `--review` — run codex/claude review after each task
- `--no-review` — skip the review step
- `--model NAME` — model preset (opus-max, opus-high, opus-med, opus, sonnet-high, sonnet, haiku) or raw model ID
- `--reviewer X` — reviewer: auto (default), codex, or claude

## What it does

1. Finds and reads the plan file (./plan.md, ./PLAN.md, or ~/.claude/plans/*.md)
2. Prints ASCII Ralph Wiggum, then shows each task with a countdown before executing
3. Launches `claude -p` per task (fresh context, no history bleed)
4. Parses stream-json output for live tool-use progress
5. Checks off tasks (`- [x]`) when complete
6. Respects `<!-- BATCH -->` markers — sends grouped tasks to a single invocation
7. Interactive features: inbox file, follow-up detection, background stdin reader

## TUI Interface

Ralph runs as a Textual TUI application with three regions: a scrolling output log, a status bar, and an input field.

- **Output log:** Task headers, tool details, success/failure messages, and agent output stream into a scrollable RichLog widget
- **Status bar:** Shows elapsed time, cost, task progress, current task name, and state (RUNNING / COUNTDOWN / PAUSED / DONE)
- **Input field:** Type text and press Enter to queue guidance for the next task, or use a slash command

## Slash commands

- `/stop` — Kill the running agent, git stash if dirty, exit
- `/skip` — Kill the running agent, move to the next task
- `/kill` or `/pause` — Kill the running agent, git stash, enter PAUSED state
- `/resume` — Pop the git stash and move to the next task
- `/retry` — Pop the git stash and re-run the same task
- `/plan` — Show current plan status with checkmarks

## Stopping and resuming

`/stop` or Ctrl+C exits cleanly. `/kill` pauses mid-run — use `/resume` or `/retry` to continue. Next run picks up from the first unchecked task.
