"""Plan file parsing for Ralph v2 -- phase-level with backward compatibility."""

import fcntl
import re
import sys
import time
from pathlib import Path

from models import Phase


# ─── Regexes ─────────────────────────────────────────────────────────────────

_PHASE_HEADING_RE = re.compile(r"^##\s+Phase\s+(\d+)\b(.*)$", re.IGNORECASE)
_TASK_RE = re.compile(r"^\s*- \[ \] (.+)$")
_CHECKED_TASK_RE = re.compile(r"^\s*- \[[xX]\] (.+)$")
_PARALLEL_RE = re.compile(r"^\s*<!--\s*PARALLEL\s+([\d,\s]+)\s*-->\s*$")
_DELIVERS_RE = re.compile(r"^\*\*Delivers\*\*\s*:\s*(.+)$")
_ACCEPTANCE_RE = re.compile(r"^\*\*Acceptance criteria\*\*\s*:", re.IGNORECASE)
_AI_OPP_RE = re.compile(r"^\*\*AI opportunity\*\*\s*:\s*(.*)$", re.IGNORECASE)
_CRITERION_BULLET_RE = re.compile(r"^\s*[-*]\s+(.+)$")


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
            print("Specify one: ralph-v2 <path>", file=sys.stderr)
            sys.exit(1)

    print("Error: no plan file found", file=sys.stderr)
    sys.exit(1)


# ─── Phase parsing ──────────────────────────────────────────────────────────

def parse_phases(plan_path: str) -> list[Phase]:
    """Parse all phases from a plan file.

    Supports both v2 format (phase descriptions + acceptance criteria)
    and v1 format (checkbox tasks under phase headings).
    """
    lines = Path(plan_path).read_text().splitlines()
    phases: list[Phase] = []

    i = 0
    while i < len(lines):
        m = _PHASE_HEADING_RE.match(lines[i])
        if not m:
            i += 1
            continue

        phase_num = int(m.group(1))
        rest = m.group(2).strip()
        title = rest.lstrip(":").strip() if rest else f"Phase {phase_num}"

        phase_line_start = i + 1  # 1-indexed

        # Find end of this phase (next ## heading or EOF)
        phase_line_end = len(lines)
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("## "):
                phase_line_end = j
                break

        # Parse phase body
        body_lines = lines[i + 1:phase_line_end]
        delivers = ""
        acceptance_criteria: list[str] = []
        ai_opportunity = ""
        v1_tasks: list[str] = []

        section = None

        for line in body_lines:
            stripped = line.strip()

            # Check for v1 checkbox tasks (unchecked and checked)
            task_m = _TASK_RE.match(line)
            checked_m = _CHECKED_TASK_RE.match(line)
            if task_m:
                v1_tasks.append(task_m.group(1))
                continue
            if checked_m:
                v1_tasks.append(checked_m.group(1))
                continue

            # Check for section headers
            delivers_m = _DELIVERS_RE.match(stripped)
            if delivers_m:
                delivers = delivers_m.group(1).strip()
                section = "delivers"
                continue

            if _ACCEPTANCE_RE.match(stripped):
                section = "acceptance"
                continue

            ai_m = _AI_OPP_RE.match(stripped)
            if ai_m:
                inline = ai_m.group(1).strip()
                if inline:
                    ai_opportunity = inline
                section = "ai_opportunity"
                continue

            # Horizontal rules and headings reset section tracking
            if stripped == "---":
                section = None
                continue

            # Headings within the phase reset section tracking
            if stripped.startswith("### "):
                # Sub-headings like "### What to build" -- check for acceptance
                if "acceptance" in stripped.lower():
                    section = "acceptance"
                else:
                    section = None
                continue

            # Collect content based on current section
            if section == "acceptance":
                bullet_m = _CRITERION_BULLET_RE.match(stripped)
                if bullet_m:
                    acceptance_criteria.append(bullet_m.group(1).strip())
            elif section == "ai_opportunity":
                if stripped:
                    ai_opportunity += (" " if ai_opportunity else "") + stripped
            elif section == "delivers" and stripped:
                delivers += " " + stripped

        # Determine if this is a v1 or v2 phase
        if v1_tasks and not acceptance_criteria:
            # v1 format: checkbox tasks, no acceptance criteria
            if not delivers:
                delivers = f"Complete all tasks in Phase {phase_num}"
            phase = Phase(
                number=phase_num,
                title=title,
                delivers=delivers,
                acceptance_criteria=[f"All tasks completed: {'; '.join(v1_tasks)}"],
                v1_tasks=v1_tasks,
                line_start=phase_line_start,
                line_end=phase_line_end,
            )
        else:
            phase = Phase(
                number=phase_num,
                title=title,
                delivers=delivers,
                acceptance_criteria=acceptance_criteria,
                ai_opportunity=ai_opportunity,
                v1_tasks=v1_tasks if v1_tasks else None,
                line_start=phase_line_start,
                line_end=phase_line_end,
            )

        phases.append(phase)
        i = phase_line_end

    return phases


def get_phase(plan_path: str, phase_num: int) -> Phase | None:
    """Return a specific phase by number, or None."""
    for phase in parse_phases(plan_path):
        if phase.number == phase_num:
            return phase
    return None


# ─── Parallel group parsing ─────────────────────────────────────────────────

def find_parallel_phases(plan_path: str) -> list[list[int]]:
    groups: list[list[int]] = []
    for line in Path(plan_path).read_text().splitlines():
        m = _PARALLEL_RE.match(line)
        if m:
            nums = [int(p.strip()) for p in m.group(1).split(",") if p.strip()]
            if nums:
                groups.append(nums)
    return groups


def parse_parallel_group(plan_path: str, phase_num: int) -> list[int] | None:
    """Return phase numbers if phase_num is in a parallel group, None otherwise."""
    groups = find_parallel_phases(plan_path)
    for group in groups:
        if phase_num in group:
            return group
    return None


# ─── Plan sections ──────────────────────────────────────────────────────────

def get_plan_header(plan_path: str) -> str:
    """Return everything before the first ## Phase heading."""
    lines = Path(plan_path).read_text().splitlines()
    for i, line in enumerate(lines):
        if _PHASE_HEADING_RE.match(line):
            return "\n".join(lines[:i]).strip()
    return "\n".join(lines).strip()


def get_phase_section(plan_path: str, phase_num: int) -> str:
    """Return the raw text of a specific phase section."""
    lines = Path(plan_path).read_text().splitlines()
    phase_re = re.compile(rf"^##\s+Phase\s+{phase_num}\b", re.IGNORECASE)
    start = None
    for i, line in enumerate(lines):
        if start is None:
            if phase_re.match(line):
                start = i
        else:
            if line.startswith("## "):
                return "\n".join(lines[start:i])
    if start is not None:
        return "\n".join(lines[start:])
    return ""


# ─── v1 backward compatibility ──────────────────────────────────────────────

def is_phase_complete_v1(plan_path: str, phase: Phase) -> bool:
    """Check if a v1-format phase has all tasks checked off."""
    if phase.v1_tasks is None:
        return False
    lines = Path(plan_path).read_text().splitlines()
    start_idx = phase.line_start - 1
    end_idx = min(phase.line_end, len(lines))
    for line in lines[start_idx:end_idx]:
        if _TASK_RE.match(line):
            return False
    return True


_PHASE_COMPLETE_RE = re.compile(r"<!--\s*PHASE\s+(\d+)\s+COMPLETE\s*-->", re.IGNORECASE)


def is_phase_complete(plan_path: str, phase: Phase) -> bool:
    """Check if a phase is complete (v1 checkbox or v2 completion marker)."""
    if phase.v1_tasks is not None:
        return is_phase_complete_v1(plan_path, phase)
    # v2: search the whole file for <!-- PHASE N COMPLETE --> matching this phase.
    # Whole-file search is intentional: markers can drift out of their original
    # phase section if multiple phases are marked in one session (each insert
    # shifts subsequent line numbers).
    lines = Path(plan_path).read_text().splitlines()
    for line in lines:
        m = _PHASE_COMPLETE_RE.match(line.strip())
        if m and int(m.group(1)) == phase.number:
            return True
    return False


def mark_phase_complete(plan_path: str, phase: Phase) -> None:
    """Insert a <!-- PHASE N COMPLETE --> marker right after the phase heading.

    Re-finds the heading line at write time so the marker lands correctly even
    if the file has shifted since phases were parsed.
    """
    content = Path(plan_path).read_text()
    lines = content.splitlines(keepends=True)
    marker = f"<!-- PHASE {phase.number} COMPLETE -->\n"

    # Skip if already marked anywhere in the file
    bare_lines = content.splitlines()
    for line in bare_lines:
        m = _PHASE_COMPLETE_RE.match(line.strip())
        if m and int(m.group(1)) == phase.number:
            return

    heading_re = re.compile(rf"^##\s+Phase\s+{phase.number}\b", re.IGNORECASE)
    insert_at = None
    for i, line in enumerate(lines):
        if heading_re.match(line):
            insert_at = i + 1
            break

    if insert_at is None:
        # Heading not found — append at EOF as a last resort
        lines.append(marker)
    else:
        lines.insert(insert_at, marker)
    Path(plan_path).write_text("".join(lines))


def check_off_v1_tasks(plan_path: str, phase: Phase) -> None:
    """Check off all unchecked v1 tasks in a phase."""
    if phase.v1_tasks is None:
        return
    content = Path(plan_path).read_text()
    lines = content.splitlines(keepends=True)
    start_idx = phase.line_start - 1
    end_idx = min(phase.line_end, len(lines))
    for i in range(start_idx, end_idx):
        lines[i] = lines[i].replace("- [ ] ", "- [x] ", 1)
    Path(plan_path).write_text("".join(lines))


# ─── Plan evolution ─────────────────────────────────────────────────────────

def derive_proposed_changes_path(plan_path: str) -> str:
    p = Path(plan_path)
    return str(p.with_name(f"{p.stem}-proposed-changes.md"))


def load_proposed_changes(plan_path: str) -> str:
    changes_path = Path(derive_proposed_changes_path(plan_path))
    if changes_path.is_file():
        return changes_path.read_text().strip()
    return ""


# ─── Learnings file ─────────────────────────────────────────────────────────

def derive_learnings_path(plan_path: str) -> str:
    p = Path(plan_path)
    return str(p.with_name(f"{p.stem}-learnings.md"))


def derive_log_path(plan_path: str) -> str:
    p = Path(plan_path)
    return str(p.with_name(f"{p.stem}-ralph.log"))


def load_learnings(learnings_path: str) -> str:
    p = Path(learnings_path)
    if not p.is_file():
        return ""
    with open(p) as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        try:
            return f.read().strip()
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def append_learning(learnings_path: str, phase_title: str, content: str) -> None:
    """Append a phase learning entry (1-8 sentences)."""
    p = Path(learnings_path)
    timestamp = time.strftime("%Y-%m-%d %H:%M")
    entry = f"\n## [{timestamp}] {phase_title}\n\n{content}\n"
    if not p.exists():
        p.write_text(f"# Learnings\n# Ralph appends entries after each phase.\n{entry}")
    else:
        with open(p, "a") as f:
            deadline = time.monotonic() + 1.0
            while True:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        fcntl.flock(f, fcntl.LOCK_EX)
                        break
                    time.sleep(0.05)
            try:
                f.write(entry)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


# ─── Summary ────────────────────────────────────────────────────────────────

def format_plan_summary(plan_path: str) -> list[str]:
    """Format phase status summary for display."""
    phases = parse_phases(plan_path)
    output = [f"Plan: {len(phases)} phases"]
    output.append("")
    for phase in phases:
        n_criteria = len(phase.acceptance_criteria)
        v1_note = ""
        if phase.v1_tasks is not None:
            complete = is_phase_complete_v1(plan_path, phase)
            v1_note = " [complete]" if complete else " [in progress]"
        output.append(
            f"  Phase {phase.number}: {phase.title} "
            f"({n_criteria} criteria){v1_note}"
        )
    return output
