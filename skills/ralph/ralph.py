#!/usr/bin/env python3
# Dependency: pip install textual (required for TUI mode)
"""ralph.py — Execute a plan file task-by-task using claude -p.

Each task gets a fresh claude invocation with zero context carryover.
The plan file and a learnings file are the shared state across iterations.
The learnings file ({plan_stem}-learnings.md) accumulates gotchas and
progress notes so each fresh context window inherits institutional knowledge.

Resilience:
  Timeout:   tasks running over --task-timeout are killed and handed to a rescue agent
  Fallback:  if Claude hits a usage limit during review, Gemini CLI is used instead
  Logging:   all TUI output is mirrored to {plan_stem}-ralph.log

Interactive features (TUI mode):
  Guidance:  type in the input field to queue guidance for the next task
  Commands:  /stop, /skip, /kill, /pause, /resume, /retry, /plan
  Inbox:     echo "guidance" > .ralph-inbox  (from any terminal, any time)
  Follow-up: ralph detects when an agent asks a question and shows it in the log
"""

import argparse
import os
import sys
from pathlib import Path

# ─── Re-exports for backward compatibility ──────────────────────────────────
# Tests and other code do `import ralph; ralph.find_next_task(...)` etc.
# Keep all public names importable from this module.

from models import (  # noqa: F401
    State, AgentKilled, AgentTimeout, UsageLimitExceeded,
    _USAGE_LIMIT_RE, MODEL_PRESETS,
    CODING_AGENTS_FILE, RALPH_ASCII, INBOX_FILE,
    MAX_CONSECUTIVE_FAILS, DEFAULT_TASK_TIMEOUT, CONTEXT_REUSE_THRESHOLD,
    Config, Task, ClaudeResult,
    format_tokens, format_context_summary, elapsed,
)
from plan import (  # noqa: F401
    _TASK_RE, _CHECKED_RE, _DONE_RE, _TODO_RE, _PARALLEL_RE, _PHASE_HEADING_RE,
    find_plan, _phase_line_range,
    find_parallel_phases, parse_parallel_group,
    find_next_task, count_tasks, format_plan_summary,
    check_off_task, extract_criterion,
    collect_batch, is_batch_start,
    trim_plan_for_task,
    derive_learnings_path, derive_log_path,
    load_learnings, append_learning,
)
from prompt import (  # noqa: F401
    get_recent_commits, load_coding_rules, load_project_context,
    _append_prompt_context,
    build_single_prompt, build_batch_prompt, build_continuation_prompt,
    build_rescue_prompt,
)
from runner import (  # noqa: F401
    format_tool_detail, run_claude,
    read_inbox, needs_followup, _FOLLOWUP_RE,
)
from parallel import (  # noqa: F401
    TMUX_SESSION,
    create_worktrees, cleanup_worktrees, merge_parallel_branches,
    launch_parallel_tmux, wait_for_parallel_completion,
)
from review import (  # noqa: F401
    run_review, has_review_issues, fix_review_issues,
)
from launcher import (  # noqa: F401
    interactive_config, _has_fzf, _fzf_select, _menu_select,
    _pick, _collect_plan_files,
)
from tui import RalphApp  # noqa: F401


# ─── CLI argument parsing ───────────────────────────────────────────────────

def parse_args() -> tuple[Config, dict[str, bool]]:
    """Parse CLI arguments and return (config, explicit) where *explicit*
    tracks which settings the user provided explicitly (CLI flag or env var)
    so that interactive_config knows what to skip.
    """
    parser = argparse.ArgumentParser(
        description="Execute a plan file task-by-task using claude -p",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Model presets:
  opus-max       Opus 4.6, max thinking      (most capable, slowest)
  opus-high      Opus 4.6, high thinking     (default for hard tasks)
  opus-med       Opus 4.6, medium thinking
  opus           Opus 4.6, no effort set
  sonnet-high    Sonnet 4.6, high thinking
  sonnet         Sonnet 4.6, no effort set   (fast, good for simple tasks)
  haiku          Haiku 4.5, no effort set    (fastest, cheapest)
  Or pass any claude model ID directly (e.g. claude-opus-4-6)

Interactive features (TUI mode):
  Guidance:  type in the input field to queue guidance for the next task
  Commands:  /stop, /skip, /kill, /pause, /resume, /retry, /plan
  Inbox:     echo 'guidance' > .ralph-inbox  (from any terminal, any time)
  Follow-up: ralph shows agent questions in the log — reply via input field

Environment variables:
  RALPH_DELAY          Same as --delay
  RALPH_MODEL          Same as --model
  RALPH_REVIEWER       Same as --reviewer
  RALPH_TASK_TIMEOUT   Same as --task-timeout""",
    )
    parser.add_argument("plan_path", nargs="?", default="",
                        help="Path to the plan file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be executed without running claude")
    parser.add_argument("--delay", type=int,
                        default=int(os.environ.get("RALPH_DELAY", "5")),
                        help="Seconds for interactive countdown (default: 5)")
    parser.add_argument("--batch", action="store_true",
                        help="Process <!-- BATCH --> groups as single invocations")
    parser.add_argument("--review", action="store_true",
                        help="Run codex/claude review after each task")
    parser.add_argument("--no-review", action="store_true",
                        help="Skip review step")
    parser.add_argument("--model", default=os.environ.get("RALPH_MODEL", ""),
                        help="Model preset or claude model ID")
    parser.add_argument("--reviewer", default=os.environ.get("RALPH_REVIEWER", "auto"),
                        help="Reviewer: auto (default), codex, or claude")
    parser.add_argument("--phase", type=int, default=None,
                        help="Only execute tasks under ## Phase N heading")
    parser.add_argument("--task-timeout", type=int,
                        default=int(os.environ.get("RALPH_TASK_TIMEOUT",
                                                    str(DEFAULT_TASK_TIMEOUT))),
                        help="Kill stuck tasks after N seconds (default: 3600 = 1h, 0 to disable)")
    parser.add_argument("--learnings-path", default="",
                        help="Override auto-derived learnings file path (for worktree instances)")

    args = parser.parse_args()

    config = Config(
        delay=args.delay,
        dry_run=args.dry_run,
        task_timeout=args.task_timeout,
        batch_mode=args.batch,
        reviewer=args.reviewer,
        phase=args.phase,
        learnings_path=args.learnings_path,
    )

    # --review / --no-review logic (--no-review wins if both given)
    if args.no_review:
        config.skip_review = True
    elif args.review:
        config.skip_review = False

    # Resolve model preset
    model_str = args.model
    if model_str:
        if model_str in MODEL_PRESETS:
            config.model, config.effort = MODEL_PRESETS[model_str]
        else:
            config.model = model_str

    # Track what was explicitly provided so interactive_config can skip those
    explicit = {
        "plan_path": bool(args.plan_path),
        "model":     bool(args.model),
        "review":    args.review or args.no_review,
        "reviewer":  bool(os.environ.get("RALPH_REVIEWER"))
                     or any(a.startswith("--reviewer") for a in sys.argv[1:]),
    }

    # If plan_path was given explicitly, resolve it now
    if explicit["plan_path"]:
        config.plan_path = find_plan(args.plan_path)

    return config, explicit


# ─── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    config, explicit = parse_args()

    # Fill in gaps interactively (skips anything already set via CLI/env)
    interactive_config(config, explicit)

    # Resolve plan (if interactive_config selected it) and derive aux paths
    if not config.plan_path:
        # Should not happen — interactive_config always sets it — but guard
        config.plan_path = find_plan("")
    config.learnings_path = (config.learnings_path
                             or derive_learnings_path(config.plan_path))
    config.log_path = derive_log_path(config.plan_path)
    config.work_dir = os.getcwd()

    app = RalphApp(config)
    try:
        app.run()
    except KeyboardInterrupt:
        # Textual restores the terminal; just kill any lingering subprocess
        app._cleanup_proc()
    finally:
        # Safety net: kill subprocess on any unexpected exit
        app._cleanup_proc()


if __name__ == "__main__":
    main()
