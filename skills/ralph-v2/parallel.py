"""Parallel phase orchestration via git worktrees and tmux."""

import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from models import Config


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
) -> None:
    """Merge each phase branch back into main sequentially."""
    for i, phase in enumerate(phases):
        branch = f"ralph/phase-{phase}"
        on_output(f"  Merging {branch}...")

        if i > 0:
            rebase = subprocess.run(
                ["git", "rebase", "HEAD", branch],
                cwd=repo_dir, capture_output=True, text=True,
            )
            if rebase.returncode != 0:
                on_output(f"  Rebase conflict on {branch} -- attempting auto-resolve")
                diff_result = subprocess.run(
                    ["git", "diff"], cwd=repo_dir, capture_output=True, text=True,
                )
                conflict_diff = diff_result.stdout[:4000]

                resolve_prompt = (
                    f"You are resolving a git rebase conflict.\n\n"
                    f"Branch '{branch}' (phase {phase}) is being rebased onto main.\n"
                    f"The other phases ({phases[:i]}) have already been merged.\n\n"
                    f"Conflict diff:\n```\n{conflict_diff}\n```\n\n"
                    f"Resolve all conflicts in the working tree, then run "
                    f"'git add' on resolved files and 'git rebase --continue'.\n"
                    f"If the conflicts are irreconcilable, run 'git rebase --abort' "
                    f"and explain why."
                )
                agent = subprocess.run(
                    ["claude", "-p", "--dangerously-skip-permissions",
                     "--output-format", "text"],
                    input=resolve_prompt,
                    cwd=repo_dir, capture_output=True, text=True, timeout=300,
                )
                if agent.returncode != 0:
                    subprocess.run(
                        ["git", "rebase", "--abort"],
                        cwd=repo_dir, capture_output=True, text=True,
                    )
                    raise RuntimeError(
                        f"Failed to resolve conflicts merging {branch}."
                    )
                on_output(f"  Conflicts resolved by Claude agent")

        merge = subprocess.run(
            ["git", "merge", "--ff-only", branch],
            cwd=repo_dir, capture_output=True, text=True,
        )
        if merge.returncode != 0:
            merge = subprocess.run(
                ["git", "merge", branch, "-m", f"Merge parallel phase {phase}"],
                cwd=repo_dir, capture_output=True, text=True,
            )
            if merge.returncode != 0:
                raise RuntimeError(
                    f"Merge failed for {branch}: {merge.stderr}"
                )
        on_output(f"  {branch} merged")


def launch_parallel_tmux(
    phases: list[int],
    worktrees: dict[int, str],
    plan_path: str,
    learnings_path: str,
    config: Config,
) -> None:
    """Launch a tmux session with one window per phase running Ralph v2."""
    ralph_script = str(Path(__file__).resolve().parent / "ralph.py")
    model_flags = ""
    if config.model:
        model_flags += f" --model {config.model}"

    for i, phase in enumerate(phases):
        wt = worktrees[phase]
        cmd = (f"cd {wt} && python3 {ralph_script} {plan_path}"
               f" --phase {phase} --learnings-path {learnings_path}"
               f"{model_flags}")
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


def wait_for_parallel_completion() -> None:
    """Block until all windows in the ralph-parallel tmux session have exited."""
    while True:
        result = subprocess.run(
            ["tmux", "list-windows", "-t", TMUX_SESSION],
            capture_output=True, text=True,
        )
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
