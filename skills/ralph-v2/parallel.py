"""Parallel phase orchestration via git worktrees and tmux."""

import shlex
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from models import Config
from recovery import git_state_clean, run_with_recovery, post_merge_wrap


TMUX_SESSION = "ralph-parallel"


def create_worktrees(phases: list[int], repo_dir: str) -> dict[int, str]:
    """Create a git worktree for each phase, returning {phase: worktree_path}."""
    worktrees: dict[int, str] = {}
    for phase in phases:
        branch = f"ralph/phase-{phase}"
        wt_path = f"{repo_dir}-ralph-phase-{phase}"
        subprocess.run(
            ["git", "worktree", "add", wt_path, "-b", branch, "HEAD"],
            cwd=repo_dir, capture_output=True, text=True, check=True,
        )
        worktrees[phase] = wt_path
    return worktrees


def cleanup_worktrees(worktrees: dict[int, str], repo_dir: str) -> None:
    """Remove worktrees and delete their branches."""
    for phase, wt_path in worktrees.items():
        branch = f"ralph/phase-{phase}"
        subprocess.run(
            ["git", "worktree", "remove", "--force", wt_path],
            cwd=repo_dir, capture_output=True, text=True,
        )
        subprocess.run(
            ["git", "branch", "-D", branch],
            cwd=repo_dir, capture_output=True, text=True,
        )


def merge_parallel_branches(
    phases: list[int],
    worktrees: dict[int, str],
    repo_dir: str,
    on_output: Callable[[str], None] = print,
    *,
    run_post_wrap: bool = True,
) -> None:
    """Merge each phase branch back into main sequentially.

    Every git operation is wrapped in `run_with_recovery` so a non-zero exit
    code, a half-finished rebase, or a dirty working tree triggers a
    `claude -p` recovery agent before we give up. The merge step also
    verifies the working tree is clean before continuing to the next branch,
    closing the gap where a "resolved" conflict left files uncommitted.
    """
    # Make sure we start from a clean tree — uncommitted changes here will
    # silently sabotage `git merge --ff-only` and `git rebase`.
    ok, why = git_state_clean(repo_dir)
    if not ok:
        on_output(f"  Pre-merge: working tree not clean ({why})")
        res = run_with_recovery(
            ["git", "status"], cwd=repo_dir, on_output=on_output,
            directive=(
                "Ralph is about to merge parallel phase branches but the "
                "working tree is not clean. Decide whether the uncommitted "
                "changes should be committed, stashed, or discarded based on "
                "their content, then leave the working tree clean. Be "
                "conservative: prefer commit or stash over discard."
            ),
            extra_context=why,
            check_ok=lambda: git_state_clean(repo_dir),
        )
        if not res.ok:
            raise RuntimeError(
                "Pre-merge cleanup failed: working tree still dirty"
            )

    for i, phase in enumerate(phases):
        branch = f"ralph/phase-{phase}"
        on_output(f"  Merging {branch}...")

        if i > 0:
            rebase_res = run_with_recovery(
                ["git", "rebase", "HEAD", branch],
                cwd=repo_dir, on_output=on_output,
                directive=(
                    f"A git rebase of '{branch}' (phase {phase}) onto the "
                    f"current branch failed. Other phases already merged: "
                    f"{phases[:i]}. Resolve every conflict in the working "
                    f"tree, `git add` the resolved files, run "
                    f"`git rebase --continue` until the rebase completes, "
                    f"and leave HEAD on '{branch}' with a clean working "
                    f"tree. If conflicts are genuinely irreconcilable, run "
                    f"`git rebase --abort` and report why."
                ),
                check_ok=lambda: git_state_clean(repo_dir),
            )
            if not rebase_res.ok:
                # Make sure we leave no dangling rebase state behind.
                subprocess.run(
                    ["git", "rebase", "--abort"],
                    cwd=repo_dir, capture_output=True, text=True,
                )
                raise RuntimeError(
                    f"Rebase of {branch} could not be completed."
                )

        # Try fast-forward first; fall back to a merge commit if histories
        # have diverged. Both go through recovery so an unexpected error
        # (e.g. uncommitted leftovers) gets addressed instead of bubbling up.
        ff_res = run_with_recovery(
            ["git", "merge", "--ff-only", branch],
            cwd=repo_dir, on_output=on_output,
            max_retries=0,  # don't recover ff-only; we'll fall through
        )
        if not ff_res.ok:
            merge_res = run_with_recovery(
                ["git", "merge", branch, "-m",
                 f"Merge parallel phase {phase}"],
                cwd=repo_dir, on_output=on_output,
                directive=(
                    f"`git merge {branch}` failed. Inspect the working tree "
                    f"and resolve whatever is blocking the merge (conflicts, "
                    f"uncommitted state, missing files). Complete the merge "
                    f"and leave the working tree clean."
                ),
                check_ok=lambda: git_state_clean(repo_dir),
            )
            if not merge_res.ok:
                raise RuntimeError(
                    f"Merge failed for {branch}: {merge_res.last_stderr}"
                )
        on_output(f"  {branch} merged")

    if run_post_wrap:
        post_merge_wrap(repo_dir, on_output=on_output)


def _build_ralph_flags(config: Config) -> str:
    """Build CLI flags string from Config to pass to parallel ralph instances."""
    flags: list[str] = []
    if config.model:
        flags.append(f"--model {config.model}")
    if config.effort:
        flags.append(f"--effort {config.effort}")
    if config.skip_eval:
        flags.append("--no-eval")
    if config.task_timeout != 3600:
        flags.append(f"--task-timeout {config.task_timeout}")
    if config.max_eval_rounds != 3:
        flags.append(f"--max-eval-rounds {config.max_eval_rounds}")
    if config.reuse_context:
        flags.append("--reuse-context")
    if config.delay > 0:
        flags.append(f"--delay {config.delay}")
    if config.restart:
        flags.append("--restart")
    if config.prompt:
        flags.append(f"--prompt {shlex.quote(config.prompt)}")
    return " ".join(flags)


def launch_parallel_tmux(
    phases: list[int],
    worktrees: dict[int, str],
    plan_path: str,
    learnings_path: str,
    config: Config,
) -> None:
    """Launch a tmux session with one window per phase running Ralph v2."""
    ralph_script = str(Path(__file__).resolve().parent / "ralph.py")
    config_flags = _build_ralph_flags(config)

    # Kill any leftover session with the same name. tmux's session-uniqueness
    # rule otherwise causes new-session to fail with exit 1, which is a common
    # silent failure mode after an interrupted parallel run.
    subprocess.run(
        ["tmux", "kill-session", "-t", TMUX_SESSION],
        capture_output=True, text=True,
    )

    for i, phase in enumerate(phases):
        wt = worktrees[phase]
        cmd = (f"cd {wt} && python3 {ralph_script} {plan_path}"
               f" --phase {phase} --learnings-path {learnings_path}"
               f" {config_flags}".rstrip())
        if i == 0:
            subprocess.run(
                ["tmux", "new-session", "-d", "-s", TMUX_SESSION,
                 "-n", f"phase-{phase}", cmd],
                check=True,
            )
        else:
            subprocess.run(
                ["tmux", "new-window", "-t", TMUX_SESSION,
                 "-n", f"phase-{phase}", cmd],
                check=True,
            )


def wait_for_parallel_completion(
    log_path: str = "",
    on_output: Callable[[str], None] | None = None,
) -> None:
    """Block until all windows in the ralph-parallel tmux session have exited.

    If log_path and on_output are provided, tails the log file and streams
    new lines to on_output so the parent TUI stays updated.
    """
    # Record current end of log so we only stream new content from children
    log_pos = 0
    if log_path and on_output:
        try:
            log_pos = Path(log_path).stat().st_size
        except OSError:
            pass

    while True:
        result = subprocess.run(
            ["tmux", "list-windows", "-t", TMUX_SESSION],
            capture_output=True, text=True,
        )

        # Stream new log lines from parallel children
        if log_path and on_output:
            try:
                with open(log_path, "r") as f:
                    f.seek(log_pos)
                    new_data = f.read()
                    log_pos = f.tell()
                if new_data:
                    for line in new_data.splitlines():
                        on_output(line)
            except OSError:
                pass

        if result.returncode != 0:
            break
        time.sleep(5)


def verify_parallel_results(
    phases: list[int],
    worktrees: dict[int, str],
    repo_dir: str,
    on_output: Callable[[str], None] = print,
) -> list[int]:
    """Verify each parallel branch has commits. Returns list of failed phase numbers."""
    base_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_dir, capture_output=True, text=True,
    ).stdout.strip()

    failed: list[int] = []
    for phase in phases:
        branch = f"ralph/phase-{phase}"
        # Check if branch exists
        branch_check = subprocess.run(
            ["git", "rev-parse", "--verify", branch],
            cwd=repo_dir, capture_output=True, text=True,
        )
        if branch_check.returncode != 0:
            on_output(f"  ⚠ Phase {phase}: branch {branch} does not exist")
            failed.append(phase)
            continue

        # Check if branch has commits ahead of base
        log_result = subprocess.run(
            ["git", "log", "--oneline", f"{base_sha}..{branch}"],
            cwd=repo_dir, capture_output=True, text=True,
        )
        commit_count = len(log_result.stdout.strip().splitlines()) if log_result.stdout.strip() else 0
        if commit_count == 0:
            on_output(f"  ⚠ Phase {phase}: branch {branch} has no commits (phase likely crashed)")
            failed.append(phase)
        else:
            on_output(f"  ✓ Phase {phase}: {commit_count} commit(s) on {branch}")

    return failed
