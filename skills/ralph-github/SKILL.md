---
name: ralph-github
description: Run ralph with codex/claude code review after each task. Wrapper for ralph.py --review.
user_invocable: true
arguments:
  - name: plan_path
    description: Path to the plan file (defaults to plan.md in CWD, then ~/.claude/plans/)
    required: false
---

Ralph-GitHub runs the standard ralph loop with codex review enabled after each task. It's a thin wrapper around `ralph.py --review`.

## Launch

Tell the user to run in their terminal:

```
python3 ~/dotfiles/claude/skills/ralph/ralph.py [plan_path] --review
```

Or via the wrapper:

```
bash ~/dotfiles/claude/skills/ralph-github/ralph-github.sh [plan_path]
```

## Review Pipeline (per task)

```
① Execute task (claude -p, fresh context)
② Auto-commit any uncommitted changes
③ Codex review (falls back to Claude Opus 4.6 if no codex)
④ Fix review findings (if any)
```

## Options

All ralph.sh options are supported. Key ones:

- `--delay N` — seconds for interactive countdown (default: 5)
- `--max-turns N` — max agentic turns per task (default: 50)
- `--dry-run` — preview without executing
- `--batch` — process `<!-- BATCH -->` groups as single invocations
- `--no-review` — skip the review step (overrides the wrapper's --review)
