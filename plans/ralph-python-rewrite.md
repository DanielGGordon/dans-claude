# Ralph Python Rewrite

## Problem

ralph.sh is a 900-line bash script doing JSON parsing, string manipulation, and process orchestration. Every streaming event forks jq, task parsing uses while-read loops, and process management relies on coproc/PID juggling. Python eliminates all of this natively.

## Constraints

- Must use `claude -p` subprocess (not Anthropic SDK) — user has Claude MAX subscription, not API keys
- Single file: `skills/ralph/ralph.py` (~400 lines target)
- Python 3.10+ stdlib only (json, subprocess, re, signal, threading, argparse, pathlib, time, shutil)
- Same CLI interface: `ralph.py [plan_path] [--dry-run] [--max-turns N] [--delay N] [--batch] [--review] [--reviewer X] [--model NAME]`
- Same env vars: `RALPH_MAX_TURNS`, `RALPH_DELAY`, `RALPH_MODEL`, `RALPH_REVIEWER`
- Feature parity with ralph.sh — no features cut, no features added

## Architecture

```
ralph.py
├── Config (dataclass)         — CLI args, env vars, model presets
├── Task (dataclass)           — line_num, text, criterion, checked
├── PlanFile                   — find, parse tasks, check off, trim for prompt
├── StreamParser               — read claude stream-json, emit events
├── ClaudeRunner               — subprocess.Popen, stream, collect result/cost
├── Interaction                — inbox, countdown, follow-up detection
├── Reviewer                   — codex/claude review after tasks
└── main_loop()                — orchestration, signal handling, stats
```

No classes needed for most of these — just functions grouped by concern. Dataclasses for Config and Task only.

## Key Design Decisions

1. **Stream parsing**: `for line in proc.stdout: json.loads(line)` — zero forks
2. **Task parsing**: `re.findall()` over plan text — one pass
3. **Interactive input**: `threading.Thread` for background stdin reader (same as bash's background reader, but cleaner)
4. **Signal handling**: `signal.signal(SIGINT, handler)` — stash uncommitted changes on ctrl+c
5. **Plan trimming**: Same algorithm as bash (preamble + current phase section), but with string ops instead of grep/sed
6. **Prompt building**: f-strings instead of heredocs

## Plan

- [x] **Task 1: Scaffold and CLI** — Create `skills/ralph/ralph.py`. argparse with all flags/options, model preset resolution, plan file discovery (same search order: `./plan.md`, `./PLAN.md`, `~/.claude/plans/*.md`), Config dataclass. Print banner with plan path, working dir, model info. Wire up `skills/ralph/SKILL.md` to call `ralph.py` instead of `ralph.sh`.
- [x] **Task 2: Plan parsing and trimming** — `find_next_task()` returns `Task(line_num, text, criterion)` or None. `count_tasks()` returns `(done, total)`. `check_off_task(line_num)` edits plan file in place. `collect_batch(start_line)` for `<!-- BATCH -->` groups. `trim_plan_for_task(plan_path, task_line)` returns preamble + current phase. `extract_criterion(text)` parses ` — _Criterion: ..._` suffix.
- [x] **Task 3: Prompt building** — `build_single_prompt(task, plan_content, config)` and `build_batch_prompt(tasks, plan_content, config)`. Same prompt structure as bash version: task, criterion, plan context, recent commits (via `git log --oneline -3`), coding agent rules (from `~/.claude/CODING_AGENTS.md`), instructions. Append user guidance section if present.
- [x] **Task 4: Stream parser and Claude runner** — `run_claude(prompt, config)` spawns `claude -p --output-format stream-json --verbose --dangerously-skip-permissions` with model flags. Reads stdout line by line, `json.loads` each. Yields/prints tool-use progress lines (same `format_tool_detail` logic). Returns `ClaudeResult(text, cost)`. Handle process cleanup on error.
- [x] **Task 5: Interactive features** — Inbox: read and clear `.ralph-inbox`. Countdown: `input()` with timeout using `select.select` (or threading). Follow-up detection: regex match on result text for question patterns. Background stdin reader thread that appends to inbox file. Same user commands: `skip`, `stop`, empty enter to proceed.
- [x] **Task 6: Review and main loop** — `run_review(base_sha, task_text, config)` — git diff, codex or claude review, fix issues. Main loop: find task → countdown → trim plan → build prompt → run claude → check completion → review → status line. Signal handler for SIGINT (stash + summary). Consecutive failure bail-out (3 max). Elapsed time + cost + progress tracking.
- [x] **Task 7: Integration** — Update `skills/ralph/SKILL.md` to invoke `ralph.py` instead of `ralph.sh`. Keep `ralph.sh` as `ralph-legacy.sh` in case of rollback. Test with a small plan file. Update `README.md` if needed.
