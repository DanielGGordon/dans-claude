"""Data classes, enums, exceptions, and constants for Ralph v2."""

import enum
import re
import time
from dataclasses import dataclass, field
from pathlib import Path


class State(enum.Enum):
    RUNNING = "RUNNING"
    EVALUATING = "EVALUATING"
    PAUSED = "PAUSED"
    DONE = "DONE"


class PhaseStatus(enum.Enum):
    PENDING = "PENDING"
    GENERATING = "GENERATING"
    EVALUATING = "EVALUATING"
    PASSED = "PASSED"
    FAILED = "FAILED"


class AgentKilled(Exception):
    """Raised when a running claude subprocess is killed."""
    pass


class AgentTimeout(Exception):
    """Raised when a running claude subprocess exceeds the timeout."""
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
RALPH_ASCII = Path.home() / ".claude" / "skills" / "ralph-v2" / "ralph-ascii.txt"
INBOX_FILE = ".ralph-inbox"
MAX_CONSECUTIVE_FAILS = 3
DEFAULT_TASK_TIMEOUT = 3600  # 1 hour
DEFAULT_MAX_EVAL_ROUNDS = 3
CONTEXT_REUSE_THRESHOLD = 75_000


@dataclass
class Config:
    plan_path: str = ""
    work_dir: str = ""
    delay: int = 0
    dry_run: bool = False
    skip_eval: bool = False
    reviewer: str = "auto"
    model: str = ""
    effort: str = ""
    learnings_path: str = ""
    log_path: str = ""
    phase: int | None = None
    task_timeout: int = DEFAULT_TASK_TIMEOUT
    max_eval_rounds: int = DEFAULT_MAX_EVAL_ROUNDS
    reuse_context: bool = False

    def claude_model_flags(self) -> list[str]:
        flags = []
        if self.model:
            flags += ["--model", self.model]
        if self.effort:
            flags += ["--effort", self.effort]
        return flags


@dataclass
class Phase:
    number: int
    title: str
    delivers: str
    acceptance_criteria: list[str]
    ai_opportunity: str = ""
    v1_tasks: list[str] | None = None
    line_start: int = 0
    line_end: int = 0


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
    peak_input_tokens: int = 0
    session_id: str = ""


@dataclass
class EvalCriterionResult:
    criterion: str
    passed: bool
    detail: str = ""  # evidence if passed, issue+suggestion if failed


@dataclass
class EvalResult:
    passed: bool
    criteria_results: list[EvalCriterionResult]
    summary: str = ""
    raw_output: str = ""


# ─── Formatting utilities ────────────────────────────────────────────────────

def format_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


def format_context_summary(result: ClaudeResult) -> str:
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
    secs = int(time.time() - start_time)
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    if h > 0:
        return f"{h}h{m:02d}m{s:02d}s"
    if m > 0:
        return f"{m}m{s:02d}s"
    return f"{s}s"
