#!/usr/bin/env python3
# Dependency: pip install textual (required for TUI mode)
"""ralph-v2 -- Phase-level build/evaluate harness using claude -p.

Each phase gets a generator invocation followed by an evaluator that tests
against acceptance criteria.  Up to --max-eval-rounds attempts per phase.
The plan file and a learnings file are the shared state across phases.

Three-agent system:
  Generator:   implements the full phase autonomously
  Evaluator:   tests output against acceptance criteria (Playwright, pytest, etc.)
  Rescue:      recovers stuck phases after timeout

Interactive features (TUI mode):
  Guidance:  type in the input field to queue guidance for the next phase
  Commands:  /stop, /skip, /kill, /pause, /resume, /retry, /plan
  Inbox:     echo "guidance" > .ralph-inbox  (from any terminal, any time)
"""

import argparse
import os
import sys
from pathlib import Path

# Re-exports for backward compatibility and testing
from models import (  # noqa: F401
    State, PhaseStatus, AgentKilled, AgentTimeout, UsageLimitExceeded,
    _USAGE_LIMIT_RE, MODEL_PRESETS,
    CODING_AGENTS_FILE, RALPH_ASCII, INBOX_FILE,
    MAX_CONSECUTIVE_FAILS, DEFAULT_TASK_TIMEOUT, DEFAULT_MAX_EVAL_ROUNDS,
    CONTEXT_REUSE_THRESHOLD,
    Config, Phase, ClaudeResult, EvalResult, EvalCriterionResult,
    format_tokens, format_context_summary, elapsed,
)
from plan import (  # noqa: F401
    _PHASE_HEADING_RE, _TASK_RE, _PARALLEL_RE,
    find_plan, parse_phases, get_phase, find_parallel_phases,
    parse_parallel_group, get_plan_header, get_phase_section,
    is_phase_complete_v1, is_phase_complete, check_off_v1_tasks, mark_phase_complete,
    derive_proposed_changes_path, load_proposed_changes,
    derive_learnings_path, derive_log_path,
    load_learnings, append_learning, format_plan_summary,
)
from prompt import (  # noqa: F401
    get_recent_commits, load_coding_rules, load_project_context,
    get_restart_context,
    build_generator_prompt, build_evaluator_prompt,
    build_generator_retry_prompt, build_rescue_prompt,
    extract_learnings, PLAYWRIGHT_DIRECTIONS,
)
from runner import (  # noqa: F401
    format_tool_detail, run_claude,
    read_inbox, needs_followup, _FOLLOWUP_RE,
)
from evaluator import (  # noqa: F401
    parse_eval_output, format_eval_summary,
)
from parallel import (  # noqa: F401
    TMUX_SESSION,
    create_worktrees, cleanup_worktrees, merge_parallel_branches,
    launch_parallel_tmux, wait_for_parallel_completion,
    verify_parallel_results,
)
from launcher import (  # noqa: F401
    interactive_config, _has_fzf, _fzf_select, _menu_select,
    _pick, _collect_plan_files,
)
from tui import RalphApp  # noqa: F401


# ─── CLI argument parsing ───────────────────────────────────────────────────

def parse_args() -> tuple[Config, dict[str, bool]]:
    parser = argparse.ArgumentParser(
        description="Execute a plan file phase-by-phase using claude -p",
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

Build/evaluate loop:
  For each phase, the generator implements the full phase, then the
  evaluator tests against acceptance criteria.  Up to --max-eval-rounds
  attempts.  Use --no-eval to skip the evaluator entirely.

Interactive features (TUI mode):
  Guidance:  type in the input field to queue guidance for the next phase
  Commands:  /stop, /skip, /kill, /pause, /resume, /retry, /plan
  Inbox:     echo 'guidance' > .ralph-inbox  (from any terminal, any time)

Environment variables:
  RALPH_DELAY            Same as --delay
  RALPH_MODEL            Same as --model
  RALPH_TASK_TIMEOUT     Same as --task-timeout
  RALPH_MAX_EVAL_ROUNDS  Same as --max-eval-rounds
  RALPH_REUSE_CONTEXT    Same as --reuse-context (1/true/yes to enable)""",
    )
    parser.add_argument("plan_path", nargs="?", default="",
                        help="Path to the plan file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be executed without running claude")
    parser.add_argument("--delay", type=int,
                        default=int(os.environ.get("RALPH_DELAY", "0")),
                        help="Seconds to pause between phases (default: 0)")
    parser.add_argument("--no-eval", action="store_true",
                        help="Skip the evaluator entirely")
    parser.add_argument("--max-eval-rounds", type=int,
                        default=int(os.environ.get("RALPH_MAX_EVAL_ROUNDS",
                                                    str(DEFAULT_MAX_EVAL_ROUNDS))),
                        help="Max evaluator passes per phase (default: 3)")
    parser.add_argument("--model", default=os.environ.get("RALPH_MODEL", ""),
                        help="Model preset or claude model ID")
    parser.add_argument("--reviewer", default="auto",
                        help="Kept for backward compatibility")
    parser.add_argument("--phase", type=int, default=None,
                        help="Only execute a single phase")
    parser.add_argument("--task-timeout", type=int,
                        default=int(os.environ.get("RALPH_TASK_TIMEOUT",
                                                    str(DEFAULT_TASK_TIMEOUT))),
                        help="Kill stuck agents after N seconds (default: 3600)")
    parser.add_argument("--reuse-context", action="store_true",
                        default=os.environ.get("RALPH_REUSE_CONTEXT", "").lower()
                        in ("1", "true", "yes"),
                        help="Resume previous session when peak context < 75k")
    parser.add_argument("--restart", action="store_true",
                        help="Resume from an interrupted run — injects git state context into the first phase prompt")
    parser.add_argument("--prompt", default="",
                        help="One-time guidance message injected into the first phase prompt")
    parser.add_argument("--learnings-path", default="",
                        help="Override auto-derived learnings file path")

    args = parser.parse_args()

    config = Config(
        delay=args.delay,
        dry_run=args.dry_run,
        task_timeout=args.task_timeout,
        skip_eval=args.no_eval,
        reviewer=args.reviewer,
        phase=args.phase,
        learnings_path=args.learnings_path,
        reuse_context=args.reuse_context,
        max_eval_rounds=args.max_eval_rounds,
        restart=args.restart,
        prompt=args.prompt,
    )

    # Resolve model preset
    model_str = args.model
    if model_str:
        if model_str in MODEL_PRESETS:
            config.model, config.effort = MODEL_PRESETS[model_str]
        else:
            config.model = model_str

    explicit = {
        "plan_path": bool(args.plan_path),
        "model":     bool(args.model),
        "eval":      args.no_eval,
    }

    if explicit["plan_path"]:
        config.plan_path = find_plan(args.plan_path)

    return config, explicit


# ─── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    config, explicit = parse_args()

    interactive_config(config, explicit)

    if not config.plan_path:
        config.plan_path = find_plan("")
    config.learnings_path = (config.learnings_path
                             or derive_learnings_path(config.plan_path))
    config.log_path = derive_log_path(config.plan_path)
    config.work_dir = os.getcwd()

    app = RalphApp(config)
    try:
        app.run()
    except KeyboardInterrupt:
        app._cleanup_proc()
    finally:
        app._cleanup_proc()


if __name__ == "__main__":
    main()
