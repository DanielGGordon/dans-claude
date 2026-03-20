---
name: ralph-github
description: Execute a plan file task-by-task with GitHub PR pipeline, codex review, and bugbot integration. Each task gets its own branch and PR.
user_invocable: true
arguments:
  - name: plan_path
    description: Path to the plan file (defaults to plan.md in CWD, then ~/.claude/plans/)
    required: false
---

Ralph-GitHub is a terminal-based plan executor with full GitHub integration. Each task gets its own branch, codex review, and PR — with automatic bugbot checking and merging between tasks.

## Launch

Tell the user to run in their terminal:

```
bash ~/dotfiles/claude/skills/ralph-github/ralph-github.sh [plan_path]
```

Or with options:

```
bash ~/dotfiles/claude/skills/ralph-github/ralph-github.sh plan.md --delay 10 --base-branch main
```

## Pipeline (per task)

```
① Branch off previous task (or master)
② Execute task (claude -p, fresh context)
③ Codex review (falls back to Claude Opus 4.6 if no codex)
④ Fix review findings
⑤ Create PR (triggers bugbot)
⑥ Check previous PR for bugbot → examine → fix → merge → rebase
```

After the last task: waits for bugbot on the final PR, fixes findings, merges.

## Options

- `--delay N` — seconds for interactive countdown (default: 5)
- `--max-turns N` — max agentic turns per task (default: 50)
- `--dry-run` — preview without executing
- `--no-review` — skip codex/claude review step
- `--no-bugbot` — skip bugbot waiting/checking
- `--base-branch NAME` — main branch name (default: master)
- `--bugbot-user NAME` — bugbot GitHub username (default: cursor[bot])
