#!/usr/bin/env python3
# Dependency: pip install textual (required for TUI mode)
"""ralph.py — Execute a plan file task-by-task using claude -p.

Each task gets a fresh claude invocation with zero context carryover.
The plan file on disk is the only shared state.

Interactive features (TUI mode):
  Guidance:  type in the input field to queue guidance for the next task
  Commands:  /stop, /skip, /kill, /pause, /resume, /retry, /plan
  Inbox:     echo "guidance" > .ralph-inbox  (from any terminal, any time)
  Follow-up: ralph detects when an agent asks a question and shows it in the log
"""

import argparse
import enum
import json
import os
import re
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


@dataclass
class Config:
    plan_path: str = ""
    work_dir: str = ""
    max_turns: int = 50
    delay: int = 5
    dry_run: bool = False
    batch_mode: bool = False
    skip_review: bool = True
    reviewer: str = "auto"  # auto|codex|claude
    model: str = ""
    effort: str = ""

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


def find_next_task(plan_path: str, min_line: int = 1) -> Task | None:
    with open(plan_path) as f:
        for i, line in enumerate(f, 1):
            if i < min_line:
                continue
            m = _TASK_RE.match(line)
            if m:
                text = m.group(2)
                return Task(line_num=i, text=text, criterion=extract_criterion(text))
    return None


def count_tasks(plan_path: str) -> tuple[int, int]:
    done = 0
    total = 0
    with open(plan_path) as f:
        for line in f:
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


def build_single_prompt(task: Task, plan_content: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        user_guidance: str) -> str:
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
- When done, respond with a brief summary of what you did."""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

{user_guidance}"""

    return prompt


def build_batch_prompt(tasks: list[Task], plan_content: str, config: Config,
                       coding_rules: str, recent_commits: str,
                       user_guidance: str) -> str:
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
- When done, respond with a brief summary of what you did for each task."""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

{user_guidance}"""

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
               proc_register: Callable[[subprocess.Popen], None] | None = None) -> ClaudeResult:
    cmd = [
        "claude", "-p",
        *config.claude_model_flags(),
        "--max-turns", str(config.max_turns),
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

        # Tool use events
        if event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    input_data = block.get("input", {})
                    on_output(format_tool_detail(name, input_data))

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
                on_output(f"  💰 Cost: ${result.cost}")

    proc.wait()
    if proc.returncode is not None and proc.returncode < 0:
        raise AgentKilled()
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


def status_line(start_time: float, total_cost: float, plan_path: str) -> None:
    done, total = count_tasks(plan_path)
    print(f"  ⏱ {elapsed(start_time)} | 💰 ${total_cost:.8f} | 📋 {done}/{total} tasks")


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
        self.total_cost: float = 0.0
        self.current_task: str = ""
        self._completed: int = 0
        self._failed: int = 0
        self.guidance_queue: deque[str] = deque()
        self.current_proc: subprocess.Popen | None = None
        self.skip_event = threading.Event()
        self.pause_event = threading.Event()
        self.resume_event = threading.Event()
        self._stash_created: bool = False
        self._retry: bool = False
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

    def output(self, text: str = "") -> None:
        """Write a line to the RichLog widget (thread-safe)."""
        self.query_one("#log", RichLog).write(text)

    def update_status(self) -> None:
        """Refresh the status bar with elapsed time, cost, progress, state, task."""
        done, total = count_tasks(self.config.plan_path)
        parts = [
            f"⏱ {elapsed(self.start_time)}",
            f"💰 ${self.total_cost:.4f}",
            f"📋 {done}/{total}",
            self.state.value,
        ]
        if self.current_task:
            parts.append(self.current_task)
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
        out("")

        # Pre-load context
        coding_rules = load_coding_rules()
        recent_commits = get_recent_commits()
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

            task = find_next_task(config.plan_path, min_line=min_line)
            if task is None:
                self.current_task = ""
                self.state = State.DONE
                out(f"\n✅ All tasks complete! ({self._completed} completed)")
                break

            last_task = task

            # Check if paused between finding task and starting it
            # (avoids overwriting PAUSED state set by cmd_kill)
            if self.pause_event.is_set():
                min_line = task.line_num
                continue

            self.state = State.RUNNING
            self.current_task = task.text
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
                    if config.batch_mode and is_batch_start(config.plan_path, task.line_num):
                        batch_tasks = collect_batch(config.plan_path, task.line_num)
                        out(f"📦 BATCH ({len(batch_tasks)} tasks):")
                        for t in batch_tasks:
                            out(f"   - {t.text}")

                        review_base = self._get_review_base()
                        plan_content = trim_plan_for_task(config.plan_path, task.line_num)
                        prompt = build_batch_prompt(
                            batch_tasks, plan_content, config,
                            coding_rules, recent_commits, guidance)

                        result = run_claude(prompt, config, on_output=out,
                                            proc_register=self._register_proc)
                        self.current_proc = None
                        self.total_cost += result.cost

                        new_task = find_next_task(config.plan_path, min_line=task.line_num)
                        if new_task and new_task.text == batch_tasks[0].text:
                            self._failed += len(batch_tasks)
                            consecutive_fails += 1
                            out("\n❌ Batch failed (task not checked off)")
                        else:
                            self._completed += len(batch_tasks)
                            consecutive_fails = 0
                            out("\n✅ Batch complete")
                            if not config.skip_review and review_base:
                                auto_commit()
                                out("🔍 Reviewing changes...")
                                review_out = run_review(
                                    review_base, batch_tasks[0].text, config, out=out)
                                fix_review_issues(review_out, config, out=out)

                        if needs_followup(result.text):
                            out("⚠️  Agent may need input — check output above")

                    else:
                        # Single task
                        review_base = self._get_review_base()
                        plan_content = trim_plan_for_task(config.plan_path, task.line_num)
                        prompt = build_single_prompt(
                            task, plan_content, config,
                            coding_rules, recent_commits, guidance)

                        result = run_claude(prompt, config, on_output=out,
                                            proc_register=self._register_proc)
                        self.current_proc = None
                        self.total_cost += result.cost

                        new_task = find_next_task(config.plan_path, min_line=task.line_num)
                        if new_task and new_task.text == task.text:
                            self._failed += 1
                            consecutive_fails += 1
                            out("\n❌ Task failed (task not checked off)")
                        else:
                            self._completed += 1
                            consecutive_fails = 0
                            out("\n✅ Task complete")
                            if not config.skip_review and review_base:
                                auto_commit()
                                out("🔍 Reviewing changes...")
                                review_out = run_review(
                                    review_base, task.text, config, out=out)
                                fix_review_issues(review_out, config, out=out)

                        if needs_followup(result.text):
                            out("⚠️  Agent may need input — check output above")

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

            min_line = task.line_num + 1

        time.sleep(1)
        self.exit()


# ─── Review (codex / claude fallback) ───────────────────────────────────────

def auto_commit() -> None:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        capture_output=True, text=True,
    )
    if result.stdout.strip():
        subprocess.run(["git", "add", "-A"], capture_output=True)
        subprocess.run(
            ["git", "commit", "-m", "ralph: auto-commit before review"],
            capture_output=True,
        )


def run_review(base_sha: str, task_text: str, config: Config,
               out: Callable[[str], None] = print) -> str:
    if config.skip_review:
        return "LGTM (review skipped)"

    result = subprocess.run(
        ["git", "diff", f"{base_sha}..HEAD"],
        capture_output=True, text=True,
    )
    diff = result.stdout.strip()
    if not diff:
        return "LGTM — no changes to review"

    use_codex = False
    if config.reviewer == "codex":
        use_codex = True
    elif config.reviewer == "claude":
        use_codex = False
    elif config.reviewer == "auto":
        use_codex = subprocess.run(
            ["which", "codex"], capture_output=True
        ).returncode == 0

    if use_codex:
        out("  🔍 Codex reviewing changes...")
        try:
            result = subprocess.run(
                ["codex", "review", "--base", base_sha],
                capture_output=True, text=True, timeout=300,
            )
            return result.stdout + result.stderr
        except Exception:
            return "LGTM (codex error)"
    else:
        out("  🔍 Claude reviewing changes...")
        review_prompt = f"""Review this diff for bugs, edge cases, and issues the implementing agent may not have considered. Be specific about file and line. If the code looks good, just say LGTM.

## Task Context
{task_text}

## Diff
{diff}"""
        try:
            result = subprocess.run(
                ["claude", "-p", "--model", "claude-opus-4-6", "--max-turns", "5",
                 "--dangerously-skip-permissions"],
                input=review_prompt, capture_output=True, text=True, timeout=300,
            )
            return result.stdout + result.stderr
        except Exception:
            return "LGTM (claude error)"


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


# ─── Main loop ──────────────────────────────────────────────────────────────

def parse_args() -> Config:
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
  RALPH_MAX_TURNS  Same as --max-turns
  RALPH_DELAY      Same as --delay
  RALPH_MODEL      Same as --model
  RALPH_REVIEWER   Same as --reviewer""",
    )
    parser.add_argument("plan_path", nargs="?", default="",
                        help="Path to the plan file")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be executed without running claude")
    parser.add_argument("--max-turns", type=int,
                        default=int(os.environ.get("RALPH_MAX_TURNS", "50")),
                        help="Max agentic turns per task (default: 50)")
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

    args = parser.parse_args()

    config = Config(
        max_turns=args.max_turns,
        delay=args.delay,
        dry_run=args.dry_run,
        batch_mode=args.batch,
        reviewer=args.reviewer,
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

    # Find plan
    config.plan_path = find_plan(args.plan_path)
    config.work_dir = os.getcwd()

    return config


def main() -> None:
    config = parse_args()
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
