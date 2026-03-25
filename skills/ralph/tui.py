"""Textual TUI application for Ralph."""

import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable
from pathlib import Path

from textual.app import App, ComposeResult
from textual.reactive import reactive
from textual.widgets import RichLog, Static, Input
from textual import work

from models import (
    State, Config, ClaudeResult, Task,
    AgentKilled, AgentTimeout, UsageLimitExceeded,
    RALPH_ASCII, MAX_CONSECUTIVE_FAILS, CONTEXT_REUSE_THRESHOLD,
    elapsed, format_tokens,
)
from plan import (
    _TASK_RE, _phase_line_range,
    find_next_task, count_tasks, format_plan_summary, check_off_task,
    collect_batch, is_batch_start, parse_parallel_group,
    trim_plan_for_task,
    load_learnings, append_learning,
)
from prompt import (
    get_recent_commits, load_coding_rules, load_project_context,
    build_single_prompt, build_batch_prompt, build_continuation_prompt,
    build_rescue_prompt,
)
from runner import run_claude, read_inbox, needs_followup
from review import run_review, fix_review_issues
from parallel import (
    create_worktrees, cleanup_worktrees, merge_parallel_branches,
    launch_parallel_tmux, wait_for_parallel_completion, TMUX_SESSION,
)


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

    def _git_stash(self, message: str) -> bool:
        """Stash working tree if dirty. Returns True if a stash was created."""
        try:
            result = subprocess.run(
                ["git", "status", "--porcelain"],
                capture_output=True, text=True, timeout=5,
                cwd=self.config.work_dir,
            )
            if result.stdout.strip():
                stash_result = subprocess.run(
                    ["git", "stash", "push", "-u", "-m", message],
                    capture_output=True, text=True, timeout=10,
                    cwd=self.config.work_dir,
                )
                if stash_result.returncode == 0:
                    self.output(f"📦 Changes stashed ({message})")
                    return True
                else:
                    self.output("⚠️  git stash failed — changes left in working tree")
        except Exception:
            pass
        return False

    def cmd_stop(self, _arg: str = "") -> None:
        """Handle /stop: kill running proc, git stash if dirty, log summary, exit."""
        self._cleanup_proc()
        self._git_stash(f"ralph: stopped after {self._completed} tasks completed")

        # Write summary to log
        self.output("")
        self.output(f"🛑 Stopped after {self._completed} tasks, {self._failed} failed. "
                     f"⏱ {elapsed(self.start_time)} | 💰 ${self.total_cost:.4f}")

        self.exit()

    def cmd_skip(self, _arg: str = "") -> None:
        """Handle /skip: kill running proc, set skip flag, move to next task."""
        self._cleanup_proc()
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
        """Handle /kill: kill proc, git stash, set PAUSED, signal worker."""
        self._cleanup_proc()
        self._stash_created = self._git_stash("ralph: paused by user")

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

    def _handle_task_result(
        self, result: ClaudeResult, task: Task, config: Config,
        *, check_text: str, result_label: str,
        fail_count: int, fail_task_texts: list[str],
        success_count: int, label: str,
        review_base: str, review_text: str,
        consecutive_fails: int,
        out: Callable[[str], None],
    ) -> tuple[int, int]:
        """Process execution result. Returns (consecutive_fails, min_line)."""
        self.current_proc = None
        self.total_cost += result.cost
        self._task_results.append((result_label, result))

        new_task = find_next_task(
            config.plan_path, min_line=task.line_num, phase=config.phase)
        if new_task and new_task.text == check_text:
            self._failed += fail_count
            consecutive_fails += 1
            min_line = task.line_num
            out(f"\n❌ {label} failed (task not checked off)")
            for text in fail_task_texts:
                append_learning(config.learnings_path, text, passed=False)
        else:
            self._completed += success_count
            consecutive_fails = 0
            min_line = task.line_num + 1
            out(f"\n✅ {label} complete")
            if not config.skip_review and review_base:
                r_out = lambda t: out(t, style="steel_blue1")
                r_out("🔍 Reviewing changes...")
                review_result = run_review(
                    review_base, review_text, config, out=r_out)
                fix_review_issues(review_result, config, out=r_out)
                r_out("🔍 Review complete")

        if needs_followup(result.text):
            out("⚠️  Agent may need input — check output above")

        return consecutive_fails, min_line

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
        last_session_id = ""
        last_peak_ctx = 0

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
                # Session is stale after pause — start fresh
                last_session_id = ""

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

                    review_base = self._get_review_base()
                    plan_content = trim_plan_for_task(config.plan_path, task.line_num)

                    if config.batch_mode and is_batch_start(config.plan_path, task.line_num):
                        batch_tasks = collect_batch(config.plan_path, task.line_num)
                        out(f"📦 BATCH ({len(batch_tasks)} tasks):")
                        for t in batch_tasks:
                            out(f"   - {t.text}")

                        prompt = build_batch_prompt(
                            batch_tasks, plan_content, config,
                            coding_rules, recent_commits, guidance,
                            project_context=project_context,
                            learnings_content=learnings_content)

                        result = run_claude(prompt, config, on_output=out,
                                            proc_register=self._register_proc,
                                            timeout=config.task_timeout)

                        plan_lines = Path(config.plan_path).read_text().splitlines()
                        batch_completed = sum(
                            1 for t in batch_tasks
                            if t.line_num - 1 < len(plan_lines)
                            and not _TASK_RE.match(plan_lines[t.line_num - 1])
                        )
                        consecutive_fails, min_line = self._handle_task_result(
                            result, task, config,
                            check_text=batch_tasks[0].text,
                            result_label=f"BATCH: {batch_tasks[0].text}",
                            fail_count=len(batch_tasks),
                            fail_task_texts=[t.text for t in batch_tasks],
                            success_count=batch_completed,
                            label="Batch",
                            review_base=review_base,
                            review_text=batch_tasks[0].text,
                            consecutive_fails=consecutive_fails,
                            out=out,
                        )
                        # Batch tasks don't participate in context reuse
                        last_session_id = ""
                        last_peak_ctx = 0

                    else:
                        # Single task — try context reuse if enabled and previous session was lightweight
                        result = None
                        if config.reuse_context and last_session_id:
                            try:
                                out(f"♻️  Reusing context from previous task ({format_tokens(last_peak_ctx)} peak)")
                                prompt = build_continuation_prompt(
                                    task, config, guidance,
                                    learnings_content=learnings_content)
                                result = run_claude(
                                    prompt, config, on_output=out,
                                    proc_register=self._register_proc,
                                    timeout=config.task_timeout,
                                    continue_session=last_session_id)
                            except (AgentKilled, AgentTimeout):
                                raise
                            except Exception:
                                out("⚠️  Context reuse failed — starting fresh")
                                last_session_id = ""

                        if result is None:
                            prompt = build_single_prompt(
                                task, plan_content, config,
                                coding_rules, recent_commits, guidance,
                                project_context=project_context,
                                learnings_content=learnings_content)
                            result = run_claude(
                                prompt, config, on_output=out,
                                proc_register=self._register_proc,
                                timeout=config.task_timeout)

                        consecutive_fails, min_line = self._handle_task_result(
                            result, task, config,
                            check_text=task.text,
                            result_label=task.text,
                            fail_count=1,
                            fail_task_texts=[task.text],
                            success_count=1,
                            label="Task",
                            review_base=review_base,
                            review_text=task.text,
                            consecutive_fails=consecutive_fails,
                            out=out,
                        )

                        # Track session for potential context reuse on next task
                        if (consecutive_fails == 0
                                and result.session_id
                                and result.peak_input_tokens > 0
                                and result.peak_input_tokens < CONTEXT_REUSE_THRESHOLD):
                            last_session_id = result.session_id
                            last_peak_ctx = result.peak_input_tokens
                        else:
                            last_session_id = ""
                            last_peak_ctx = 0

                except UsageLimitExceeded as e:
                    self.current_proc = None
                    last_session_id = ""
                    out(f"\n🛑 Claude usage limit hit — stopping.")
                    out(f"   ({e})")
                    break

                except AgentTimeout:
                    self.current_proc = None
                    last_session_id = ""
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
                    last_session_id = ""
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
