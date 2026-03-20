"""Tests for ralph.py — task parsing, plan trimming, prompt building, and stream parsing."""

import json
import os
import sys
import tempfile
from pathlib import Path

import pytest
from textual.widgets import RichLog, Static, Input

# Add skills/ralph to path so we can import ralph
sys.path.insert(0, str(Path(__file__).parent.parent / "skills" / "ralph"))
import ralph


# ─── Fixtures ────────────────────────────────────────────────────────────────

@pytest.fixture
def plan_file(tmp_path):
    """Create a temporary plan file with mixed checked/unchecked tasks."""
    content = """\
# Test Plan

## Phase 1: Setup

- [x] **Task 1** — _Criterion: file exists_
- [ ] **Task 2: Do something** — _Criterion: tests pass_
- [ ] **Task 3: Another thing** — Build the widget

## Phase 2: Polish

- [ ] **Task 4** — _Criterion: docs updated_
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


@pytest.fixture
def batch_plan(tmp_path):
    """Plan with a BATCH marker."""
    content = """\
# Plan

## Phase 1

<!-- BATCH -->
- [ ] Task A — do A
- [ ] Task B — do B
- [ ] Task C — do C

## Phase 2

- [ ] Task D — do D
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


# ─── Task parsing tests ─────────────────────────────────────────────────────

class TestFindNextTask:
    def test_finds_first_unchecked(self, plan_file):
        task = ralph.find_next_task(plan_file)
        assert task is not None
        assert "Task 2" in task.text
        assert task.line_num == 6

    def test_skips_checked_tasks(self, plan_file):
        task = ralph.find_next_task(plan_file)
        assert "Task 1" not in task.text

    def test_returns_none_when_all_done(self, tmp_path):
        p = tmp_path / "done.md"
        p.write_text("- [x] Done task\n- [X] Also done\n")
        assert ralph.find_next_task(str(p)) is None


class TestCountTasks:
    def test_counts_correctly(self, plan_file):
        done, total = ralph.count_tasks(plan_file)
        assert done == 1
        assert total == 4


class TestCheckOffTask:
    def test_checks_off_specific_line(self, plan_file):
        ralph.check_off_task(plan_file, 6)  # Task 2 is line 6
        task = ralph.find_next_task(plan_file)
        assert task is not None
        assert "Task 3" in task.text  # Task 2 should now be checked


class TestExtractCriterion:
    def test_criterion_format(self):
        text = "**Task 2** — _Criterion: tests pass_"
        assert ralph.extract_criterion(text) == "tests pass"

    def test_dash_format(self):
        text = "**Task 3** — Build the widget"
        assert ralph.extract_criterion(text) == "Build the widget"

    def test_no_criterion(self):
        text = "Just a task with no criterion"
        assert ralph.extract_criterion(text) == "Task is complete and working correctly"


class TestCollectBatch:
    def test_collects_consecutive_tasks(self, batch_plan):
        tasks = ralph.collect_batch(batch_plan, 6)
        assert len(tasks) == 3
        assert "Task A" in tasks[0].text
        assert "Task C" in tasks[2].text

    def test_stops_at_non_task_line(self, batch_plan):
        tasks = ralph.collect_batch(batch_plan, 6)
        # Should not include Task D from Phase 2
        for t in tasks:
            assert "Task D" not in t.text


class TestIsBatchStart:
    def test_detects_batch_marker(self, batch_plan):
        assert ralph.is_batch_start(batch_plan, 6) is True

    def test_no_batch_marker(self, plan_file):
        assert ralph.is_batch_start(plan_file, 5) is False

    def test_line_1(self, plan_file):
        assert ralph.is_batch_start(plan_file, 1) is False


# ─── Plan trimming tests ────────────────────────────────────────────────────

class TestTrimPlanForTask:
    def test_includes_preamble(self, plan_file):
        trimmed = ralph.trim_plan_for_task(plan_file, 5)
        assert "# Test Plan" in trimmed

    def test_includes_current_phase(self, plan_file):
        trimmed = ralph.trim_plan_for_task(plan_file, 5)
        assert "## Phase 1" in trimmed

    def test_omits_later_phases_for_phase1_task(self, plan_file):
        trimmed = ralph.trim_plan_for_task(plan_file, 5)
        assert "## Phase 2" not in trimmed

    def test_includes_correct_phase_for_phase2(self, plan_file):
        trimmed = ralph.trim_plan_for_task(plan_file, 10)
        assert "## Phase 2" in trimmed
        assert "completed phases omitted" in trimmed

    def test_no_headings_returns_full(self, tmp_path):
        p = tmp_path / "flat.md"
        p.write_text("- [ ] Task 1\n- [ ] Task 2\n")
        trimmed = ralph.trim_plan_for_task(str(p), 1)
        assert "Task 1" in trimmed
        assert "Task 2" in trimmed


# ─── Prompt building tests ──────────────────────────────────────────────────

class TestBuildSinglePrompt:
    def test_contains_task(self):
        task = ralph.Task(line_num=5, text="Build it", criterion="It works")
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_single_prompt(
            task, "plan content", config, "rules", "abc123 commit", "")
        assert "Build it" in prompt
        assert "It works" in prompt
        assert "plan content" in prompt
        assert "abc123 commit" in prompt
        assert "rules" in prompt

    def test_includes_user_guidance(self):
        task = ralph.Task(line_num=5, text="Build it", criterion="It works")
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_single_prompt(
            task, "plan", config, "", "", "focus on edge cases")
        assert "focus on edge cases" in prompt
        assert "User Guidance" in prompt

    def test_no_guidance_section_when_empty(self):
        task = ralph.Task(line_num=5, text="Build it", criterion="It works")
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_single_prompt(task, "plan", config, "", "", "")
        assert "User Guidance" not in prompt


class TestBuildBatchPrompt:
    def test_contains_all_tasks(self):
        tasks = [
            ralph.Task(1, "Task A", "A done"),
            ralph.Task(2, "Task B", "B done"),
        ]
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_batch_prompt(tasks, "plan", config, "", "", "")
        assert "Task A" in prompt
        assert "Task B" in prompt
        assert "batch" in prompt.lower()


# ─── Stream parsing tests ───────────────────────────────────────────────────

class TestFormatToolDetail:
    def test_read_tool(self):
        result = ralph.format_tool_detail("Read", {"file_path": "/foo/bar.py"})
        assert "bar.py" in result
        assert "Read" in result

    def test_bash_tool_truncation(self):
        long_cmd = "a" * 100
        result = ralph.format_tool_detail("Bash", {"command": long_cmd})
        assert "..." in result
        assert len(result) < 120

    def test_grep_tool(self):
        result = ralph.format_tool_detail("Grep", {"pattern": "foo", "path": "/tmp/bar.py"})
        assert "/foo/" in result
        assert "bar.py" in result

    def test_unknown_tool(self):
        result = ralph.format_tool_detail("CustomTool", {})
        assert "CustomTool" in result


# ─── Inbox & interaction tests ──────────────────────────────────────────────

class TestReadInbox:
    def test_reads_and_clears(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        inbox = tmp_path / ".ralph-inbox"
        inbox.write_text("hello world\n")
        monkeypatch.setattr(ralph, "INBOX_FILE", str(inbox))
        content = ralph.read_inbox()
        assert content == "hello world"
        assert inbox.read_text() == ""

    def test_empty_inbox(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        monkeypatch.setattr(ralph, "INBOX_FILE", str(tmp_path / ".ralph-inbox"))
        assert ralph.read_inbox() == ""


class TestNeedsFollowup:
    def test_detects_question(self):
        assert ralph.needs_followup("Should I use approach A or B?") is True
        assert ralph.needs_followup("need clarification on the API") is True
        assert ralph.needs_followup("before I proceed, can you confirm") is True

    def test_no_false_positive(self):
        assert ralph.needs_followup("Task completed successfully.") is False
        assert ralph.needs_followup("") is False


# ─── Config tests ───────────────────────────────────────────────────────────

class TestConfig:
    def test_model_flags_empty(self):
        c = ralph.Config()
        assert c.claude_model_flags() == []

    def test_model_flags_with_model(self):
        c = ralph.Config(model="claude-opus-4-6")
        assert c.claude_model_flags() == ["--model", "claude-opus-4-6"]

    def test_model_flags_with_effort(self):
        c = ralph.Config(model="claude-opus-4-6", effort="high")
        flags = c.claude_model_flags()
        assert "--model" in flags
        assert "--effort" in flags
        assert "high" in flags


# ─── Model presets ──────────────────────────────────────────────────────────

class TestModelPresets:
    def test_all_presets_resolve(self):
        for name, (model, effort) in ralph.MODEL_PRESETS.items():
            assert model.startswith("claude-")
            assert isinstance(effort, str)

    def test_opus_max(self):
        model, effort = ralph.MODEL_PRESETS["opus-max"]
        assert model == "claude-opus-4-6"
        assert effort == "max"


# ─── Time formatting ────────────────────────────────────────────────────────

class TestElapsed:
    def test_seconds(self):
        import time as _time
        now = _time.time()
        assert ralph.elapsed(now - 45) == "45s"

    def test_minutes(self):
        import time as _time
        now = _time.time()
        assert "m" in ralph.elapsed(now - 125)

    def test_hours(self):
        import time as _time
        now = _time.time()
        result = ralph.elapsed(now - 3661)
        assert "h" in result


# ─── Review logic ───────────────────────────────────────────────────────────

class TestHasReviewIssues:
    def test_lgtm(self):
        assert ralph.has_review_issues("Everything looks great. LGTM") is False

    def test_no_issues(self):
        assert ralph.has_review_issues("no issues found") is False

    def test_has_issues(self):
        assert ralph.has_review_issues("Bug: missing null check on line 42") is True

    def test_empty(self):
        assert ralph.has_review_issues("") is False


# ─── Find plan tests ────────────────────────────────────────────────────────

class TestFindPlan:
    def test_explicit_path(self, tmp_path):
        p = tmp_path / "my-plan.md"
        p.write_text("# Plan\n")
        assert ralph.find_plan(str(p)) == str(p.resolve())

    def test_explicit_path_not_found(self, tmp_path):
        with pytest.raises(SystemExit):
            ralph.find_plan(str(tmp_path / "nonexistent.md"))

    def test_cwd_plan_md(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "plan.md").write_text("# Plan\n")
        result = ralph.find_plan("")
        assert result.endswith("plan.md")

    def test_no_plan_found(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        with pytest.raises(SystemExit):
            ralph.find_plan("")


# ─── TUI tests ────────────────────────────────────────────────────────────────


class TestRalphApp:
    def test_compose_yields_expected_widgets(self, plan_file):
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        widgets = list(app.compose())
        assert len(widgets) == 3
        assert isinstance(widgets[0], RichLog)
        assert isinstance(widgets[1], Static)
        assert isinstance(widgets[2], Input)

    def test_widget_ids(self, plan_file):
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        widgets = list(app.compose())
        assert widgets[0].id == "log"
        assert widgets[1].id == "status"

    def test_css_is_set(self, plan_file):
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert "#log" in app.CSS
        assert "#status" in app.CSS

    @pytest.mark.asyncio
    async def test_dry_run_processes_tasks(self, plan_file):
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            # Wait for worker to complete (tasks are fast in dry-run)
            await pilot.pause(delay=3)
        # After app exits, all unchecked tasks should be checked off
        done, total = ralph.count_tasks(plan_file)
        assert done == total
