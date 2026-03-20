#!/usr/bin/env python3
# Dependency: pip install textual (required for TUI mode)
"""ralph.py — Execute a plan file task-by-task using claude -p.

Each task gets a fresh claude invocation with zero context carryover.
The plan file on disk is the only shared state.

Interactive features:
  Inbox:     echo "guidance" > .ralph-inbox  (from any terminal, any time)
  Countdown: type during the between-task pause to add guidance
  Follow-up: ralph detects when an agent asks a question and pauses for you
"""

import argparse
import json
import os
import re
import select
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
from textual.widgets import RichLog, Static, Input
from textual import work

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
               on_output: Callable[[str], None] = print) -> ClaudeResult:
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


def interactive_countdown(task_desc: str, delay: int) -> tuple[int, str]:
    """Returns (action, guidance).
    action: 0=proceed, 1=skip, 2=stop.
    guidance: user-typed text to pass to agent.
    """
    guidance = ""

    # Check inbox first
    inbox_msg = read_inbox()
    if inbox_msg:
        print(f"  📬 Inbox: {inbox_msg}")
        guidance += inbox_msg + "\n"

    if delay <= 0:
        return 0, guidance

    sys.stdout.write(f"  > ({delay}s) guidance, 'skip', 'stop', or Enter: ")
    sys.stdout.flush()

    # Use select for timeout on stdin
    user_input = ""
    try:
        rlist, _, _ = select.select([sys.stdin], [], [], delay)
        if rlist:
            user_input = sys.stdin.readline().rstrip("\n")
    except (OSError, ValueError):
        # stdin not selectable (e.g., not a terminal)
        time.sleep(delay)

    # Clear the countdown line
    sys.stdout.write(f"\r{' ' * 80}\r")
    sys.stdout.flush()

    if user_input == "skip":
        return 1, ""
    if user_input == "stop":
        return 2, ""
    if user_input:
        guidance += user_input + "\n"

    return 0, guidance


def handle_followup(result_text: str) -> str:
    """If agent asked a question, pause and get user reply. Returns guidance."""
    if not needs_followup(result_text):
        return ""

    print()
    print("━" * 60)
    print("⚠️  Agent is asking for input:")
    # Show last 5 lines
    last_lines = result_text.strip().splitlines()[-5:]
    for l in last_lines:
        print(f"  {l}")
    print("━" * 60)
    sys.stdout.write("  > reply, 'skip', or 'stop': ")
    sys.stdout.flush()

    try:
        reply = input()
    except EOFError:
        return ""

    if reply == "skip":
        return ""
    if reply == "stop":
        print("🛑 Stopped by user.")
        sys.exit(0)
    return reply


# ─── Background stdin reader ────────────────────────────────────────────────

_input_thread: threading.Thread | None = None
_input_stop = threading.Event()


def start_input_reader():
    global _input_thread
    if not sys.stdin.isatty():
        return

    def reader():
        try:
            tty = open("/dev/tty", "r")
        except OSError:
            return
        try:
            while not _input_stop.is_set():
                try:
                    rlist, _, _ = select.select([tty], [], [], 0.5)
                except (OSError, ValueError):
                    break
                if rlist:
                    line = tty.readline().strip()
                    if not line:
                        continue
                    with open(INBOX_FILE, "a") as f:
                        f.write(line + "\n")
                    # Echo to tty
                    try:
                        tty_out = open("/dev/tty", "w")
                        tty_out.write(f"  📬 Queued: {line}\n")
                        tty_out.close()
                    except OSError:
                        pass
        finally:
            tty.close()

    _input_thread = threading.Thread(target=reader, daemon=True)
    _input_thread.start()


def stop_input_reader():
    global _input_thread
    _input_stop.set()
    if _input_thread is not None:
        _input_thread.join(timeout=1)
        _input_thread = None
    _input_stop.clear()


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
        height: 1;
    }
    """

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
        self.command_handlers: dict[str, Callable[[str], None]] = {
            "stop": self.cmd_stop,
            "skip": self.cmd_skip,
        }

    def output(self, text: str = "") -> None:
        """Write a line to the RichLog widget (thread-safe)."""
        self.query_one("#log", RichLog).write(text)

    def update_status(self) -> None:
        """Refresh the status bar with elapsed time, cost, progress, task."""
        done, total = count_tasks(self.config.plan_path)
        parts = [
            f"⏱ {elapsed(self.start_time)}",
            f"💰 ${self.total_cost:.4f}",
            f"📋 {done}/{total}",
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

    @work(thread=True)
    def _run_tasks(self) -> None:
        config = self.config
        out = self.output

        # Banner
        if RALPH_ASCII.is_file():
            out(RALPH_ASCII.read_text())
        out(f"Plan: {config.plan_path}")
        out(f"Working directory: {config.work_dir}")
        out("")

        min_line = 1
        while True:
            task = find_next_task(config.plan_path, min_line=min_line)
            if task is None:
                self.current_task = ""
                out(f"\n✅ All tasks complete! ({self._completed} completed)")
                break

            self.current_task = task.text
            out("━" * 60)
            out(f"📋 Task: {task.text}")
            out("━" * 60)

            if config.dry_run:
                out("[dry-run] Would execute this task")
                # Interruptible delay — /skip can break out early
                if self.skip_event.wait(timeout=0.3):
                    self.skip_event.clear()
                    out("⏭️  Skipped")
                    min_line = task.line_num + 1
                    continue
                check_off_task(config.plan_path, task.line_num)
                self._completed += 1
                min_line = task.line_num + 1
                continue

            # Real execution will be wired in later phases
            break

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


def run_review(base_sha: str, task_text: str, config: Config) -> str:
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
        print("  🔍 Codex reviewing changes...")
        try:
            result = subprocess.run(
                ["codex", "review", "--base", base_sha],
                capture_output=True, text=True, timeout=300,
            )
            return result.stdout + result.stderr
        except Exception:
            return "LGTM (codex error)"
    else:
        print("  🔍 Claude reviewing changes...")
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


def fix_review_issues(review_output: str, config: Config) -> None:
    if not has_review_issues(review_output):
        print("  ✅ Review passed — LGTM")
        return

    print("  🔧 Fixing review findings...")
    # Show first 20 lines
    for line in review_output.splitlines()[:20]:
        print(f"    {line}")

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

Interactive features:
  Inbox:     echo 'guidance' > .ralph-inbox  (from any terminal, any time)
  Countdown: type during the pause between tasks to add guidance
  Follow-up: ralph pauses when an agent asks a question

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

    # TUI mode for dry-run (will expand to all modes in later phases)
    if config.dry_run:
        app = RalphApp(config)
        app.run()
        return

    # Banner
    print()
    if RALPH_ASCII.is_file():
        print(RALPH_ASCII.read_text(), end="")
    print(f"Plan: {config.plan_path}")
    print(f"Working directory: {config.work_dir}")
    print(f"Inbox: {config.work_dir}/{INBOX_FILE}")
    if config.model:
        model_info = config.model
        if config.effort:
            model_info += f" (effort: {config.effort})"
        print(f"Model: {model_info}")
    if not config.skip_review:
        print(f"Review: enabled (reviewer: {config.reviewer})")
    print()

    # Pre-load context
    coding_rules = load_coding_rules()
    recent_commits = get_recent_commits()

    # Stats
    completed = 0
    failed = 0
    consecutive_fails = 0
    total_cost = 0.0
    start_time = time.time()
    claude_proc: subprocess.Popen | None = None

    # Signal handler
    def sigint_handler(signum, frame):
        nonlocal total_cost
        print()
        stop_input_reader()
        print(f"🛑 Stopped after {completed} tasks, {failed} failed. "
              f"⏱ {elapsed(start_time)} | 💰 ${total_cost:.8f}")
        # Stash uncommitted changes
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True, text=True,
        )
        if result.stdout.strip():
            stash_result = subprocess.run(
                ["git", "stash", "push", "-u", "-m",
                 f"ralph: interrupted after {completed} tasks completed"],
                capture_output=True, text=True,
            )
            if stash_result.returncode == 0:
                print("📦 Changes stashed (git stash pop to restore)")
            else:
                print("⚠️  git stash failed — changes left in working tree")
        sys.exit(0)

    signal.signal(signal.SIGINT, sigint_handler)

    print("📬 Type a message any time — it will be sent to the next agent.")
    print()

    user_guidance = ""

    while True:
        task = find_next_task(config.plan_path)
        if task is None:
            print(f"✅ All tasks complete! ({completed} completed, {failed} failed)")
            status_line(start_time, total_cost, config.plan_path)
            break

        # Check for batch
        if config.batch_mode and is_batch_start(config.plan_path, task.line_num):
            batch_tasks = collect_batch(config.plan_path, task.line_num)
            print("━" * 60)
            print(f"📦 BATCH ({len(batch_tasks)} tasks):")
            for t in batch_tasks:
                print(f"   - {t.text}")
            print("━" * 60)

            if config.dry_run:
                print(f"[dry-run] Would execute batch of {len(batch_tasks)} tasks")
                for t in batch_tasks:
                    check_off_task(config.plan_path, t.line_num)
                completed += len(batch_tasks)
                continue

            action, guidance = interactive_countdown(
                f"batch of {len(batch_tasks)} tasks", config.delay)
            user_guidance = guidance
            if action == 1:
                print("  ⏭️  Skipped")
                continue
            if action == 2:
                print("🛑 Stopped by user.")
                break

            review_base = ""
            try:
                review_base = subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    capture_output=True, text=True,
                ).stdout.strip()
            except Exception:
                pass

            plan_content = trim_plan_for_task(config.plan_path, task.line_num)
            prompt = build_batch_prompt(
                batch_tasks, plan_content, config,
                coding_rules, recent_commits, user_guidance)

            print()
            start_input_reader()
            result = run_claude(prompt, config)
            stop_input_reader()
            total_cost += result.cost

            # Check success: did first task get checked off?
            new_task = find_next_task(config.plan_path)
            first_batch_text = batch_tasks[0].text
            if new_task and new_task.text == first_batch_text:
                failed += len(batch_tasks)
                consecutive_fails += 1
                print()
                print("❌ Batch failed (task not checked off)")
            else:
                completed += len(batch_tasks)
                consecutive_fails = 0
                print()
                print("✅ Batch complete")
                if not config.skip_review and review_base:
                    auto_commit()
                    review_out = run_review(review_base, first_batch_text, config)
                    fix_review_issues(review_out, config)

            status_line(start_time, total_cost, config.plan_path)

            # Follow-up detection
            user_guidance = handle_followup(result.text)

        else:
            # Single task
            print("━" * 60)
            print(f"📋 Task: {task.text}")
            print("━" * 60)

            if config.dry_run:
                print("[dry-run] Would execute this task")
                check_off_task(config.plan_path, task.line_num)
                completed += 1
                continue

            action, guidance = interactive_countdown(task.text, config.delay)
            user_guidance = guidance
            if action == 1:
                print("  ⏭️  Skipped")
                continue
            if action == 2:
                print("🛑 Stopped by user.")
                break

            review_base = ""
            try:
                review_base = subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    capture_output=True, text=True,
                ).stdout.strip()
            except Exception:
                pass

            plan_content = trim_plan_for_task(config.plan_path, task.line_num)
            prompt = build_single_prompt(
                task, plan_content, config,
                coding_rules, recent_commits, user_guidance)

            print()
            start_input_reader()
            result = run_claude(prompt, config)
            stop_input_reader()
            total_cost += result.cost

            # Check success
            new_task = find_next_task(config.plan_path)
            if new_task and new_task.text == task.text:
                failed += 1
                consecutive_fails += 1
                print()
                print("❌ Task failed (task not checked off)")
            else:
                completed += 1
                consecutive_fails = 0
                print()
                print("✅ Task complete")
                if not config.skip_review and review_base:
                    auto_commit()
                    review_out = run_review(review_base, task.text, config)
                    fix_review_issues(review_out, config)

            status_line(start_time, total_cost, config.plan_path)

            # Follow-up detection
            user_guidance = handle_followup(result.text)

        # Bail on consecutive failures
        if consecutive_fails >= MAX_CONSECUTIVE_FAILS:
            print()
            print(f"🛑 Stopping: {MAX_CONSECUTIVE_FAILS} consecutive failures on the same task.")
            print("   Fix the issue manually, then re-run ralph.")
            sys.exit(1)

        # Refresh git history every 3 tasks
        if completed > 0 and completed % 3 == 0:
            recent_commits = get_recent_commits()

        print()


if __name__ == "__main__":
    main()
