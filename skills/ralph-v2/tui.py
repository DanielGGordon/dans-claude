"""Textual TUI application for Ralph v2 -- phase-level dashboard."""

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
    State, PhaseStatus, Config, ClaudeResult, Phase,
    AgentKilled, AgentTimeout, UsageLimitExceeded,
    RALPH_ASCII, MAX_CONSECUTIVE_FAILS, CONTEXT_REUSE_THRESHOLD,
    elapsed, format_tokens,
)
from plan import (
    parse_phases, get_plan_header, find_parallel_phases,
    parse_parallel_group, load_proposed_changes,
    check_off_v1_tasks, format_plan_summary,
    load_learnings, append_learning,
)
from prompt import (
    get_recent_commits, load_coding_rules, load_project_context,
    build_generator_prompt, build_evaluator_prompt,
    build_generator_retry_prompt, build_rescue_prompt,
    extract_learnings,
)
from runner import run_claude, read_inbox, needs_followup
from evaluator import parse_eval_output, format_eval_summary
from parallel import (
    create_worktrees, cleanup_worktrees, merge_parallel_branches,
    launch_parallel_tmux, wait_for_parallel_completion, TMUX_SESSION,
)


class RalphApp(App):
    """Textual TUI for Ralph v2 -- phase-level build/evaluate dashboard."""

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

    COMMAND_VALID_STATES: dict[str, set[State]] = {
        "skip": {State.RUNNING, State.EVALUATING},
        "stop": {State.RUNNING, State.EVALUATING, State.PAUSED},
        "kill": {State.RUNNING, State.EVALUATING},
        "pause": {State.RUNNING, State.EVALUATING},
        "resume": {State.PAUSED},
        "retry": {State.PAUSED},
    }

    def __init__(self, config: Config, **kwargs):
        super().__init__(**kwargs)
        self.config = config
        self.start_time: float = time.time()
        self.phase_start_time: float = 0.0
        self.total_cost: float = 0.0
        self.current_phase_title: str = ""
        self.current_phase_num: int = 0
        self.total_phases: int = 0
        self.current_status: str = ""  # "Generating", "Evaluating 2/3", etc.
        self._completed_phases: int = 0
        self._failed_phases: int = 0
        self._phase_results: list[tuple[str, ClaudeResult]] = []
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
        from rich.text import Text
        log = self.query_one("#log", RichLog)
        if style:
            log.write(Text(text, style=style))
        else:
            log.write(text)
        if self._log_file:
            timestamp = time.strftime("%H:%M:%S")
            self._log_file.write(f"[{timestamp}] {text}\n")
            self._log_file.flush()

    def update_status(self) -> None:
        parts = [
            f"T {elapsed(self.start_time)}",
            f"$ ${self.total_cost:.4f}",
        ]
        if self.total_phases > 0:
            parts.append(f"Phase {self.current_phase_num}/{self.total_phases}")
        parts.append(self.state.value)
        if self.current_status:
            parts.append(self.current_status)
        if self.current_phase_title and self.phase_start_time > 0:
            parts.append(
                f"{self.current_phase_title} ({elapsed(self.phase_start_time)})"
            )
        self.query_one("#status", Static).update(" | ".join(parts))

    def _git_stash(self, message: str) -> bool:
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
                    self.output(f"Changes stashed ({message})")
                    return True
                else:
                    self.output("git stash failed -- changes left in working tree")
        except Exception:
            pass
        return False

    def cmd_stop(self, _arg: str = "") -> None:
        self._cleanup_proc()
        self._git_stash(
            f"ralph: stopped after {self._completed_phases} phases completed"
        )
        self.output("")
        self.output(
            f"Stopped after {self._completed_phases} phases, "
            f"{self._failed_phases} failed. "
            f"T {elapsed(self.start_time)} | ${self.total_cost:.4f}"
        )
        self.exit()

    def cmd_skip(self, _arg: str = "") -> None:
        self._cleanup_proc()
        self.skip_event.set()
        self.output("Skipping current phase...")

    def cmd_help(self, _arg: str = "") -> None:
        lines = [
            "--- Ralph v2 Commands ---",
            "  /skip     -- Kill current agent, skip to next phase",
            "  /stop     -- Kill current agent, stash changes, exit",
            "  /kill     -- Kill current agent, stash changes, pause",
            "  /pause    -- Pause after current phase finishes",
            "  /resume   -- Unpause, move to next phase (pops stash)",
            "  /retry    -- Unpause, re-run same phase (pops stash)",
            "  /plan     -- Show plan progress",
            "  /help     -- Show this help",
            "--- Guidance ---",
            "  Type anything else to queue guidance for the next phase.",
            "  You can also: echo 'guidance' > .ralph-inbox",
        ]
        for line in lines:
            self.output(line)

    def cmd_plan(self, _arg: str = "") -> None:
        for line in format_plan_summary(self.config.plan_path):
            self.output(line)

    def cmd_kill(self, _arg: str = "") -> None:
        self._cleanup_proc()
        self._stash_created = self._git_stash("ralph: paused by user")
        self.state = State.PAUSED
        self.pause_event.set()
        self.output("Paused. Use /resume or /retry to continue.")

    def cmd_pause(self, _arg: str = "") -> None:
        self.pause_event.set()
        self.output("Will pause after current phase finishes...")

    def cmd_resume(self, _arg: str = "") -> None:
        self._retry = False
        self.state = State.RUNNING
        self.resume_event.set()
        self.output("Resuming -- moving to next phase...")

    def cmd_retry(self, _arg: str = "") -> None:
        self._retry = True
        self.state = State.RUNNING
        self.resume_event.set()
        self.output("Retrying current phase...")

    def _pop_stash(self, out: Callable[[str], None]) -> None:
        try:
            result = subprocess.run(
                ["git", "stash", "pop"],
                capture_output=True, text=True, timeout=10,
                cwd=self.config.work_dir,
            )
            if result.returncode == 0:
                out("Stash restored (git stash pop)")
            else:
                out(f"git stash pop failed: {result.stderr.strip()}")
        except Exception:
            out("git stash pop failed")
        self._stash_created = False

    def _register_proc(self, proc: subprocess.Popen) -> None:
        self.current_proc = proc

    def on_input_submitted(self, event: Input.Submitted) -> None:
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
                        f"/{cmd_name} is not valid in {self.state.value} state"
                    )
                else:
                    handler(cmd_arg)
            else:
                self.output(f"Unknown command: /{cmd_name}")
        else:
            self.guidance_queue.append(text)
            self.output(f"Queued: {text}")

    def compose(self) -> ComposeResult:
        yield RichLog(id="log", wrap=True)
        yield Static("Ralph v2 -- starting...", id="status")
        yield Input(placeholder="Type guidance or /command...")

    def on_mount(self) -> None:
        self.set_interval(1, self.update_status)
        self._run_phases()

    def _cleanup_proc(self) -> None:
        if self.current_proc is not None:
            try:
                self.current_proc.kill()
                self.current_proc.wait(timeout=5)
            except Exception:
                pass
            self.current_proc = None

    def _collect_guidance(self) -> str:
        """Drain guidance queue and inbox into a single string."""
        parts: list[str] = []
        while self.guidance_queue:
            parts.append(self.guidance_queue.popleft())
        inbox_msg = read_inbox()
        if inbox_msg:
            parts.append(inbox_msg)
            self.output(f"  Inbox: {inbox_msg}")
        return "\n".join(parts)

    @work(thread=True)
    def _run_phases(self) -> None:
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
        if config.skip_eval:
            out("Evaluator: disabled")
        else:
            out(f"Evaluator: enabled (max {config.max_eval_rounds} rounds)")
        out(f"Learnings: {config.learnings_path}")
        out(f"Log: {config.log_path}")
        if config.task_timeout > 0:
            out(f"Phase timeout: {config.task_timeout // 60}m (auto-rescue)")
        out("")

        # Pre-load context
        coding_rules = load_coding_rules()
        recent_commits = get_recent_commits()
        project_context = load_project_context(config.work_dir)
        consecutive_fails = 0

        # Parse phases
        all_phases = parse_phases(config.plan_path)
        if config.phase is not None:
            all_phases = [p for p in all_phases if p.number == config.phase]
        self.total_phases = len(all_phases)

        if not all_phases:
            out("No phases found in plan.")
            self.state = State.DONE
            self.exit()
            return

        out(f"Found {len(all_phases)} phase(s) to execute")
        out("")

        phase_idx = 0
        last_phase: Phase | None = None

        while phase_idx < len(all_phases):
            phase = all_phases[phase_idx]

            # Check pause
            if self.pause_event.is_set():
                self.state = State.PAUSED
                while not self.resume_event.wait(timeout=0.5):
                    if not self.is_running:
                        return
                self.resume_event.clear()
                self.pause_event.clear()

                if self._retry and last_phase is not None:
                    if self._stash_created:
                        self._pop_stash(out)
                    phase = last_phase
                    # Don't increment phase_idx
                else:
                    if self._stash_created:
                        self._pop_stash(out)
                    # Continue with current phase_idx (already incremented or not)
                continue

            last_phase = phase
            self.current_phase_num = phase.number
            self.current_phase_title = phase.title
            self.phase_start_time = time.time()

            # -- Parallel group detection --
            if config.phase is None:
                parallel_group = parse_parallel_group(
                    config.plan_path, phase.number
                )
                if parallel_group:
                    out("=" * 60)
                    out(f"Parallel group detected: phases {parallel_group}")
                    out("=" * 60)
                    try:
                        worktrees = create_worktrees(
                            parallel_group, config.work_dir
                        )
                        launch_parallel_tmux(
                            parallel_group, worktrees,
                            config.plan_path, config.learnings_path, config,
                        )
                        out(f"  tmux attach -t {TMUX_SESSION}")
                        n = len(parallel_group)
                        self.current_status = f"Parallel: {n} phases"
                        self.update_status()
                        wait_for_parallel_completion()
                        out(f"All {n} parallel phases finished")
                        merge_parallel_branches(
                            parallel_group, worktrees, config.work_dir, out,
                        )
                        cleanup_worktrees(worktrees, config.work_dir)
                        self._completed_phases += n
                    except Exception as e:
                        out(f"Parallel execution failed: {e}",
                            style="bold red")
                    # Skip past all phases in the parallel group
                    while (phase_idx < len(all_phases)
                           and all_phases[phase_idx].number in parallel_group):
                        phase_idx += 1
                    continue

            # -- Single phase execution --
            self.state = State.RUNNING
            self.current_status = "Generating"
            out("=" * 60)
            out(f"Phase {phase.number}: {phase.title}")
            out(f"Delivers: {phase.delivers}")
            out(f"Criteria: {len(phase.acceptance_criteria)}")
            for i, c in enumerate(phase.acceptance_criteria, 1):
                out(f"  {i}. {c}")
            out("=" * 60)

            if config.dry_run:
                out("[dry-run] Would execute this phase")
                if self.skip_event.wait(timeout=0.3):
                    self.skip_event.clear()
                    out("Skipped")
                    phase_idx += 1
                    continue
                if self.pause_event.is_set():
                    continue
                if phase.v1_tasks:
                    check_off_v1_tasks(config.plan_path, phase)
                self._completed_phases += 1
                phase_idx += 1
                continue

            # Collect guidance
            user_guidance = self._collect_guidance()

            # Load fresh context
            learnings_content = load_learnings(config.learnings_path)
            plan_header = get_plan_header(config.plan_path)
            proposed_changes = load_proposed_changes(config.plan_path)

            # -- Build/evaluate loop --
            phase_passed = False
            eval_feedback = ""

            try:
                for eval_round in range(1, config.max_eval_rounds + 1):
                    # Check for skip/pause between rounds
                    if self.skip_event.is_set():
                        self.skip_event.clear()
                        out("Skipped")
                        break
                    if self.pause_event.is_set():
                        break

                    # -- Generator --
                    self.state = State.RUNNING
                    if eval_round == 1:
                        self.current_status = "Generating"
                        out(f"\n--- Generator (round {eval_round}) ---")
                        prompt = build_generator_prompt(
                            phase, plan_header, config,
                            coding_rules, recent_commits,
                            user_guidance=user_guidance,
                            project_context=project_context,
                            learnings=learnings_content,
                            proposed_changes=proposed_changes,
                        )
                    else:
                        self.current_status = f"Retrying ({eval_round}/{config.max_eval_rounds})"
                        out(f"\n--- Generator retry (round {eval_round}/{config.max_eval_rounds}) ---")
                        prompt = build_generator_retry_prompt(
                            phase, plan_header, config,
                            coding_rules, recent_commits,
                            eval_feedback, eval_round,
                            user_guidance=user_guidance,
                            project_context=project_context,
                            learnings=learnings_content,
                            proposed_changes=proposed_changes,
                        )

                    gen_result = run_claude(
                        prompt, config, on_output=out,
                        proc_register=self._register_proc,
                        timeout=config.task_timeout,
                    )
                    self.current_proc = None
                    self.total_cost += gen_result.cost
                    self._phase_results.append(
                        (f"Gen P{phase.number} R{eval_round}", gen_result)
                    )

                    # Extract learnings from generator output
                    gen_learnings = extract_learnings(gen_result.text)

                    if needs_followup(gen_result.text):
                        out("Agent may need input -- check output above")

                    # -- Evaluator --
                    if config.skip_eval:
                        out("\nEvaluator: skipped (--no-eval)")
                        phase_passed = True
                        # Save learnings from generator
                        if gen_learnings:
                            append_learning(
                                config.learnings_path,
                                f"Phase {phase.number}: {phase.title}",
                                gen_learnings,
                            )
                        break

                    self.state = State.EVALUATING
                    self.current_status = f"Eval {eval_round}/{config.max_eval_rounds}"
                    out(f"\n--- Evaluator (round {eval_round}/{config.max_eval_rounds}) ---")

                    eval_prompt = build_evaluator_prompt(phase, config)
                    eval_result_claude = run_claude(
                        eval_prompt, config, on_output=out,
                        proc_register=self._register_proc,
                        timeout=config.task_timeout,
                    )
                    self.current_proc = None
                    self.total_cost += eval_result_claude.cost
                    self._phase_results.append(
                        (f"Eval P{phase.number} R{eval_round}",
                         eval_result_claude)
                    )

                    # Parse evaluator output
                    eval_result = parse_eval_output(eval_result_claude.text)
                    out("")
                    out(format_eval_summary(eval_result),
                        style="green" if eval_result.passed else "red")

                    if eval_result.passed:
                        out(f"\nPhase {phase.number} PASSED")
                        phase_passed = True
                        if gen_learnings:
                            append_learning(
                                config.learnings_path,
                                f"Phase {phase.number}: {phase.title}",
                                gen_learnings,
                            )
                        break
                    else:
                        eval_feedback = eval_result.raw_output
                        if eval_round < config.max_eval_rounds:
                            out(f"\nPhase {phase.number} FAILED "
                                f"-- retrying ({eval_round}/{config.max_eval_rounds})")
                        else:
                            out(f"\nPhase {phase.number} FAILED after "
                                f"{config.max_eval_rounds} rounds")

                    # Refresh commits between rounds
                    recent_commits = get_recent_commits()

                if phase_passed:
                    self._completed_phases += 1
                    consecutive_fails = 0
                    if phase.v1_tasks:
                        check_off_v1_tasks(config.plan_path, phase)
                else:
                    self._failed_phases += 1
                    consecutive_fails += 1

            except UsageLimitExceeded as e:
                self.current_proc = None
                out(f"\nClaude usage limit hit -- stopping.")
                out(f"   ({e})")
                break

            except AgentTimeout:
                self.current_proc = None
                elapsed_mins = int(
                    (time.time() - self.phase_start_time) / 60
                )
                out(f"\nPhase timed out after {elapsed_mins}m "
                    "-- launching rescue agent...")
                append_learning(
                    config.learnings_path,
                    f"Phase {phase.number}: {phase.title} [TIMED OUT]",
                    f"Phase timed out after {elapsed_mins} minutes.",
                )

                rescue_learnings = load_learnings(config.learnings_path)
                rescue_prompt = build_rescue_prompt(
                    phase, plan_header, config,
                    coding_rules, recent_commits, elapsed_mins,
                    learnings=rescue_learnings,
                    project_context=project_context,
                )

                self.phase_start_time = time.time()
                self.current_status = "Rescue"
                out("Rescue agent starting...")
                try:
                    rescue_result = run_claude(
                        rescue_prompt, config, on_output=out,
                        proc_register=self._register_proc,
                    )
                    self.current_proc = None
                    self.total_cost += rescue_result.cost
                    self._phase_results.append(
                        (f"Rescue P{phase.number}", rescue_result)
                    )
                    out("\nRescue agent finished")
                    self._completed_phases += 1
                    consecutive_fails = 0
                except AgentKilled:
                    self.current_proc = None
                    out("Rescue agent killed")
                    self._failed_phases += 1
                    consecutive_fails += 1
                except AgentTimeout:
                    self.current_proc = None
                    out("Rescue agent also timed out -- moving on")
                    self._failed_phases += 1
                    consecutive_fails += 1

            except AgentKilled:
                self.current_proc = None
                if self.skip_event.is_set():
                    self.skip_event.clear()
                    out("Skipped")
                else:
                    out("Agent killed")
                # Don't count as fail if skipped

            # Consecutive failure check
            if consecutive_fails >= MAX_CONSECUTIVE_FAILS:
                out(f"\nStopping: {MAX_CONSECUTIVE_FAILS} consecutive failures.")
                out("   Fix the issue manually, then re-run ralph.")
                break

            # Refresh git history periodically
            if self._completed_phases > 0 and self._completed_phases % 2 == 0:
                recent_commits = get_recent_commits()

            phase_idx += 1

            # Inter-phase delay
            if config.delay > 0 and phase_idx < len(all_phases):
                delay_end = time.time() + config.delay
                while time.time() < delay_end:
                    if self.skip_event.is_set():
                        self.skip_event.clear()
                        break
                    if self.pause_event.is_set():
                        break
                    if not self.is_running:
                        return
                    time.sleep(0.1)

        # Final summary
        out("")
        out("=" * 60)
        out(f"Ralph v2 finished -- {self._completed_phases} passed, "
            f"{self._failed_phases} failed")
        out(f"   T {elapsed(self.start_time)} | ${self.total_cost:.4f}")
        out(f"   Log: {config.log_path}")

        if self._phase_results:
            peaks = [
                r.peak_input_tokens
                for _, r in self._phase_results
                if r.peak_input_tokens > 0
            ]
            total_out = sum(r.output_tokens for _, r in self._phase_results)
            total_turns = sum(r.num_turns for _, r in self._phase_results)
            if peaks:
                avg_peak = sum(peaks) / len(peaks)
                max_peak = max(peaks)
                max_label = next(
                    name for name, r in self._phase_results
                    if r.peak_input_tokens == max_peak
                )
                if len(max_label) > 50:
                    max_label = max_label[:47] + "..."
                out(f"   Context: avg {format_tokens(int(avg_peak))} peak | "
                    f"max {format_tokens(max_peak)} ({max_label})")
                out(f"   Totals: {total_turns} turns | "
                    f"{format_tokens(total_out)} output")

                out("")
                out("   Agent invocation breakdown:")
                for i, (name, r) in enumerate(self._phase_results, 1):
                    short = name[:40] + "..." if len(name) > 40 else name
                    out(f"   {i:2d}. {format_tokens(r.peak_input_tokens):>5s} peak | "
                        f"{r.num_turns:2d} turns | "
                        f"{format_tokens(r.output_tokens):>5s} out | "
                        f"${r.cost:.4f} | {short}")

        out("=" * 60)

        self.state = State.DONE

        if self._log_file:
            self._log_file.close()
            self._log_file = None

        time.sleep(1)
        self.exit()
