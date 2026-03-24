"""Plan file parsing, discovery, learnings, and trimming."""

import fcntl
import re
import sys
import time
from pathlib import Path

from models import Task


# ─── Regexes ─────────────────────────────────────────────────────────────────

_TASK_RE = re.compile(r"^(\s*- \[ \] )(.+)$")
_CHECKED_RE = re.compile(r"^\s*- \[[xX ]\] ")
_DONE_RE = re.compile(r"^\s*- \[[xX]\] (.+)$")
_TODO_RE = re.compile(r"^\s*- \[ \] (.+)$")
_PARALLEL_RE = re.compile(r"^\s*<!--\s*PARALLEL\s+([\d,\s]+)\s*-->\s*$")
_PHASE_HEADING_RE = re.compile(r"^##\s+Phase\s+(\d+)\b", re.IGNORECASE)


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


# ─── Phase and task parsing ─────────────────────────────────────────────────

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
