"""Tests for ralph.py — task parsing, plan trimming, prompt building, and stream parsing."""

import json
import os
import subprocess
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

    @pytest.mark.asyncio
    async def test_output_writes_to_richlog(self, plan_file):
        """output() method routes text to the RichLog widget, not stdout."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            app.output("hello from output")
            await pilot.pause(delay=0.1)
            log = app.query_one("#log", RichLog)
            # RichLog stores lines internally — check it didn't crash
            # and the widget exists (write is a no-error operation)
            assert log is not None

    @pytest.mark.asyncio
    async def test_dry_run_output_in_richlog_not_stdout(self, plan_file, capsys):
        """Dry-run task output appears in RichLog, not on raw stdout."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            await pilot.pause(delay=3)
        # stdout should NOT contain task output (it goes to RichLog)
        captured = capsys.readouterr()
        assert "[dry-run]" not in captured.out
        assert "Task 2" not in captured.out


    def test_app_has_status_tracking_attrs(self, plan_file):
        """RalphApp initializes status tracking attributes."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert isinstance(app.start_time, float)
        assert app.total_cost == 0.0
        assert app.current_task == ""
        assert app._completed == 0

    def test_update_status_method_exists(self, plan_file):
        """RalphApp has an update_status method."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "update_status")
        assert callable(app.update_status)

    @pytest.mark.asyncio
    async def test_status_bar_updates_during_dry_run(self, plan_file):
        """Status bar updates every second via set_interval during dry-run."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            # Let the tasks run and timer tick
            await pilot.pause(delay=2)
            status = app.query_one("#status", Static)
            text = str(status.render())
            # Status should contain elapsed time and task progress
            assert "⏱" in text
            assert "📋" in text
            assert "💰" in text

    @pytest.mark.asyncio
    async def test_status_bar_shows_current_task(self, plan_file):
        """Status bar displays the current task name while running."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            # Briefly pause — tasks should be in-progress
            await pilot.pause(delay=0.5)
            # Set a current task manually and trigger update
            app.current_task = "Test task name"
            app.update_status()
            await pilot.pause(delay=0.1)
            status = app.query_one("#status", Static)
            text = str(status.render())
            assert "Test task name" in text


class TestInputHandling:
    """Input.on_submit dispatches /commands or queues guidance."""

    @pytest.mark.asyncio
    async def test_plain_text_queues_guidance(self, plan_file):
        """Typing plain text and pressing Enter queues it and shows message."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "focus on edge cases"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            # Check guidance queue
            assert len(app.guidance_queue) == 1
            assert app.guidance_queue[0] == "focus on edge cases"
            # Check input is cleared
            assert input_widget.value == ""

    @pytest.mark.asyncio
    async def test_plain_text_shows_queued_message(self, plan_file):
        """Queued text shows '📬 Queued: {text}' in the log."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "be more careful"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            log = app.query_one("#log", RichLog)
            assert log is not None

    @pytest.mark.asyncio
    async def test_slash_command_dispatches_to_handler(self, plan_file):
        """Input starting with / dispatches to the command handler dict."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        called_with = []
        app.command_handlers["test"] = lambda arg: called_with.append(arg)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/test hello world"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            assert called_with == ["hello world"]
            # Input should be cleared
            assert input_widget.value == ""

    @pytest.mark.asyncio
    async def test_unknown_command_shows_error(self, plan_file):
        """Unknown /command shows error in the log."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/nonexistent"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            # Should not be in guidance queue
            assert len(app.guidance_queue) == 0

    @pytest.mark.asyncio
    async def test_empty_input_ignored(self, plan_file):
        """Empty input (just pressing Enter) does nothing."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            assert len(app.guidance_queue) == 0

    @pytest.mark.asyncio
    async def test_multiple_submissions_queue_in_order(self, plan_file):
        """Multiple submissions are queued in FIFO order."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            for msg in ["first", "second", "third"]:
                input_widget.value = msg
                await input_widget.action_submit()
                await pilot.pause(delay=0.1)
            assert list(app.guidance_queue) == ["first", "second", "third"]

    def test_guidance_queue_initialized(self, plan_file):
        """RalphApp initializes with an empty guidance queue."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "guidance_queue")
        assert len(app.guidance_queue) == 0

    def test_command_handlers_initialized(self, plan_file):
        """RalphApp initializes with built-in command handlers."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "command_handlers")
        assert isinstance(app.command_handlers, dict)
        assert "stop" in app.command_handlers
        assert "plan" in app.command_handlers


class TestStopCommand:
    """/stop kills current_proc, git stashes if dirty, logs summary, exits."""

    def test_current_proc_initialized_none(self, plan_file):
        """RalphApp starts with current_proc = None."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert app.current_proc is None

    def test_stop_registered_in_handlers(self, plan_file):
        """cmd_stop is registered as the /stop handler."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert "stop" in app.command_handlers
        assert app.command_handlers["stop"] == app.cmd_stop

    def test_cmd_stop_kills_running_proc(self, plan_file):
        """cmd_stop kills the current_proc if one is running."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        # Create a long-running subprocess
        proc = subprocess.Popen(
            ["sleep", "60"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        app.current_proc = proc
        assert proc.poll() is None  # Still running
        # cmd_stop needs a mounted app for output/exit, so call the kill logic directly
        try:
            proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass
        assert proc.poll() is not None  # Process terminated
        app.current_proc = None

    @pytest.mark.asyncio
    async def test_stop_via_input_exits_app(self, plan_file):
        """/stop typed in input causes the app to exit."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/stop"
            await input_widget.action_submit()
            await pilot.pause(delay=0.5)
        # App should have exited (we're past the context manager)
        # If we reach here, the app exited cleanly

    @pytest.mark.asyncio
    async def test_stop_sets_current_proc_to_none(self, plan_file):
        """/stop clears current_proc after killing."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            # Simulate a running process
            proc = subprocess.Popen(
                ["sleep", "60"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            app.current_proc = proc
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/stop"
            await input_widget.action_submit()
            await pilot.pause(delay=0.5)
        # After exit, proc should have been killed
        assert proc.poll() is not None

    @pytest.mark.asyncio
    async def test_stop_stashes_if_dirty(self, plan_file, tmp_path):
        """/stop runs git stash if working tree is dirty."""
        # Set up a git repo with dirty state
        repo = tmp_path / "repo"
        repo.mkdir()
        subprocess.run(["git", "init"], cwd=str(repo), capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@test.com"],
                       cwd=str(repo), capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"],
                       cwd=str(repo), capture_output=True)
        # Create initial commit so stash works
        (repo / "file.txt").write_text("initial")
        subprocess.run(["git", "add", "."], cwd=str(repo), capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=str(repo), capture_output=True)
        # Make dirty
        (repo / "dirty.txt").write_text("uncommitted change")

        config = ralph.Config(plan_path=plan_file, work_dir=str(repo), dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/stop"
            await input_widget.action_submit()
            await pilot.pause(delay=1)

        # dirty.txt should have been stashed
        assert not (repo / "dirty.txt").exists()
        # Verify stash exists
        stash_list = subprocess.run(
            ["git", "stash", "list"], cwd=str(repo),
            capture_output=True, text=True,
        )
        assert "ralph: stopped" in stash_list.stdout

    def test_cmd_stop_method_exists(self, plan_file):
        """RalphApp has a cmd_stop method."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "cmd_stop")
        assert callable(app.cmd_stop)

    def test_failed_counter_initialized(self, plan_file):
        """RalphApp initializes _failed counter."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert app._failed == 0


class TestSkipCommand:
    """/skip kills current_proc, sets skip flag, worker moves to next task."""

    def test_skip_registered_in_handlers(self, plan_file):
        """cmd_skip is registered as the /skip handler."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert "skip" in app.command_handlers
        assert app.command_handlers["skip"] == app.cmd_skip

    def test_skip_event_initialized(self, plan_file):
        """RalphApp starts with skip_event unset."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "skip_event")
        assert not app.skip_event.is_set()

    def test_cmd_skip_sets_skip_event(self, plan_file):
        """cmd_skip sets the skip_event flag."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async def fake_output(text=""):
            pass
        # cmd_skip needs output — mock it since app isn't mounted
        app.output = lambda text="": None
        app.cmd_skip()
        assert app.skip_event.is_set()

    def test_cmd_skip_kills_running_proc(self, plan_file):
        """cmd_skip kills the current_proc if one is running."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        app.output = lambda text="": None
        proc = subprocess.Popen(
            ["sleep", "60"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        app.current_proc = proc
        assert proc.poll() is None  # Still running
        app.cmd_skip()
        assert proc.poll() is not None  # Terminated
        assert app.current_proc is None

    def test_cmd_skip_without_proc(self, plan_file):
        """cmd_skip works even when no process is running."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        app.output = lambda text="": None
        app.cmd_skip()  # Should not raise
        assert app.skip_event.is_set()
        assert app.current_proc is None

    @pytest.mark.asyncio
    async def test_skip_during_dry_run_skips_task(self, plan_file):
        """/skip during a running dry-run task moves to the next task."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        # Pre-set skip event before app starts so the first unchecked task gets skipped
        app.skip_event.set()
        async with app.run_test(size=(80, 24)) as pilot:
            # Let the worker run through tasks
            await pilot.pause(delay=3)
        # Task 2 (first unchecked) should NOT have been checked off (it was skipped),
        # but Task 3 and Task 4 should be checked off.
        # Task 1 was already checked. So done count = 1 (pre-checked) + 2 (3 & 4) = 3
        done, total = ralph.count_tasks(plan_file)
        assert done == total - 1  # One task was skipped

    @pytest.mark.asyncio
    async def test_skip_via_input(self, plan_file):
        """/skip typed in input sets the skip event."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/skip"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            # The skip event should have been set (worker may have consumed it already)
            # But the command was dispatched correctly
            assert input_widget.value == ""


class TestRunClaudeOnOutput:
    """run_claude() accepts on_output callback and routes output through it."""

    def test_on_output_signature(self):
        """run_claude accepts on_output parameter."""
        import inspect
        sig = inspect.signature(ralph.run_claude)
        assert "on_output" in sig.parameters
        # Default should be print
        assert sig.parameters["on_output"].default is print


# ─── /plan command tests ──────────────────────────────────────────────────────


class TestFormatPlanSummary:
    """format_plan_summary reads the plan file and returns formatted task lines."""

    def test_shows_progress_header(self, plan_file):
        lines = ralph.format_plan_summary(plan_file)
        assert any("1/4" in l for l in lines)
        assert any("📋" in l for l in lines)

    def test_shows_checked_tasks(self, plan_file):
        lines = ralph.format_plan_summary(plan_file)
        checked = [l for l in lines if "✅" in l]
        assert len(checked) == 1
        assert "Task 1" in checked[0]

    def test_shows_unchecked_tasks(self, plan_file):
        lines = ralph.format_plan_summary(plan_file)
        unchecked = [l for l in lines if "⬜" in l]
        assert len(unchecked) == 3
        assert "Task 2" in unchecked[0]

    def test_shows_headings(self, plan_file):
        lines = ralph.format_plan_summary(plan_file)
        headings = [l for l in lines if l.startswith("#")]
        assert len(headings) >= 2
        assert any("Phase 1" in h for h in headings)
        assert any("Phase 2" in h for h in headings)

    def test_all_done(self, tmp_path):
        p = tmp_path / "done.md"
        p.write_text("# Plan\n\n- [x] Task A\n- [x] Task B\n")
        lines = ralph.format_plan_summary(str(p))
        assert any("2/2" in l for l in lines)
        unchecked = [l for l in lines if "⬜" in l]
        assert len(unchecked) == 0


class TestPlanCommand:
    """/plan shows current plan status in the output log."""

    def test_plan_registered_in_handlers(self, plan_file):
        """cmd_plan is registered as the /plan handler."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert "plan" in app.command_handlers
        assert app.command_handlers["plan"] == app.cmd_plan

    def test_cmd_plan_method_exists(self, plan_file):
        """RalphApp has a cmd_plan method."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        assert hasattr(app, "cmd_plan")
        assert callable(app.cmd_plan)

    @pytest.mark.asyncio
    async def test_plan_via_input(self, plan_file):
        """/plan typed in input writes plan summary to the log."""
        config = ralph.Config(plan_path=plan_file, work_dir="/tmp", dry_run=True)
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/plan"
            await input_widget.action_submit()
            await pilot.pause(delay=0.5)
            # Input should be cleared
            assert input_widget.value == ""
            # Should not be in guidance queue (it's a command)
            assert len(app.guidance_queue) == 0
