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

## Interactive features

- **Inbox:** `echo "guidance" > .ralph-inbox` from any terminal, any time
- **Countdown:** type during the pause between tasks to add guidance
- **Follow-up:** ralph detects when an agent asks a question and pauses for you
- **Commands:** `skip` (skip task), `stop` (end loop), Enter (proceed), or any text (guidance)

## Stopping and resuming

Ctrl+C stashes uncommitted changes. Next run picks up from the first unchecked task.
