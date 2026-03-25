"""Data classes, enums, exceptions, and constants for Ralph."""

import enum
import re
import time
from dataclasses import dataclass
from pathlib import Path


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
CONTEXT_REUSE_THRESHOLD = 75_000  # tokens — reuse session if peak was under this


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
    session_id: str = ""  # conversation session ID for --resume


# ─── Formatting utilities ────────────────────────────────────────────────────

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


def elapsed(start_time: float) -> str:
    """Format elapsed time since start_time as a human-readable string."""
    secs = int(time.time() - start_time)
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h{m:02d}m{s:02d}s"
    if m > 0:
        return f"{m}m{s:02d}s"
    return f"{s}s"
