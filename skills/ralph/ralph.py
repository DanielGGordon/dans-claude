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
import enum
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from textual.app import App, ComposeResult
from textual.reactive import reactive
from textual.widgets import RichLog, Static, Input
from textual import work


class State(enum.Enum):
    RUNNING = "RUNNING"
    COUNTDOWN = "COUNTDOWN"
    PAUSED = "PAUSED"
    DONE = "DONE"


class AgentKilled(Exception):
    """Raised when a running claude subprocess is killed (e.g., by /kill or /skip)."""
    pass


class AgentTimeout(Exception):
    """Raised when a running claude subprocess exceeds the task timeout."""
    pass


class UsageLimitExceeded(Exception):
    """Raised when Claude reports a usage/rate limit error."""
    pass


_USAGE_LIMIT_RE = re.compile(
    r"(usage limit|rate limit|over.?loaded|out of usage|"
    r"capacity|too many requests|429|529|"
    r"exceeded.*limit|limit.*exceeded|"
    r"try again later|resource_exhausted)",
    re.IGNORECASE,
)

# ─── Configuration ───────────────────────────────────────────────────────────

MODEL_PRESETS = {
    "opus-max":    ("claude-opus-4-6",            "max"),
    "opus-high":   ("claude-opus-4-6",            "high"),
    "opus-med":    ("claude-opus-4-6",            "medium"),
    "opus":        ("claude-opus-4-6",            ""),
    "sonnet-high": ("claude-sonnet-4-6",          "high"),
    "sonnet":      ("claude-sonnet-4-6",          ""),
    "haiku":       ("claude-haiku-4-5-20251001",  ""),
}

CODING_AGENTS_FILE = Path.home() / ".claude" / "CODING_AGENTS.md"
RALPH_ASCII = Path.home() / ".claude" / "skills" / "ralph" / "ralph-ascii.txt"
INBOX_FILE = ".ralph-inbox"
MAX_CONSECUTIVE_FAILS = 3
DEFAULT_TASK_TIMEOUT = 3600  # 1 hour in seconds


@dataclass
class Config:
    plan_path: str = ""
    work_dir: str = ""
    delay: int = 5
    dry_run: bool = False
    batch_mode: bool = False
    skip_review: bool = True
    reviewer: str = "auto"  # auto|codex|claude
    model: str = ""
    effort: str = ""
    learnings_path: str = ""  # auto-derived from plan_path if empty
    log_path: str = ""  # auto-derived from plan_path
    phase: int | None = None  # only execute tasks under this phase heading
    task_timeout: int = DEFAULT_TASK_TIMEOUT  # seconds; 0 to disable

    def claude_model_flags(self) -> list[str]:
        flags = []
        if self.model:
            flags += ["--model", self.model]
        if self.effort:
            flags += ["--effort", self.effort]
        return flags


@dataclass
class Task:
    line_num: int
    text: str
    criterion: str


@dataclass
class ClaudeResult:
    text: str = ""
    cost: float = 0.0
    num_turns: int = 0
    duration_ms: int = 0
    duration_api_ms: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    peak_input_tokens: int = 0  # max single-turn input (input + cache_read + cache_creation)


def format_tokens(n: int) -> str:
    """Format token count as human-readable string (e.g., 187k, 1.2M)."""
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def format_context_summary(result: ClaudeResult) -> str:
    """One-line summary of context/token usage for a task."""
    parts = [f"{result.num_turns} turns"]
    if result.peak_input_tokens > 0:
        parts.append(f"{format_tokens(result.peak_input_tokens)} peak ctx")
    total_in = result.input_tokens + result.cache_read_tokens + result.cache_creation_tokens
    if total_in > 0:
        parts.append(f"{format_tokens(total_in)} total in")
    if result.output_tokens > 0:
        parts.append(f"{format_tokens(result.output_tokens)} out")
    if result.duration_ms > 0:
        secs = result.duration_ms / 1000
        if secs >= 60:
            m, s = divmod(int(secs), 60)
            parts.append(f"{m}m{s:02d}s")
        else:
            parts.append(f"{secs:.1f}s")
    return " | ".join(parts)


# ─── Plan file discovery ────────────────────────────────────────────────────

def find_plan(explicit_path: str) -> str:
    if explicit_path:
        p = Path(explicit_path)
        if p.is_file():
            return str(p.resolve())
        print(f"Error: plan file not found: {explicit_path}", file=sys.stderr)
        sys.exit(1)

    for candidate in ("plan.md", "PLAN.md"):
        if Path(candidate).is_file():
            return str(Path(candidate).resolve())

    plans_dir = Path.home() / ".claude" / "plans"
    if plans_dir.is_dir():
        plans = sorted(plans_dir.glob("*.md"))
        if len(plans) == 1:
            return str(plans[0].resolve())
        if len(plans) > 1:
            print(f"Multiple plans found in {plans_dir}:", file=sys.stderr)
            for p in plans:
                print(f"  {p}", file=sys.stderr)
            print("Specify one: ralph.py <path>", file=sys.stderr)
            sys.exit(1)

    print("Error: no plan file found", file=sys.stderr)
    sys.exit(1)


# ─── Task parsing ───────────────────────────────────────────────────────────

_TASK_RE = re.compile(r"^(\s*- \[ \] )(.+)$")
_CHECKED_RE = re.compile(r"^\s*- \[[xX ]\] ")
_DONE_RE = re.compile(r"^\s*- \[[xX]\] (.+)$")
_TODO_RE = re.compile(r"^\s*- \[ \] (.+)$")
_PARALLEL_RE = re.compile(r"^\s*<!--\s*PARALLEL\s+([\d,\s]+)\s*-->\s*$")
_PHASE_HEADING_RE = re.compile(r"^##\s+Phase\s+(\d+)\b", re.IGNORECASE)


def _phase_line_range(plan_path: str, phase: int) -> tuple[int, int]:
    """Return (start, end) 1-indexed line range for '## Phase {phase}' section.

    end is the line before the next ## heading, or the last line of the file.
    """
    lines = Path(plan_path).read_text().splitlines()
    phase_re = re.compile(rf"^##\s+Phase\s+{phase}\b", re.IGNORECASE)
    start = None
    for i, line in enumerate(lines, 1):
        if start is None:
            if phase_re.match(line):
                start = i
        else:
            if line.startswith("## "):
                return start, i - 1
    if start is not None:
        return start, len(lines)
    return 0, 0  # phase not found: empty range


def find_parallel_phases(plan_path: str) -> list[list[int]]:
    """Return all parallel groups defined in the plan.

    Each group is a list of phase numbers extracted from
    ``<!-- PARALLEL N,M,... -->`` annotations.  Groups are returned in
    the order they appear in the file.
    """
    groups: list[list[int]] = []
    for line in Path(plan_path).read_text().splitlines():
        m = _PARALLEL_RE.match(line)
        if m:
            phases = [int(p.strip()) for p in m.group(1).split(",") if p.strip()]
            if phases:
                groups.append(phases)
    return groups


def parse_parallel_group(plan_path: str, task_line: int) -> list[int] | None:
    """Return phase numbers if task_line is inside a parallel group, None otherwise.

    A parallel group is defined by a ``<!-- PARALLEL N,M,... -->`` comment that
    covers the phases listed.  A task belongs to a group if its line falls within
    one of the group's phase sections.
    """
    groups = find_parallel_phases(plan_path)
    if not groups:
        return None
    # Determine which phase the task_line belongs to
    lines = Path(plan_path).read_text().splitlines()
    current_phase: int | None = None
    for i, line in enumerate(lines, 1):
        pm = _PHASE_HEADING_RE.match(line)
        if pm:
            current_phase = int(pm.group(1))
        if i == task_line:
            break
    if current_phase is None:
        return None
    # Check if that phase is in any group
    for group in groups:
        if current_phase in group:
            return group
    return None


def find_next_task(plan_path: str, min_line: int = 1,
                   phase: int | None = None) -> Task | None:
    phase_start, phase_end = (1, None)
    if phase is not None:
        phase_start, phase_end = _phase_line_range(plan_path, phase)
    effective_min = max(min_line, phase_start)
    with open(plan_path) as f:
        for i, line in enumerate(f, 1):
            if i < effective_min:
                continue
            if phase_end is not None and i > phase_end:
                break
            m = _TASK_RE.match(line)
            if m:
                text = m.group(2)
                return Task(line_num=i, text=text, criterion=extract_criterion(text))
    return None


def count_tasks(plan_path: str, phase: int | None = None) -> tuple[int, int]:
    done = 0
    total = 0
    phase_start, phase_end = 1, None
    if phase is not None:
        phase_start, phase_end = _phase_line_range(plan_path, phase)
    with open(plan_path) as f:
        for i, line in enumerate(f, 1):
            if i < phase_start:
                continue
            if phase_end is not None and i > phase_end:
                break
            if _CHECKED_RE.match(line):
                total += 1
                if re.match(r"^\s*- \[[xX]\] ", line):
                    done += 1
    return done, total


def format_plan_summary(plan_path: str) -> list[str]:
    """Read the plan file and return formatted lines showing task status."""
    lines: list[str] = []
    done, total = count_tasks(plan_path)
    lines.append(f"📋 Plan: {done}/{total} tasks complete")
    lines.append("")

    with open(plan_path) as f:
        for raw_line in f:
            stripped = raw_line.rstrip()
            m_done = _DONE_RE.match(stripped)
            m_todo = _TODO_RE.match(stripped)
            if m_done:
                lines.append(f"  ✅ {m_done.group(1)}")
            elif m_todo:
                lines.append(f"  ⬜ {m_todo.group(1)}")
            elif stripped.startswith("#"):
                lines.append(stripped)

    return lines


def check_off_task(plan_path: str, line_num: int) -> None:
    lines = Path(plan_path).read_text().splitlines(keepends=True)
    idx = line_num - 1
    if 0 <= idx < len(lines):
        lines[idx] = lines[idx].replace("- [ ] ", "- [x] ", 1)
        Path(plan_path).write_text("".join(lines))


def extract_criterion(text: str) -> str:
    # Try "_Criterion: ..._" suffix
    m = re.search(r"_Criterion:\s*(.+?)_\s*$", text)
    if m:
        return m.group(1)
    # Try " — description" suffix
    m = re.search(r"\s—\s(.+)$", text)
    if m:
        return m.group(1)
    return "Task is complete and working correctly"


def collect_batch(plan_path: str, start_line: int) -> list[Task]:
    tasks = []
    collecting = False
    with open(plan_path) as f:
        for i, line in enumerate(f, 1):
            if i < start_line:
                continue
            m = _TASK_RE.match(line)
            if m:
                collecting = True
                text = m.group(2)
                tasks.append(Task(line_num=i, text=text, criterion=extract_criterion(text)))
            elif collecting:
                break
    return tasks


def is_batch_start(plan_path: str, task_line: int) -> bool:
    if task_line < 2:
        return False
    lines = Path(plan_path).read_text().splitlines()
    prev = lines[task_line - 2] if task_line - 1 < len(lines) else ""
    return "<!-- BATCH -->" in prev


# ─── Learnings file ─────────────────────────────────────────────────────────

def derive_learnings_path(plan_path: str) -> str:
    """Derive learnings file path from plan path: plan.md -> plan-learnings.md"""
    p = Path(plan_path)
    return str(p.with_name(f"{p.stem}-learnings.md"))


def derive_log_path(plan_path: str) -> str:
    """Derive log file path from plan path: plan.md -> plan-ralph.log"""
    p = Path(plan_path)
    return str(p.with_name(f"{p.stem}-ralph.log"))


def load_learnings(learnings_path: str) -> str:
    """Read the learnings file with a shared lock, returning empty string if missing."""
    p = Path(learnings_path)
    if not p.is_file():
        return ""
    with open(p) as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            return f.read().strip()
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def append_learning(learnings_path: str, task_text: str, passed: bool) -> None:
    """Append a one-liner to the learnings file under an exclusive lock."""
    p = Path(learnings_path)
    timestamp = time.strftime("%Y-%m-%d %H:%M")
    status = "done" if passed else "FAILED"
    entry = f"[{status} {timestamp}] {task_text}\n"
    if not p.exists():
        p.write_text(f"# Learnings\n# Ralph appends entries here. Claude also appends gotchas.\n\n{entry}")
    else:
        with open(p, "a") as f:
            # Exclusive lock with 1-second blocking wait
            deadline = time.monotonic() + 1.0
            while True:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        fcntl.flock(f, fcntl.LOCK_EX)  # final blocking attempt
                        break
                    time.sleep(0.05)
            try:
                f.write(entry)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


# ─── Parallel orchestration ─────────────────────────────────────────────────

TMUX_SESSION = "ralph-parallel"


def create_worktrees(phases: list[int], repo_dir: str) -> dict[int, str]:
    """Create a git worktree for each phase, returning {phase: worktree_path}."""
    worktrees: dict[int, str] = {}
    for phase in phases:
        branch = f"ralph/phase-{phase}"
        wt_path = f"{repo_dir}-ralph-phase-{phase}"
        subprocess.run(
            ["git", "worktree", "add", wt_path, "-b", branch, "HEAD"],
            cwd=repo_dir, capture_output=True, text=True, check=True,
        )
        worktrees[phase] = wt_path
    return worktrees


def cleanup_worktrees(worktrees: dict[int, str], repo_dir: str) -> None:
    """Remove worktrees and delete their branches."""
    for phase, wt_path in worktrees.items():
        branch = f"ralph/phase-{phase}"
        subprocess.run(
            ["git", "worktree", "remove", "--force", wt_path],
            cwd=repo_dir, capture_output=True, text=True,
        )
        subprocess.run(
            ["git", "branch", "-D", branch],
            cwd=repo_dir, capture_output=True, text=True,
        )


def merge_parallel_branches(
    phases: list[int],
    worktrees: dict[int, str],
    repo_dir: str,
    on_output: Callable[[str], None] = print,
) -> None:
    """Merge each phase branch back into main sequentially.

    First branch merges directly. Subsequent branches rebase onto updated main
    first. If rebase conflicts occur, a Claude agent attempts resolution.
    """
    for i, phase in enumerate(phases):
        branch = f"ralph/phase-{phase}"
        on_output(f"  Merging {branch}...")

        if i > 0:
            # Rebase onto updated main before merging
            rebase = subprocess.run(
                ["git", "rebase", "HEAD", branch],
                cwd=repo_dir, capture_output=True, text=True,
            )
            if rebase.returncode != 0:
                on_output(f"  ⚠️  Rebase conflict on {branch} — attempting auto-resolve")
                # Get conflict info for the Claude agent
                diff_result = subprocess.run(
                    ["git", "diff"], cwd=repo_dir, capture_output=True, text=True,
                )
                conflict_diff = diff_result.stdout[:4000]

                # Spawn a Claude agent to resolve
                resolve_prompt = (
                    f"You are resolving a git rebase conflict.\n\n"
                    f"Branch '{branch}' (phase {phase}) is being rebased onto main.\n"
                    f"The other phases ({phases[:i]}) have already been merged.\n\n"
                    f"Conflict diff:\n```\n{conflict_diff}\n```\n\n"
                    f"Resolve all conflicts in the working tree, then run "
                    f"'git add' on resolved files and 'git rebase --continue'.\n"
                    f"If the conflicts are irreconcilable, run 'git rebase --abort' "
                    f"and explain why."
                )
                agent = subprocess.run(
                    ["claude", "-p", "--dangerously-skip-permissions",
                     "--output-format", "text"],
                    input=resolve_prompt,
                    cwd=repo_dir, capture_output=True, text=True, timeout=300,
                )
                if agent.returncode != 0:
                    # Abort rebase and raise
                    subprocess.run(
                        ["git", "rebase", "--abort"],
                        cwd=repo_dir, capture_output=True, text=True,
                    )
                    raise RuntimeError(
                        f"Failed to resolve conflicts merging {branch}. "
                        f"Conflicting files are in the diff above."
                    )
                on_output(f"  ✅ Conflicts resolved by Claude agent")

        # Fast-forward merge the (now rebased) branch
        merge = subprocess.run(
            ["git", "merge", "--ff-only", branch],
            cwd=repo_dir, capture_output=True, text=True,
        )
        if merge.returncode != 0:
            # Fallback to regular merge if ff not possible
            merge = subprocess.run(
                ["git", "merge", branch, "-m", f"Merge parallel phase {phase}"],
                cwd=repo_dir, capture_output=True, text=True,
            )
            if merge.returncode != 0:
                raise RuntimeError(
                    f"Merge failed for {branch}: {merge.stderr}"
                )
        on_output(f"  ✅ {branch} merged")


def launch_parallel_tmux(
    phases: list[int],
    worktrees: dict[int, str],
    plan_path: str,
    learnings_path: str,
    config: Config,
) -> None:
    """Launch a tmux session with one window per phase running Ralph."""
    ralph_script = str(Path(__file__).resolve())
    model_flags = ""
    if config.model:
        model_flags += f" --model {config.model}"

    for i, phase in enumerate(phases):
        wt = worktrees[phase]
        cmd = (f"cd {wt} && python3 {ralph_script} {plan_path}"
               f" --phase {phase} --learnings-path {learnings_path}"
               f"{model_flags}")
        if i == 0:
            subprocess.run(
                ["tmux", "new-session", "-d", "-s", TMUX_SESSION,
                 "-n", f"phase-{phase}", cmd],
                check=True,
            )
        else:
            subprocess.run(
                ["tmux", "new-window", "-t", TMUX_SESSION,
                 "-n", f"phase-{phase}", cmd],
                check=True,
            )


def wait_for_parallel_completion() -> None:
    """Block until all windows in the ralph-parallel tmux session have exited."""
    while True:
        result = subprocess.run(
            ["tmux", "list-windows", "-t", TMUX_SESSION],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            break  # session gone — all windows finished
        time.sleep(5)


# ─── Plan trimming ──────────────────────────────────────────────────────────

def trim_plan_for_task(plan_path: str, task_line: int) -> str:
    lines = Path(plan_path).read_text().splitlines()

    # Find all ## heading line numbers (1-indexed)
    heading_lines = [i + 1 for i, l in enumerate(lines) if l.startswith("## ")]

    if not heading_lines:
        return "\n".join(lines)

    # Preamble ends before first heading
    preamble_end = heading_lines[0] - 1

    # Task before any heading — return full plan
    if task_line < heading_lines[0]:
        return "\n".join(lines)

    # Find section containing the task
    section_start = heading_lines[0]
    section_end = None
    for idx, hl in enumerate(heading_lines):
        if hl <= task_line:
            section_start = hl
            if idx + 1 < len(heading_lines):
                section_end = heading_lines[idx + 1] - 1
            else:
                section_end = None

    parts = []

    # Preamble
    if preamble_end > 0:
        parts.append("\n".join(lines[:preamble_end]))

    # Separator if skipping phases
    if section_start > preamble_end + 1:
        parts.append("\n[... completed phases omitted ...]\n")

    # Current section (convert to 0-indexed)
    if section_end is not None:
        parts.append("\n".join(lines[section_start - 1:section_end]))
    else:
        parts.append("\n".join(lines[section_start - 1:]))

    return "\n".join(parts)


# ─── Prompt building ────────────────────────────────────────────────────────

def get_recent_commits() -> str:
    try:
        result = subprocess.run(
            ["git", "log", "--oneline", "-3"],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() or "No git history available."
    except Exception:
        return "No git history available."


def load_coding_rules() -> str:
    if CODING_AGENTS_FILE.is_file():
        return CODING_AGENTS_FILE.read_text()
    return ""


def load_project_context(work_dir: str) -> str:
    """Load README.md and PROJECT_STRUCTURE.md from the working directory if they exist."""
    parts: list[str] = []
    for filename in ("README.md", "PROJECT_STRUCTURE.md"):
        filepath = Path(work_dir) / filename
        if filepath.is_file():
            contents = filepath.read_text().strip()
            if contents:
                parts.append(f"This is the {filename}:\n\n{contents}")
    return "\n\n".join(parts)


def build_single_prompt(task: Task, plan_content: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        user_guidance: str,
                        project_context: str = "",
                        learnings_content: str = "") -> str:
    prompt = f"""You are executing a single task from a plan.

## Your Task

**Task:** {task.text}
**Completion Criterion:** {task.criterion}
**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## Plan Context

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ONLY this single task. Do not work on other tasks.
- When the task is complete and the completion criterion is met, edit the plan file to check off this task: change `- [ ]` to `- [x]` for this task's line.
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did.
- After completing (or failing) the task, append a single line to `{config.learnings_path}`. Use this format:
  `[done YYYY-MM-DD HH:MM] Task description. ⚠️ Learning: <only if there's a genuine gotcha, else omit>`
  Only record a learning if you discovered something surprising — a workaround, an environment quirk, a non-obvious dependency, or a dead end worth avoiding. Do not record routine work."""

    if learnings_content:
        prompt += f"""

## Progress & Learnings

Previous tasks recorded these notes. Read them to avoid repeating mistakes or rediscovering gotchas:

{learnings_content}"""

    if project_context:
        prompt += f"""

## Project Context

{project_context}"""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

{user_guidance}"""

    return prompt


def build_batch_prompt(tasks: list[Task], plan_content: str, config: Config,
                       coding_rules: str, recent_commits: str,
                       user_guidance: str,
                       project_context: str = "",
                       learnings_content: str = "") -> str:
    task_list = "\n".join(f"- {t.text}" for t in tasks)

    prompt = f"""You are executing a batch of related tasks from a plan.

## Your Tasks

{task_list}

**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## Plan Context

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ALL of the tasks listed above. They are related and should be done together.
- Work through them in order, but use your judgment — if implementing one naturally completes another, that's fine.
- When each task is complete, edit the plan file to check it off: change `- [ ]` to `- [x]` for that task's line.
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did for each task.
- After completing the batch, append a single line per task to `{config.learnings_path}`. Use this format:
  `[done YYYY-MM-DD HH:MM] Task description. ⚠️ Learning: <only if there's a genuine gotcha, else omit>`
  Only record a learning if you discovered something surprising. Do not record routine work."""

    if learnings_content:
        prompt += f"""

## Progress & Learnings

Previous tasks recorded these notes. Read them to avoid repeating mistakes or rediscovering gotchas:

{learnings_content}"""

    if project_context:
        prompt += f"""

## Project Context

{project_context}"""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

{user_guidance}"""

    return prompt


def build_rescue_prompt(task: Task, plan_content: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        elapsed_mins: int,
                        learnings_content: str = "",
                        project_context: str = "") -> str:
    """Build a prompt for a fresh agent to rescue a stuck task."""
    prompt = f"""You are rescuing a stuck task. A previous agent was working on this task for over {elapsed_mins} minutes and appeared to be stuck or in a loop. It was terminated, but its code changes are still in the working tree — nothing was stashed or reverted.

## Your Task

**Task:** {task.text}
**Completion Criterion:** {task.criterion}
**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## What Happened

The previous agent ran for {elapsed_mins} minutes without completing this task. Its partial changes are in the working tree right now. Common causes:
- Stuck in a test-fix loop (tests fail, agent tries to fix, tests fail again)
- Over-engineering or going down the wrong path
- Waiting on something that won't resolve

## What You Should Do

1. Run `git diff` and `git status` to see what the previous agent changed
2. Assess whether the changes are on the right track or need a different approach
3. If the changes are close, finish them up. If they're wrong, revert and start fresh.
4. Complete the task and check it off in the plan file: change `- [ ]` to `- [x]`
5. Keep it simple — the previous agent likely overcomplicated things

## Plan Context

<plan>
{plan_content}
</plan>

## Recent Commits

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}"""

    if learnings_content:
        prompt += f"""

## Progress & Learnings

{learnings_content}"""

    if project_context:
        prompt += f"""

## Project Context

{project_context}"""

    return prompt


# ─── Stream parser and Claude runner ────────────────────────────────────────

def format_tool_detail(name: str, input_data: dict) -> str:
    detail = ""
    if name in ("Read", "Write"):
        fp = input_data.get("file_path", "")
        if fp:
            detail = os.path.basename(fp)
    elif name == "Edit":
        fp = input_data.get("file_path", "")
        if fp:
            detail = os.path.basename(fp)
    elif name == "Bash":
        cmd = input_data.get("command", "")
        if len(cmd) > 80:
            cmd = cmd[:77] + "..."
        detail = cmd
    elif name == "Grep":
        pat = input_data.get("pattern", "")
        path = input_data.get("path", "")
        if path:
            path = os.path.basename(path)
        parts = []
        if pat:
            parts.append(f"/{pat}/")
        if path:
            parts.append(f"in {path}")
        detail = " ".join(parts)
    elif name == "Glob":
        detail = input_data.get("pattern", "")
    elif name == "Agent":
        detail = input_data.get("description", "")

    if detail:
        return f"  🔧 {name} — {detail}"
    return f"  🔧 {name}"


def run_claude(prompt: str, config: Config,
               on_output: Callable[[str], None] = print,
               proc_register: Callable[[subprocess.Popen], None] | None = None,
               timeout: int = 0) -> ClaudeResult:
    cmd = [
        "claude", "-p",
        *config.claude_model_flags(),
        "--dangerously-skip-permissions",
        "--verbose",
        "--output-format", "stream-json",
    ]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    proc.stdin.write(prompt)
    proc.stdin.close()

    if proc_register is not None:
        proc_register(proc)

    # Watchdog: kill proc after timeout (0 = no timeout)
    timed_out = threading.Event()
    watchdog: threading.Timer | None = None
    if timeout > 0:
        def _timeout_kill():
            timed_out.set()
            try:
                proc.kill()
            except Exception:
                pass
        watchdog = threading.Timer(timeout, _timeout_kill)
        watchdog.daemon = True
        watchdog.start()

    result = ClaudeResult()

    for raw_line in proc.stdout:
        line = raw_line.strip()
        if not line:
            continue

        # Fast-path: skip frequent events
        if '"content_block_delta"' in line:
            continue
        if '"content_block_stop"' in line:
            continue
        if '"message_start"' in line:
            continue
        if '"message_delta"' in line:
            continue
        if '"message_stop"' in line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Tool use events + per-turn token tracking
        if event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    input_data = block.get("input", {})
                    on_output(format_tool_detail(name, input_data))
            # Track per-turn usage for peak context detection
            usage = event.get("message", {}).get("usage", {})
            if usage:
                turn_input = (usage.get("input_tokens", 0)
                              + usage.get("cache_read_input_tokens", 0)
                              + usage.get("cache_creation_input_tokens", 0))
                if turn_input > result.peak_input_tokens:
                    result.peak_input_tokens = turn_input

        elif '"content_block_start"' in line and '"tool_use"' in line:
            tool = event.get("content_block", {}).get("name", "")
            if tool:
                on_output(f"  🔧 {tool}")

        elif event.get("type") == "result":
            result.text = event.get("result", "")
            if result.text:
                on_output("")
                on_output(result.text)
            cost = event.get("total_cost_usd")
            if cost is not None:
                result.cost = float(cost)
            # Aggregate usage from result event
            usage = event.get("usage", {})
            result.input_tokens = usage.get("input_tokens", 0)
            result.output_tokens = usage.get("output_tokens", 0)
            result.cache_read_tokens = usage.get("cache_read_input_tokens", 0)
            result.cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
            result.num_turns = event.get("num_turns", 0)
            result.duration_ms = event.get("duration_ms", 0)
            result.duration_api_ms = event.get("duration_api_ms", 0)
            on_output(f"  📊 {format_context_summary(result)}")
            on_output(f"  💰 ${result.cost:.4f}")

    if watchdog is not None:
        watchdog.cancel()

    proc.wait()
    if timed_out.is_set():
        raise AgentTimeout()
    if proc.returncode is not None and proc.returncode < 0:
        raise AgentKilled()

    # Detect usage/rate limit errors
    if result.text and _USAGE_LIMIT_RE.search(result.text):
        raise UsageLimitExceeded(result.text)
    # Non-zero exit with no result often means an API error
    if proc.returncode and proc.returncode > 0 and not result.text:
        raise UsageLimitExceeded(f"claude exited with code {proc.returncode}")

    return result


# ─── Inbox & interaction ────────────────────────────────────────────────────

def read_inbox() -> str:
    p = Path(INBOX_FILE)
    if p.is_file() and p.stat().st_size > 0:
        contents = p.read_text()
        p.write_text("")  # clear
        return contents.strip()
    return ""


_FOLLOWUP_RE = re.compile(
    r"(need clarification|which approach|should [iI]|blocked by|unclear|"
    r"question:|please confirm|please advise|awaiting|before I proceed|"
    r"could you|can you clarify|not sure whether|two options|either .+ or)",
    re.IGNORECASE,
)


def needs_followup(text: str) -> bool:
    if not text:
        return False
    return bool(_FOLLOWUP_RE.search(text))


# ─── Time tracking ──────────────────────────────────────────────────────────

def elapsed(start_time: float) -> str:
    secs = int(time.time() - start_time)
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h{m:02d}m{s:02d}s"
    if m > 0:
        return f"{m}m{s:02d}s"
    return f"{s}s"


# ─── TUI App ─────────────────────────────────────────────────────────────────


class RalphApp(App):
    """Textual TUI for ralph — scrollable log, status bar, input field."""

    CSS = """
    #log {
        height: 1fr;
    }
    #status {
        height: 1;
        background: $surface;
        color: $text-muted;
        padding: 0 1;
    }
    Input {
        height: 3;
        color: #e8a735;
    }
    """

    state: reactive[State] = reactive(State.RUNNING)

    # Valid states for each command — commands not listed here are always valid
    COMMAND_VALID_STATES: dict[str, set[State]] = {
        "skip": {State.RUNNING, State.COUNTDOWN},
        "stop": {State.RUNNING, State.COUNTDOWN, State.PAUSED},
        "kill": {State.RUNNING, State.COUNTDOWN},
        "pause": {State.RUNNING, State.COUNTDOWN},
        "resume": {State.PAUSED},
        "retry": {State.PAUSED},
    }

    def __init__(self, config: Config, **kwargs):
        super().__init__(**kwargs)
        self.config = config
        self.start_time: float = time.time()
        self.task_start_time: float = 0.0
        self.total_cost: float = 0.0
        self.current_task: str = ""
        self._completed: int = 0
        self._failed: int = 0
        self._task_results: list[tuple[str, ClaudeResult]] = []  # (task_text, result)
        self.guidance_queue: deque[str] = deque()
        self.current_proc: subprocess.Popen | None = None
        self.skip_event = threading.Event()
        self.pause_event = threading.Event()
        self.resume_event = threading.Event()
        self._stash_created: bool = False
        self._retry: bool = False
        self._log_file = open(config.log_path, "a") if config.log_path else None
        self.command_handlers: dict[str, Callable[[str], None]] = {
            "stop": self.cmd_stop,
            "skip": self.cmd_skip,
            "plan": self.cmd_plan,
            "kill": self.cmd_kill,
            "pause": self.cmd_pause,
            "resume": self.cmd_resume,
            "retry": self.cmd_retry,
            "help": self.cmd_help,
        }

    def output(self, text: str = "", style: str = "") -> None:
        """Write a line to the RichLog widget and log file (thread-safe)."""
        from rich.text import Text
        log = self.query_one("#log", RichLog)
        if style:
            log.write(Text(text, style=style))
        else:
            log.write(text)
        # Mirror to log file
        if self._log_file:
            timestamp = time.strftime("%H:%M:%S")
            self._log_file.write(f"[{timestamp}] {text}\n")
            self._log_file.flush()

    def update_status(self) -> None:
        """Refresh the status bar with elapsed time, cost, progress, state, task."""
        done, total = count_tasks(self.config.plan_path, phase=self.config.phase)
        parts = [
            f"⏱ {elapsed(self.start_time)}",
            f"💰 ${self.total_cost:.4f}",
            f"📋 {done}/{total}",
            self.state.value,
        ]
        if self.current_task:
            task_display = self.current_task
            if self.task_start_time > 0 and self.state == State.RUNNING:
                task_display += f" ({elapsed(self.task_start_time)})"
            parts.append(task_display)
        self.query_one("#status", Static).update(" | ".join(parts))

    def cmd_stop(self, _arg: str = "") -> None:
        """Handle /stop: kill running proc, git stash if dirty, log summary, exit."""
        # Kill the running subprocess if any
        if self.current_proc is not None:
            try:
                self.current_proc.kill()
                self.current_proc.wait(timeout=5)
            except Exception:
                pass
            self.current_proc = None

        # Git stash if working tree is dirty
        try:
            result = subprocess.run(
                ["git", "status", "--porcelain"],
                capture_output=True, text=True, timeout=5,
                cwd=self.config.work_dir,
            )
            if result.stdout.strip():
                stash_result = subprocess.run(
                    ["git", "stash", "push", "-u", "-m",
                     f"ralph: stopped after {self._completed} tasks completed"],
                    capture_output=True, text=True, timeout=10,
                    cwd=self.config.work_dir,
                )
                if stash_result.returncode == 0:
                    self.output("📦 Changes stashed (git stash pop to restore)")
                else:
                    self.output("⚠️  git stash failed — changes left in working tree")
        except Exception:
            pass

        # Write summary to log
        self.output("")
        self.output(f"🛑 Stopped after {self._completed} tasks, {self._failed} failed. "
                     f"⏱ {elapsed(self.start_time)} | 💰 ${self.total_cost:.4f}")

        self.exit()

    def cmd_skip(self, _arg: str = "") -> None:
        """Handle /skip: kill running proc, set skip flag, move to next task."""
        if self.current_proc is not None:
            try:
                self.current_proc.kill()
                self.current_proc.wait(timeout=5)
            except Exception:
                pass
            self.current_proc = None
        self.skip_event.set()
        self.output("⏭️  Skipping current task...")

    def cmd_help(self, _arg: str = "") -> None:
        """Handle /help: show available commands."""
        lines = [
            "━━━ Ralph Commands ━━━",
            "  /skip     — Kill current task, move to next",
            "  /stop     — Kill current task, stash changes, exit",
            "  /kill     — Kill current task, stash changes, pause",
            "  /pause    — Pause after current task finishes",
            "  /resume   — Unpause, move to next task (pops stash)",
            "  /retry    — Unpause, re-run same task (pops stash)",
            "  /plan     — Show plan progress",
            "  /help     — Show this help",
            "━━━ Guidance ━━━",
            "  Type anything else to queue guidance for the next task.",
            "  You can also: echo 'guidance' > .ralph-inbox",
        ]
        for line in lines:
            self.output(line)

    def cmd_plan(self, _arg: str = "") -> None:
        """Handle /plan: show current plan status in the output log."""
        for line in format_plan_summary(self.config.plan_path):
            self.output(line)

    def cmd_kill(self, _arg: str = "") -> None:
        """Handle /kill and /pause: kill proc, git stash, set PAUSED, signal worker."""
        # Kill the running subprocess if any
        if self.current_proc is not None:
            try:
                self.current_proc.kill()
                self.current_proc.wait(timeout=5)
            except Exception:
                pass
            self.current_proc = None

        # Git stash if working tree is dirty
        self._stash_created = False
        try:
            result = subprocess.run(
                ["git", "status", "--porcelain"],
                capture_output=True, text=True, timeout=5,
                cwd=self.config.work_dir,
            )
            if result.stdout.strip():
                stash_result = subprocess.run(
                    ["git", "stash", "push", "-u", "-m",
                     "ralph: paused by user"],
                    capture_output=True, text=True, timeout=10,
                    cwd=self.config.work_dir,
                )
                if stash_result.returncode == 0:
                    self._stash_created = True
                    self.output("📦 Changes stashed (ralph: paused by user)")
                else:
                    self.output("⚠️  git stash failed — changes left in working tree")
        except Exception:
            pass

        self.state = State.PAUSED
        self.pause_event.set()
        self.output("⏸️  Paused. Use /resume or /retry to continue.")

    def cmd_pause(self, _arg: str = "") -> None:
        """Handle /pause: set pause flag so worker pauses after current task finishes."""
        self.pause_event.set()
        self.output("⏸️  Will pause after current task finishes...")

    def cmd_resume(self, _arg: str = "") -> None:
        """Handle /resume: set retry=False, signal resume_event. Worker moves to next task."""
        self._retry = False
        self.state = State.RUNNING
        self.resume_event.set()
        self.output("▶️  Resuming — moving to next task...")

    def cmd_retry(self, _arg: str = "") -> None:
        """Handle /retry: set retry=True, signal resume_event. Worker re-runs same task."""
        self._retry = True
        self.state = State.RUNNING
        self.resume_event.set()
        self.output("🔄 Retrying current task...")

    def _pop_stash(self, out: Callable[[str], None]) -> None:
        """Pop the git stash created by /kill or /pause."""
        try:
            result = subprocess.run(
                ["git", "stash", "pop"],
                capture_output=True, text=True, timeout=10,
                cwd=self.config.work_dir,
            )
            if result.returncode == 0:
                out("📦 Stash restored (git stash pop)")
            else:
                out(f"⚠️  git stash pop failed: {result.stderr.strip()}")
        except Exception:
            out("⚠️  git stash pop failed")
        self._stash_created = False

    def _register_proc(self, proc: subprocess.Popen) -> None:
        """Register the running subprocess so /kill and /skip can find it."""
        self.current_proc = proc

    def _get_review_base(self) -> str:
        """Get the current git HEAD for review diffing."""
        try:
            return subprocess.run(
                ["git", "rev-parse", "HEAD"],
                capture_output=True, text=True,
            ).stdout.strip()
        except Exception:
            return ""

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle input submission: dispatch /commands or queue guidance."""
        text = event.value.strip()
        if not text:
            return
        event.input.clear()
        if text.startswith("/"):
            cmd_parts = text[1:].split(None, 1)
            cmd_name = cmd_parts[0] if cmd_parts else ""
            cmd_arg = cmd_parts[1] if len(cmd_parts) > 1 else ""
            handler = self.command_handlers.get(cmd_name)
            if handler:
                valid_states = self.COMMAND_VALID_STATES.get(cmd_name)
                if valid_states is not None and self.state not in valid_states:
                    self.output(
                        f"⚠️  /{cmd_name} is not valid in {self.state.value} state"
                    )
                else:
                    handler(cmd_arg)
            else:
                self.output(f"Unknown command: /{cmd_name}")
        else:
            self.guidance_queue.append(text)
            self.output(f"📬 Queued: {text}")

    def compose(self) -> ComposeResult:
        yield RichLog(id="log", wrap=True)
        yield Static("Ralph — starting...", id="status")
        yield Input(placeholder="Type guidance or /command...")

    def on_mount(self) -> None:
        self.set_interval(1, self.update_status)
        self._run_tasks()

    def _cleanup_proc(self) -> None:
        """Kill the running subprocess if any. Called on shutdown/crash."""
        if self.current_proc is not None:
            try:
                self.current_proc.kill()
                self.current_proc.wait(timeout=5)
            except Exception:
                pass
            self.current_proc = None

    @work(thread=True)
    def _run_tasks(self) -> None:
        config = self.config
        out = self.output

        # Banner
        if RALPH_ASCII.is_file():
            out(RALPH_ASCII.read_text())
        out(f"Plan: {config.plan_path}")
        out(f"Working directory: {config.work_dir}")
        if config.model:
            model_info = config.model
            if config.effort:
                model_info += f" (effort: {config.effort})"
            out(f"Model: {model_info}")
        if not config.skip_review:
            out(f"Review: enabled (reviewer: {config.reviewer})")
        out(f"Learnings: {config.learnings_path}")
        out(f"Log: {config.log_path}")
        if config.task_timeout > 0:
            out(f"Task timeout: {config.task_timeout // 60}m (auto-rescue)")
        out("")

        # Pre-load context
        coding_rules = load_coding_rules()
        recent_commits = get_recent_commits()
        project_context = load_project_context(config.work_dir)
        consecutive_fails = 0
        user_guidance = ""

        min_line = 1
        last_task: Task | None = None
        while True:
            # Check if paused — wait for resume before continuing
            if self.pause_event.is_set():
                self.state = State.PAUSED
                # Block until resume_event is signalled (poll to allow app shutdown)
                while not self.resume_event.wait(timeout=0.5):
                    if not self.is_running:
                        return
                self.resume_event.clear()
                self.pause_event.clear()

                if self._retry and last_task is not None:
                    # Retry: pop stash to restore changes, re-run same task
                    if self._stash_created:
                        self._pop_stash(out)
                    min_line = last_task.line_num
                else:
                    # Resume: move to next task, pop stash if one was created
                    if self._stash_created:
                        self._pop_stash(out)
                    if last_task is not None:
                        min_line = last_task.line_num + 1
                continue

            task = find_next_task(config.plan_path, min_line=min_line, phase=config.phase)
            if task is None:
                self.current_task = ""
                self.state = State.DONE
                phase_msg = f" in phase {config.phase}" if config.phase else ""
                out(f"\n✅ All tasks{phase_msg} complete! ({self._completed} completed)")
                break

            last_task = task

            # Check if paused between finding task and starting it
            # (avoids overwriting PAUSED state set by cmd_kill)
            if self.pause_event.is_set():
                min_line = task.line_num
                continue

            # ── Parallel group detection ──────────────────────────
            if config.phase is None:  # only main Ralph orchestrates
                parallel_phases = parse_parallel_group(config.plan_path, task.line_num)
                if parallel_phases:
                    out("━" * 60)
                    out(f"🔀 Parallel group detected: phases {parallel_phases}")
                    out("━" * 60)
                    try:
                        worktrees = create_worktrees(parallel_phases, config.work_dir)
                        launch_parallel_tmux(
                            parallel_phases, worktrees,
                            config.plan_path, config.learnings_path, config,
                        )
                        out(f"  tmux attach -t {TMUX_SESSION}")
                        n = len(parallel_phases)
                        self.current_task = f"Parallel: {n} phases running"
                        self.update_status()
                        wait_for_parallel_completion()
                        out(f"✅ All {n} parallel phases finished")
                        # Merge back (Phase 5 logic)
                        merge_parallel_branches(
                            parallel_phases, worktrees, config.work_dir, out,
                        )
                        cleanup_worktrees(worktrees, config.work_dir)
                    except Exception as e:
                        out(f"❌ Parallel execution failed: {e}", style="bold red")
                    # Skip past all tasks in the parallel phases
                    max_line = 0
                    for phase in parallel_phases:
                        _, end = _phase_line_range(config.plan_path, phase)
                        max_line = max(max_line, end)
                    min_line = max_line + 1
                    continue

            self.state = State.RUNNING
            self.current_task = task.text
            self.task_start_time = time.time()
            out("━" * 60)
            out(f"📋 Task: {task.text}")
            out("━" * 60)

            if config.dry_run:
                out("[dry-run] Would execute this task")
                # Interruptible delay — /skip or /kill can break out early
                if self.skip_event.wait(timeout=0.3):
                    self.skip_event.clear()
                    out("⏭️  Skipped")
                    min_line = task.line_num + 1
                    continue
                if self.pause_event.is_set():
                    # Paused during the task — loop back to wait
                    min_line = task.line_num
                    continue
                check_off_task(config.plan_path, task.line_num)
                self._completed += 1
                min_line = task.line_num + 1
            else:
                # ── Real execution ──────────────────────────────────
                # Collect queued guidance
                guidance_parts = []
                if user_guidance:
                    guidance_parts.append(user_guidance)
                    user_guidance = ""
                while self.guidance_queue:
                    guidance_parts.append(self.guidance_queue.popleft())
                inbox_msg = read_inbox()
                if inbox_msg:
                    guidance_parts.append(inbox_msg)
                    out(f"  📬 Inbox: {inbox_msg}")
                guidance = "\n".join(guidance_parts)

                try:
                    # Load learnings fresh before each task (other iterations may have appended)
                    learnings_content = load_learnings(config.learnings_path)

                    if config.batch_mode and is_batch_start(config.plan_path, task.line_num):
                        batch_tasks = collect_batch(config.plan_path, task.line_num)
                        out(f"📦 BATCH ({len(batch_tasks)} tasks):")
                        for t in batch_tasks:
                            out(f"   - {t.text}")

                        review_base = self._get_review_base()
                        plan_content = trim_plan_for_task(config.plan_path, task.line_num)
                        prompt = build_batch_prompt(
                            batch_tasks, plan_content, config,
                            coding_rules, recent_commits, guidance,
                            project_context=project_context,
                            learnings_content=learnings_content)

                        result = run_claude(prompt, config, on_output=out,
                                            proc_register=self._register_proc,
                                            timeout=config.task_timeout)
                        self.current_proc = None
                        self.total_cost += result.cost
                        self._task_results.append((f"BATCH: {batch_tasks[0].text}", result))

                        new_task = find_next_task(config.plan_path, min_line=task.line_num, phase=config.phase)
                        if new_task and new_task.text == batch_tasks[0].text:
                            self._failed += len(batch_tasks)
                            consecutive_fails += 1
                            min_line = task.line_num
                            out("\n❌ Batch failed (task not checked off)")
                            for t in batch_tasks:
                                append_learning(config.learnings_path, t.text, passed=False)
                        else:
                            plan_lines = Path(config.plan_path).read_text().splitlines()
                            actually_completed = sum(
                                1 for t in batch_tasks
                                if t.line_num - 1 < len(plan_lines)
                                and not _TASK_RE.match(plan_lines[t.line_num - 1])
                            )
                            self._completed += actually_completed
                            consecutive_fails = 0
                            min_line = task.line_num + 1
                            out("\n✅ Batch complete")
                            if not config.skip_review and review_base:
                                r_out = lambda t: out(t, style="steel_blue1")
                                r_out("🔍 Reviewing changes...")
                                review_result = run_review(
                                    review_base, batch_tasks[0].text, config, out=r_out)
                                fix_review_issues(review_result, config, out=r_out)
                                r_out("🔍 Review complete")

                        if needs_followup(result.text):
                            out("⚠️  Agent may need input — check output above")

                    else:
                        # Single task
                        review_base = self._get_review_base()
                        plan_content = trim_plan_for_task(config.plan_path, task.line_num)
                        prompt = build_single_prompt(
                            task, plan_content, config,
                            coding_rules, recent_commits, guidance,
                            project_context=project_context,
                            learnings_content=learnings_content)

                        result = run_claude(prompt, config, on_output=out,
                                            proc_register=self._register_proc,
                                            timeout=config.task_timeout)
                        self.current_proc = None
                        self.total_cost += result.cost
                        self._task_results.append((task.text, result))

                        new_task = find_next_task(config.plan_path, min_line=task.line_num, phase=config.phase)
                        if new_task and new_task.text == task.text:
                            self._failed += 1
                            consecutive_fails += 1
                            min_line = task.line_num
                            out("\n❌ Task failed (task not checked off)")
                            append_learning(config.learnings_path, task.text, passed=False)
                        else:
                            self._completed += 1
                            consecutive_fails = 0
                            min_line = task.line_num + 1
                            out("\n✅ Task complete")
                            if not config.skip_review and review_base:
                                r_out = lambda t: out(t, style="steel_blue1")
                                r_out("🔍 Reviewing changes...")
                                review_result = run_review(
                                    review_base, task.text, config, out=r_out)
                                fix_review_issues(review_result, config, out=r_out)
                                r_out("🔍 Review complete")

                        if needs_followup(result.text):
                            out("⚠️  Agent may need input — check output above")

                except UsageLimitExceeded as e:
                    self.current_proc = None
                    out(f"\n🛑 Claude usage limit hit — stopping.")
                    out(f"   ({e})")
                    break

                except AgentTimeout:
                    self.current_proc = None
                    elapsed_mins = int((time.time() - self.task_start_time) / 60)
                    out(f"\n⏰ Task timed out after {elapsed_mins}m — launching rescue agent...")
                    append_learning(config.learnings_path, task.text + " [TIMED OUT]", passed=False)

                    # Build rescue prompt and run a fresh agent (no timeout on rescue)
                    plan_content = trim_plan_for_task(config.plan_path, task.line_num)
                    rescue_learnings = load_learnings(config.learnings_path)
                    rescue_prompt = build_rescue_prompt(
                        task, plan_content, config,
                        coding_rules, recent_commits, elapsed_mins,
                        learnings_content=rescue_learnings,
                        project_context=project_context)

                    self.task_start_time = time.time()
                    out("🚑 Rescue agent starting...")
                    try:
                        rescue_result = run_claude(
                            rescue_prompt, config, on_output=out,
                            proc_register=self._register_proc)
                        self.current_proc = None
                        self.total_cost += rescue_result.cost
                        self._task_results.append((f"RESCUE: {task.text}", rescue_result))

                        new_task = find_next_task(config.plan_path, min_line=task.line_num, phase=config.phase)
                        if new_task and new_task.text == task.text:
                            self._failed += 1
                            consecutive_fails += 1
                            min_line = task.line_num
                            out("\n❌ Rescue agent also failed")
                            append_learning(config.learnings_path, task.text + " [RESCUE FAILED]", passed=False)
                        else:
                            self._completed += 1
                            consecutive_fails = 0
                            min_line = task.line_num + 1
                            out("\n✅ Rescue agent completed the task!")
                    except AgentKilled:
                        self.current_proc = None
                        out("🔪 Rescue agent killed")
                        min_line = task.line_num
                    except AgentTimeout:
                        self.current_proc = None
                        out("⏰ Rescue agent also timed out — moving on")
                        self._failed += 1
                        consecutive_fails += 1
                        min_line = task.line_num
                    continue

                except AgentKilled:
                    self.current_proc = None
                    if self.skip_event.is_set():
                        self.skip_event.clear()
                        out("⏭️  Skipped")
                        min_line = task.line_num + 1
                    else:
                        out("🔪 Agent killed")
                        min_line = task.line_num
                    continue

            # Consecutive failure check
            if consecutive_fails >= MAX_CONSECUTIVE_FAILS:
                out(f"\n🛑 Stopping: {MAX_CONSECUTIVE_FAILS} consecutive failures.")
                out("   Fix the issue manually, then re-run ralph.")
                break

            # Refresh git history periodically
            if self._completed > 0 and self._completed % 3 == 0:
                recent_commits = get_recent_commits()

            # COUNTDOWN between tasks
            if config.delay > 0:
                self.state = State.COUNTDOWN
                countdown_end = time.time() + config.delay
                while time.time() < countdown_end:
                    if self.skip_event.is_set():
                        self.skip_event.clear()
                        break
                    if self.pause_event.is_set():
                        break
                    if not self.is_running:
                        return
                    time.sleep(0.1)
                # Collect guidance queued during countdown
                while self.guidance_queue:
                    user_guidance += self.guidance_queue.popleft() + "\n"
                # If paused during countdown, loop back to let
                # the pause handler at the top decide min_line
                if self.pause_event.is_set():
                    continue


        # Final summary
        out("")
        out("━" * 60)
        out(f"🏁 Ralph finished — {self._completed} completed, {self._failed} failed")
        out(f"   ⏱ {elapsed(self.start_time)} | 💰 ${self.total_cost:.4f}")
        out(f"   📄 Log: {config.log_path}")

        # Context usage summary
        if self._task_results:
            peaks = [r.peak_input_tokens for _, r in self._task_results if r.peak_input_tokens > 0]
            total_out = sum(r.output_tokens for _, r in self._task_results)
            total_turns = sum(r.num_turns for _, r in self._task_results)
            if peaks:
                avg_peak = sum(peaks) / len(peaks)
                max_peak = max(peaks)
                max_task = next(
                    name for name, r in self._task_results
                    if r.peak_input_tokens == max_peak
                )
                # Truncate task name for display
                if len(max_task) > 50:
                    max_task = max_task[:47] + "..."
                out(f"   📊 Context: avg {format_tokens(int(avg_peak))} peak | "
                    f"max {format_tokens(max_peak)} ({max_task})")
                out(f"   📊 Totals: {total_turns} turns | "
                    f"{format_tokens(total_out)} output")

                # Per-task breakdown
                out("")
                out("   Task context breakdown:")
                for i, (name, r) in enumerate(self._task_results, 1):
                    short_name = name[:45] + "..." if len(name) > 45 else name
                    out(f"   {i:2d}. {format_tokens(r.peak_input_tokens):>5s} peak | "
                        f"{r.num_turns:2d} turns | "
                        f"{format_tokens(r.output_tokens):>5s} out | "
                        f"${r.cost:.4f} | {short_name}")

        out("━" * 60)

        # Close log file
        if self._log_file:
            self._log_file.close()
            self._log_file = None

        time.sleep(1)
        self.exit()


# ─── Review (codex / claude fallback) ───────────────────────────────────────

def run_review(base_sha: str, task_text: str, config: Config,
               out: Callable[[str], None] = print) -> str:
    if config.skip_review:
        return "LGTM (review skipped)"

    # Diff working tree (committed + uncommitted) against review base
    result = subprocess.run(
        ["git", "diff", base_sha],
        capture_output=True, text=True,
    )
    diff = result.stdout.strip()
    if not diff:
        out("  no diff — working tree matches review base")
        return "LGTM — no changes to review"

    # Log diff stats
    diff_stat = subprocess.run(
        ["git", "diff", "--stat", base_sha],
        capture_output=True, text=True,
    )
    stat_summary = diff_stat.stdout.strip().splitlines()
    if stat_summary:
        out(f"  diff: {stat_summary[-1].strip()}")  # summary line e.g. "3 files changed, 40 insertions(+), 5 deletions(-)"

    # Reviewer selection logic
    use_codex = False
    if config.reviewer == "codex":
        use_codex = True
        out("  reviewer: codex (explicit config)")
    elif config.reviewer == "claude":
        use_codex = False
        out("  reviewer: claude (explicit config)")
    elif config.reviewer == "auto":
        use_codex = subprocess.run(
            ["which", "codex"], capture_output=True
        ).returncode == 0
        if use_codex:
            out("  reviewer: codex (auto-detected on PATH)")
        else:
            out("  reviewer: claude (codex not found on PATH)")

    if use_codex:
        cmd = ["codex", "review", "--base", base_sha]
        out(f"  running: {' '.join(cmd)}")
        t0 = time.time()
        try:
            result = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=300,
            )
            elapsed = time.time() - t0
            output = result.stdout + result.stderr
            out(f"  codex finished in {elapsed:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except Exception as exc:
            elapsed = time.time() - t0
            out(f"  codex FAILED after {elapsed:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (codex error: {exc})"
    else:
        review_prompt = f"""Review this diff for bugs, edge cases, and issues the implementing agent may not have considered. Be specific about file and line. If the code looks good, just say LGTM.

## Task Context
{task_text}

## Diff
{diff}"""

        # Try Claude first
        out("  🔍 Claude reviewing changes...")
        t0 = time.time()
        try:
            result = subprocess.run(
                ["claude", "-p", "--model", "claude-opus-4-6", "--max-turns", "5",
                 "--dangerously-skip-permissions"],
                input=review_prompt, capture_output=True, text=True, timeout=300,
            )
            elapsed_t = time.time() - t0
            output = result.stdout + result.stderr
            # Check for usage limit in review output
            if _USAGE_LIMIT_RE.search(output) or (result.returncode and not output.strip()):
                raise UsageLimitExceeded(output or f"exit code {result.returncode}")
            out(f"  claude finished in {elapsed_t:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except UsageLimitExceeded:
            elapsed_t = time.time() - t0
            out(f"  claude hit usage limit after {elapsed_t:.1f}s — falling back to Gemini...")
        except Exception as exc:
            elapsed_t = time.time() - t0
            out(f"  claude FAILED after {elapsed_t:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (claude error: {exc})"

        # Gemini fallback for review
        out("  🔍 Gemini reviewing changes...")
        t0 = time.time()
        try:
            result = subprocess.run(
                ["gemini", "-p", review_prompt, "--yolo"],
                capture_output=True, text=True, timeout=300,
            )
            elapsed_t = time.time() - t0
            output = result.stdout + result.stderr
            out(f"  gemini finished in {elapsed_t:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except Exception as exc:
            elapsed_t = time.time() - t0
            out(f"  gemini FAILED after {elapsed_t:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (gemini error: {exc})"


def has_review_issues(output: str) -> bool:
    if not output:
        return False
    last_lines = "\n".join(output.strip().splitlines()[-5:])
    return not bool(re.search(
        r"(LGTM|no issues|looks good|no bugs|no discrete|did not find|did not identify)",
        last_lines, re.IGNORECASE,
    ))


def fix_review_issues(review_output: str, config: Config,
                      out: Callable[[str], None] = print) -> None:
    if not has_review_issues(review_output):
        out("  ✅ Review passed — LGTM")
        # Show first few lines of what the reviewer actually said
        lines = [l for l in review_output.strip().splitlines() if l.strip()]
        for line in lines[:3]:
            out(f"    | {line}")
        if len(lines) > 3:
            out(f"    | ... ({len(lines) - 3} more lines)")
        return

    out("  🔧 Fixing review findings...")
    for line in review_output.splitlines()[:20]:
        out(f"    {line}")

    fix_prompt = f"""A code reviewer found the following issues. Fix each one. Commit when done.

## Review Findings
{review_output}

## Working Directory
{os.getcwd()}"""

    try:
        subprocess.run(
            ["claude", "-p", "--max-turns", "15", "--dangerously-skip-permissions"],
            input=fix_prompt, capture_output=True, text=True, timeout=600,
        )
    except Exception:
        pass


# ─── Interactive launcher ────────────────────────────────────────────────────


def _has_fzf() -> bool:
    """Check whether fzf is installed."""
    return shutil.which("fzf") is not None


def _fzf_select(choices: list[str], prompt: str, preview: str = "") -> str:
    """Run fzf and return the selected item, or "" if cancelled."""
    cmd = ["fzf", "--prompt", prompt, "--height", "~20", "--reverse"]
    if preview:
        cmd += ["--preview", preview]
    try:
        proc = subprocess.run(
            cmd, input="\n".join(choices),
            capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _menu_select(choices: list[str], prompt: str) -> str:
    """Numbered-menu fallback when fzf is unavailable."""
    print(f"\n  {prompt}")
    for i, c in enumerate(choices, 1):
        marker = " (default)" if i == 1 else ""
        print(f"    {i}. {c}{marker}")
    while True:
        try:
            raw = input(f"  Choice [1-{len(choices)}, default=1]: ").strip()
        except (EOFError, KeyboardInterrupt):
            return choices[0]
        if not raw:
            return choices[0]
        try:
            idx = int(raw)
            if 1 <= idx <= len(choices):
                return choices[idx - 1]
        except ValueError:
            pass
        print(f"    Enter 1\u2013{len(choices)}")


def _pick(choices: list[str], prompt: str, preview: str = "",
          default: str = "") -> str:
    """Present choices via fzf (preferred) or numbered menu (fallback).

    *default* is moved to the top of the list so it is pre-highlighted.
    """
    if not choices:
        return ""
    if default and default in choices:
        choices = [default] + [c for c in choices if c != default]
    if _has_fzf():
        result = _fzf_select(choices, prompt, preview)
        if result:
            return result
        # Esc / Ctrl-C in fzf — abort
        print("Selection cancelled.", file=sys.stderr)
        sys.exit(1)
    return _menu_select(choices, prompt)


def _collect_plan_files() -> list[str]:
    """Gather .md plan files from cwd, ./plans/, and ~/.claude/plans/."""
    seen: set[str] = set()
    plans: list[str] = []

    def _add(p: Path) -> None:
        resolved = str(p.resolve())
        if resolved not in seen:
            seen.add(resolved)
            plans.append(str(p))

    for name in ("plan.md", "PLAN.md"):
        p = Path(name)
        if p.is_file():
            _add(p)
    for d in (Path("plans"), Path.home() / ".claude" / "plans"):
        if d.is_dir():
            for p in sorted(d.glob("*.md")):
                _add(p)
    return plans


def interactive_config(config: Config, explicit: dict[str, bool]) -> Config:
    """Prompt for any config values not already set via CLI flags or env vars.

    Uses fzf when available; falls back to a simple numbered menu.
    """
    # ── Plan selector ──
    if not explicit["plan_path"]:
        plans = _collect_plan_files()
        if not plans:
            print("Error: no plan files found (./plans/, ~/.claude/plans/, "
                  "or ./plan.md)", file=sys.stderr)
            sys.exit(1)
        if len(plans) == 1:
            config.plan_path = str(Path(plans[0]).resolve())
            print(f"  Auto-selected plan: {plans[0]}")
        else:
            selected = _pick(plans, "Plan: ", preview="head -20 {}")
            config.plan_path = str(Path(selected).resolve())

    # ── Model selector ──
    if not explicit["model"]:
        presets = list(MODEL_PRESETS.keys())
        selected = _pick(presets, "Model: ", default="opus-high")
        if selected in MODEL_PRESETS:
            config.model, config.effort = MODEL_PRESETS[selected]
        else:
            config.model = selected

    # ── Review toggle ──
    if not explicit["review"]:
        selected = _pick(["no", "yes"], "Review after each task? ", default="no")
        config.skip_review = (selected != "yes")

    # ── Reviewer selector (only when review is enabled) ──
    if not config.skip_review and not explicit["reviewer"]:
        selected = _pick(["auto", "claude", "codex"], "Reviewer: ", default="auto")
        config.reviewer = selected

    return config


# ─── Main loop ──────────────────────────────────────────────────────────────

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
