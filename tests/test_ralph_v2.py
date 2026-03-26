"""Tests for Ralph v2 -- phase-level parsing, evaluator parsing, prompt building, and TUI."""

import sys
import threading
from pathlib import Path

import pytest
from textual.widgets import RichLog, Static, Input

# Add skills/ralph-v2 to path
sys.path.insert(0, str(Path(__file__).parent.parent / "skills" / "ralph-v2"))
import ralph  # noqa: E402


# ─── Fixtures ────────────────────────────────────────────────────────────────

@pytest.fixture
def v2_plan(tmp_path):
    """v2-format plan with phase descriptions and acceptance criteria."""
    content = """\
# Plan: Test Feature

> Source: test PRD

## Project config

- **Tech stack**: Python + FastAPI
- **Eval approach**: pytest

## Architectural decisions

- **Routes**: /api/v1/items
- **Schema**: items table with id, name, created_at

---

## Phase 1: Foundation

**Delivers**: Basic API with a single endpoint that returns a list of items.

**Acceptance criteria**:
- GET /api/v1/items returns 200 with JSON array
- Database table 'items' exists with correct schema
- pytest test suite passes

**AI opportunity**: Add a /ai endpoint for natural language queries.

---

## Phase 2: CRUD Operations

**Delivers**: Full CRUD for items -- create, read, update, delete.

**Acceptance criteria**:
- POST /api/v1/items creates a new item and returns 201
- PUT /api/v1/items/:id updates an item
- DELETE /api/v1/items/:id removes an item
- All endpoints have error handling for missing items (404)

---

## Phase 3: Polish

**Delivers**: Input validation, pagination, and search.

**Acceptance criteria**:
- Items are paginated (default 20 per page)
- Search by name via query parameter
- Input validation rejects empty names with 422
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


@pytest.fixture
def v1_plan(tmp_path):
    """v1-format plan with checkbox tasks."""
    content = """\
# Plan: Legacy Feature

## Phase 1: Setup

- [x] **Task 1** -- Set up project
- [ ] **Task 2: Create API** -- _Criterion: API responds_
- [ ] **Task 3: Add tests** -- Write tests

## Phase 2: Polish

- [ ] **Task 4** -- _Criterion: docs updated_
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


@pytest.fixture
def mixed_plan(tmp_path):
    """Plan with both v2 acceptance criteria AND v1 checkbox tasks."""
    content = """\
# Plan: Mixed

## Phase 1: Setup

**Delivers**: Project scaffolding.

**Acceptance criteria**:
- Project structure exists
- Dependencies installed

- [ ] Create package.json
- [ ] Install dependencies

## Phase 2: Features

**Delivers**: Core features.

**Acceptance criteria**:
- Feature A works
- Feature B works
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


@pytest.fixture
def parallel_plan(tmp_path):
    """Plan with PARALLEL annotation."""
    content = """\
# Plan: Parallel Test

## Phase 1: Setup

**Delivers**: Foundation.

**Acceptance criteria**:
- Project initialized

<!-- PARALLEL 2,3 -->

## Phase 2: Feature A

**Delivers**: Feature A.

**Acceptance criteria**:
- Feature A endpoint works

## Phase 3: Feature B

**Delivers**: Feature B.

**Acceptance criteria**:
- Feature B endpoint works

## Phase 4: Integration

**Delivers**: Combined features.

**Acceptance criteria**:
- A and B work together
"""
    p = tmp_path / "plan.md"
    p.write_text(content)
    return str(p)


# ─── Phase parsing tests ────────────────────────────────────────────────────

class TestParsePhases:
    def test_parses_v2_phases(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert len(phases) == 3

    def test_v2_phase_numbers(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert [p.number for p in phases] == [1, 2, 3]

    def test_v2_phase_titles(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert phases[0].title == "Foundation"
        assert phases[1].title == "CRUD Operations"
        assert phases[2].title == "Polish"

    def test_v2_delivers(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert "Basic API" in phases[0].delivers
        assert "Full CRUD" in phases[1].delivers

    def test_v2_acceptance_criteria(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert len(phases[0].acceptance_criteria) == 3
        assert len(phases[1].acceptance_criteria) == 4
        assert len(phases[2].acceptance_criteria) == 3

    def test_v2_criteria_content(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        criteria = phases[0].acceptance_criteria
        assert any("GET" in c for c in criteria)
        assert any("items" in c.lower() for c in criteria)

    def test_v2_ai_opportunity(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert "/ai endpoint" in phases[0].ai_opportunity

    def test_v2_no_v1_tasks(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        assert phases[0].v1_tasks is None

    def test_v1_backward_compat(self, v1_plan):
        phases = ralph.parse_phases(v1_plan)
        assert len(phases) == 2

    def test_v1_has_tasks(self, v1_plan):
        phases = ralph.parse_phases(v1_plan)
        assert phases[0].v1_tasks is not None
        # 3 tasks total (1 checked + 2 unchecked)
        assert len(phases[0].v1_tasks) == 3

    def test_v1_auto_criteria(self, v1_plan):
        """v1 phases get auto-generated acceptance criteria."""
        phases = ralph.parse_phases(v1_plan)
        assert len(phases[0].acceptance_criteria) == 1
        assert "All tasks completed" in phases[0].acceptance_criteria[0]

    def test_mixed_plan_has_both(self, mixed_plan):
        """Plan with both v2 criteria AND v1 tasks preserves both."""
        phases = ralph.parse_phases(mixed_plan)
        p1 = phases[0]
        # Has v2 acceptance criteria
        assert len(p1.acceptance_criteria) == 2
        # Also has v1 tasks
        assert p1.v1_tasks is not None
        assert len(p1.v1_tasks) == 2

    def test_empty_plan(self, tmp_path):
        p = tmp_path / "empty.md"
        p.write_text("# Empty Plan\n\nNo phases here.\n")
        phases = ralph.parse_phases(str(p))
        assert phases == []

    def test_phase_line_ranges(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        for phase in phases:
            assert phase.line_start > 0
            assert phase.line_end > phase.line_start


class TestGetPhase:
    def test_get_existing_phase(self, v2_plan):
        phase = ralph.get_phase(v2_plan, 2)
        assert phase is not None
        assert phase.number == 2
        assert phase.title == "CRUD Operations"

    def test_get_nonexistent_phase(self, v2_plan):
        assert ralph.get_phase(v2_plan, 99) is None


# ─── Parallel group tests ───────────────────────────────────────────────────

class TestParallelGroups:
    def test_find_parallel_phases(self, parallel_plan):
        groups = ralph.find_parallel_phases(parallel_plan)
        assert groups == [[2, 3]]

    def test_phase_in_group(self, parallel_plan):
        result = ralph.parse_parallel_group(parallel_plan, 2)
        assert result == [2, 3]

    def test_phase_not_in_group(self, parallel_plan):
        result = ralph.parse_parallel_group(parallel_plan, 1)
        assert result is None

    def test_phase_after_group(self, parallel_plan):
        result = ralph.parse_parallel_group(parallel_plan, 4)
        assert result is None

    def test_no_parallel(self, v2_plan):
        groups = ralph.find_parallel_phases(v2_plan)
        assert groups == []


# ─── Plan header extraction ─────────────────────────────────────────────────

class TestGetPlanHeader:
    def test_extracts_header(self, v2_plan):
        header = ralph.get_plan_header(v2_plan)
        assert "Project config" in header
        assert "Architectural decisions" in header
        assert "Phase 1" not in header

    def test_header_includes_routes(self, v2_plan):
        header = ralph.get_plan_header(v2_plan)
        assert "/api/v1/items" in header


# ─── v1 backward compatibility ──────────────────────────────────────────────

class TestV1BackwardCompat:
    def test_is_phase_complete_with_unchecked(self, v1_plan):
        phases = ralph.parse_phases(v1_plan)
        assert ralph.is_phase_complete_v1(v1_plan, phases[0]) is False

    def test_check_off_v1_tasks(self, v1_plan):
        phases = ralph.parse_phases(v1_plan)
        ralph.check_off_v1_tasks(v1_plan, phases[0])
        assert ralph.is_phase_complete_v1(v1_plan, phases[0]) is True


# ─── Evaluator output parsing ───────────────────────────────────────────────

class TestParseEvalOutput:
    def test_parses_all_pass(self):
        output = """\
## Phase 1 Evaluation

**Overall**: PASS (3 of 3 criteria met)

### Criterion 1: GET endpoint returns 200
**Result**: PASS
**Evidence**: Tested with curl, got 200 OK

### Criterion 2: Database table exists
**Result**: PASS
**Evidence**: Checked with sqlite3, table found

### Criterion 3: Tests pass
**Result**: PASS
**Evidence**: pytest ran 5 tests, all passed
"""
        result = ralph.parse_eval_output(output)
        assert result.passed is True
        assert len(result.criteria_results) == 3
        assert all(cr.passed for cr in result.criteria_results)
        assert "3/3" in result.summary

    def test_parses_mixed_results(self):
        output = """\
## Phase 2 Evaluation

**Overall**: FAIL (2 of 3 criteria met)

### Criterion 1: POST creates item
**Result**: PASS
**Evidence**: POST returned 201

### Criterion 2: PUT updates item
**Result**: FAIL
**Issue**: PUT returns 500 server error
**Suggestion**: Check the update handler for null checks

### Criterion 3: DELETE removes item
**Result**: PASS
**Evidence**: DELETE returned 204
"""
        result = ralph.parse_eval_output(output)
        assert result.passed is False
        assert len(result.criteria_results) == 3
        assert result.criteria_results[0].passed is True
        assert result.criteria_results[1].passed is False
        assert result.criteria_results[2].passed is True
        assert "500" in result.criteria_results[1].detail

    def test_parses_all_fail(self):
        output = """\
## Phase 1 Evaluation

**Overall**: FAIL (0 of 2 criteria met)

### Criterion 1: API works
**Result**: FAIL
**Issue**: Server won't start

### Criterion 2: Tests pass
**Result**: FAIL
**Issue**: No test files found
"""
        result = ralph.parse_eval_output(output)
        assert result.passed is False
        assert len(result.criteria_results) == 2
        assert all(not cr.passed for cr in result.criteria_results)

    def test_heuristic_fallback_pass(self):
        output = "Everything looks good. All criteria pass. LGTM."
        result = ralph.parse_eval_output(output)
        assert result.passed is True

    def test_heuristic_fallback_fail(self):
        output = "Multiple things are broken. Tests fail. Missing files."
        result = ralph.parse_eval_output(output)
        assert result.passed is False

    def test_empty_output(self):
        result = ralph.parse_eval_output("")
        assert result.criteria_results == []


class TestFormatEvalSummary:
    def test_formats_pass(self):
        result = ralph.EvalResult(
            passed=True,
            criteria_results=[
                ralph.EvalCriterionResult("API works", True, "All good"),
            ],
            summary="1/1 criteria passed",
        )
        text = ralph.format_eval_summary(result)
        assert "1/1" in text
        assert "PASS" in text

    def test_formats_failure_with_detail(self):
        result = ralph.EvalResult(
            passed=False,
            criteria_results=[
                ralph.EvalCriterionResult("API works", True, "OK"),
                ralph.EvalCriterionResult("Tests pass", False, "3 failures"),
            ],
            summary="1/2 criteria passed",
        )
        text = ralph.format_eval_summary(result)
        assert "FAIL" in text
        assert "3 failures" in text


# ─── Learnings extraction ───────────────────────────────────────────────────

class TestExtractLearnings:
    def test_extracts_learnings(self):
        output = """\
I implemented the full API.

LEARNINGS:
The SQLite driver requires WAL mode for concurrent access.
FastAPI's dependency injection made testing much easier than expected.
"""
        result = ralph.extract_learnings(output)
        assert "WAL mode" in result
        assert "dependency injection" in result

    def test_no_learnings(self):
        output = "I implemented everything. Done."
        result = ralph.extract_learnings(output)
        assert result == ""

    def test_learnings_with_backticks(self):
        output = """\
Done.
```
LEARNINGS:
Important discovery about the codebase.
```
"""
        result = ralph.extract_learnings(output)
        assert "Important discovery" in result

    def test_learnings_inline(self):
        output = "LEARNINGS: The API requires auth headers for all endpoints."
        result = ralph.extract_learnings(output)
        assert "auth headers" in result


# ─── Prompt building tests ───────────────────────────────────────────────────

class TestBuildGeneratorPrompt:
    def test_contains_phase_info(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Basic scaffold",
            acceptance_criteria=["Tests pass", "Server starts"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_prompt(
            phase, "# Header", config, "rules", "abc123 commit",
        )
        assert "Phase 1" in prompt
        assert "Setup" in prompt
        assert "Basic scaffold" in prompt
        assert "Tests pass" in prompt
        assert "rules" in prompt
        assert "abc123" in prompt

    def test_includes_v1_tasks(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Basic scaffold",
            acceptance_criteria=["All done"],
            v1_tasks=["Create project", "Add tests"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_prompt(
            phase, "", config, "", "", "",
        )
        assert "Create project" in prompt
        assert "Legacy Task List" in prompt

    def test_includes_guidance(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_prompt(
            phase, "", config, "", "",
            user_guidance="Focus on edge cases",
        )
        assert "Focus on edge cases" in prompt
        assert "User Guidance" in prompt

    def test_includes_proposed_changes(self):
        phase = ralph.Phase(
            number=2, title="Features", delivers="CRUD",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_prompt(
            phase, "", config, "", "",
            proposed_changes="Add validation to Phase 2",
        )
        assert "Add validation" in prompt
        assert "Proposed Changes" in prompt


class TestBuildEvaluatorPrompt:
    def test_contains_criteria(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["GET /api returns 200", "Tests pass"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_evaluator_prompt(phase, config)
        assert "GET /api returns 200" in prompt
        assert "Tests pass" in prompt

    def test_includes_playwright(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Page loads"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_evaluator_prompt(phase, config)
        assert "Playwright" in prompt
        assert "playwright" in prompt.lower()

    def test_adversarial_instruction(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_evaluator_prompt(phase, config)
        assert "adversarial" in prompt.lower()

    def test_structured_output_format(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_evaluator_prompt(phase, config)
        assert "**Overall**" in prompt
        assert "**Result**" in prompt


class TestBuildRetryPrompt:
    def test_includes_eval_feedback(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_retry_prompt(
            phase, "", config, "", "",
            eval_feedback="PUT endpoint returns 500",
            eval_round=2,
        )
        assert "PUT endpoint returns 500" in prompt
        assert "retry" in prompt.lower()
        assert "FAILED" in prompt or "failed" in prompt.lower()

    def test_includes_round_number(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_generator_retry_prompt(
            phase, "", config, "", "",
            eval_feedback="Issues found",
            eval_round=3,
        )
        assert "3" in prompt


class TestBuildRescuePrompt:
    def test_includes_elapsed_time(self):
        phase = ralph.Phase(
            number=1, title="Setup", delivers="Scaffold",
            acceptance_criteria=["Done"],
        )
        config = ralph.Config(plan_path="/tmp/plan.md", work_dir="/tmp")
        prompt = ralph.build_rescue_prompt(
            phase, "", config, "", "", elapsed_mins=45,
        )
        assert "45" in prompt
        assert "stuck" in prompt.lower()


# ─── Learnings file tests ───────────────────────────────────────────────────

class TestLearnings:
    def test_load_missing(self, tmp_path):
        assert ralph.load_learnings(str(tmp_path / "nope.md")) == ""

    def test_append_creates_file(self, tmp_path):
        p = tmp_path / "learnings.md"
        ralph.append_learning(str(p), "Phase 1: Setup", "SQLite needs WAL mode.")
        content = p.read_text()
        assert "# Learnings" in content
        assert "Phase 1: Setup" in content
        assert "WAL mode" in content

    def test_append_to_existing(self, tmp_path):
        p = tmp_path / "learnings.md"
        p.write_text("# Learnings\n")
        ralph.append_learning(str(p), "Phase 1", "Learning A")
        ralph.append_learning(str(p), "Phase 2", "Learning B")
        content = p.read_text()
        assert "Phase 1" in content
        assert "Phase 2" in content

    def test_concurrent_appends(self, tmp_path):
        p = tmp_path / "learnings.md"
        p.write_text("# Learnings\n")
        path = str(p)

        def writer(prefix, count):
            for i in range(count):
                ralph.append_learning(path, f"{prefix}-{i}", f"note {i}")

        t1 = threading.Thread(target=writer, args=("A", 25))
        t2 = threading.Thread(target=writer, args=("B", 25))
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        content = p.read_text()
        # Each append writes "## [timestamp] prefix-N" headers
        headers = [l for l in content.splitlines() if l.startswith("## [")]
        assert len(headers) == 50


# ─── Proposed changes ────────────────────────────────────────────────────────

class TestProposedChanges:
    def test_derive_path(self):
        result = ralph.derive_proposed_changes_path("/tmp/my-plan.md")
        assert result == "/tmp/my-plan-proposed-changes.md"

    def test_load_missing(self, tmp_path):
        p = tmp_path / "plan.md"
        p.write_text("# Plan\n")
        assert ralph.load_proposed_changes(str(p)) == ""

    def test_load_existing(self, tmp_path):
        p = tmp_path / "plan.md"
        p.write_text("# Plan\n")
        changes = tmp_path / "plan-proposed-changes.md"
        changes.write_text("## After Phase 1\n- Add validation\n")
        content = ralph.load_proposed_changes(str(p))
        assert "Add validation" in content


# ─── Config tests ────────────────────────────────────────────────────────────

class TestConfig:
    def test_defaults(self):
        c = ralph.Config()
        assert c.max_eval_rounds == 3
        assert c.skip_eval is False
        assert c.delay == 0

    def test_model_flags_empty(self):
        c = ralph.Config()
        assert c.claude_model_flags() == []

    def test_model_flags_with_model(self):
        c = ralph.Config(model="claude-opus-4-6", effort="high")
        flags = c.claude_model_flags()
        assert "--model" in flags
        assert "--effort" in flags
        assert "high" in flags


class TestModelPresets:
    def test_all_presets(self):
        for name, (model, effort) in ralph.MODEL_PRESETS.items():
            assert model.startswith("claude-")
            assert isinstance(effort, str)


# ─── Plan summary ───────────────────────────────────────────────────────────

class TestFormatPlanSummary:
    def test_v2_summary(self, v2_plan):
        lines = ralph.format_plan_summary(v2_plan)
        assert any("3 phases" in l for l in lines)
        assert any("Foundation" in l for l in lines)

    def test_v1_summary(self, v1_plan):
        lines = ralph.format_plan_summary(v1_plan)
        assert any("2 phases" in l for l in lines)


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


# ─── Stream parsing ─────────────────────────────────────────────────────────

class TestFormatToolDetail:
    def test_read_tool(self):
        result = ralph.format_tool_detail("Read", {"file_path": "/foo/bar.py"})
        assert "bar.py" in result
        assert "Read" in result

    def test_bash_truncation(self):
        result = ralph.format_tool_detail("Bash", {"command": "a" * 100})
        assert "..." in result

    def test_grep_tool(self):
        result = ralph.format_tool_detail(
            "Grep", {"pattern": "foo", "path": "/tmp/bar.py"}
        )
        assert "/foo/" in result


# ─── Inbox tests ─────────────────────────────────────────────────────────────

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

    def test_no_false_positive(self):
        assert ralph.needs_followup("Task completed successfully.") is False
        assert ralph.needs_followup("") is False


# ─── Find plan tests ────────────────────────────────────────────────────────

class TestFindPlan:
    def test_explicit_path(self, tmp_path):
        p = tmp_path / "my-plan.md"
        p.write_text("# Plan\n")
        assert ralph.find_plan(str(p)) == str(p.resolve())

    def test_explicit_not_found(self, tmp_path):
        with pytest.raises(SystemExit):
            ralph.find_plan(str(tmp_path / "nonexistent.md"))

    def test_cwd_plan_md(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        (tmp_path / "plan.md").write_text("# Plan\n")
        result = ralph.find_plan("")
        assert result.endswith("plan.md")


# ─── TUI tests ──────────────────────────────────────────────────────────────

class TestRalphApp:
    def test_compose_yields_widgets(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        widgets = list(app.compose())
        assert len(widgets) == 3
        assert isinstance(widgets[0], RichLog)
        assert isinstance(widgets[1], Static)
        assert isinstance(widgets[2], Input)

    def test_widget_ids(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        widgets = list(app.compose())
        assert widgets[0].id == "log"
        assert widgets[1].id == "status"

    def test_status_tracking_attrs(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        assert isinstance(app.start_time, float)
        assert app.total_cost == 0.0
        assert app._completed_phases == 0

    def test_command_handlers(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        assert "stop" in app.command_handlers
        assert "plan" in app.command_handlers
        assert "skip" in app.command_handlers
        assert "help" in app.command_handlers

    @pytest.mark.asyncio
    async def test_dry_run_completes(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True,
            delay=0, skip_eval=True,
        )
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            await pilot.pause(delay=3)
        assert app._completed_phases == 3

    @pytest.mark.asyncio
    async def test_guidance_queue(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "focus on error handling"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            assert len(app.guidance_queue) == 1
            assert app.guidance_queue[0] == "focus on error handling"

    @pytest.mark.asyncio
    async def test_stop_exits(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/stop"
            await input_widget.action_submit()
            await pilot.pause(delay=0.5)

    @pytest.mark.asyncio
    async def test_unknown_command(self, v2_plan):
        config = ralph.Config(
            plan_path=v2_plan, work_dir="/tmp", dry_run=True, delay=0,
        )
        app = ralph.RalphApp(config)
        async with app.run_test(size=(80, 24)) as pilot:
            input_widget = app.query_one(Input)
            input_widget.focus()
            input_widget.value = "/nonexistent"
            await input_widget.action_submit()
            await pilot.pause(delay=0.2)
            assert len(app.guidance_queue) == 0


class TestPhaseFilter:
    def test_single_phase_filter(self, v2_plan):
        """--phase N restricts to a single phase."""
        phases = ralph.parse_phases(v2_plan)
        filtered = [p for p in phases if p.number == 2]
        assert len(filtered) == 1
        assert filtered[0].title == "CRUD Operations"

    def test_nonexistent_phase_filter(self, v2_plan):
        phases = ralph.parse_phases(v2_plan)
        filtered = [p for p in phases if p.number == 99]
        assert len(filtered) == 0
