"""Generic AI-driven recovery wrapper.

Any subprocess that fails — git rebase conflicts, broken merges, dirty
worktrees, install failures, flaky tests — is handed to `claude -p` with the
failure context and a recovery directive. Claude resolves it in the working
tree, then the original command is retried.

The goal is language- and tool-agnostic: nothing in here hardcodes npm/cargo/
pip. The recovery agent inspects the repo and chooses appropriate commands.
"""

from __future__ import annotations

import subprocess
from collections.abc import Callable
from dataclasses import dataclass


@dataclass
class RecoveryResult:
    ok: bool
    attempts: int
    last_stdout: str
    last_stderr: str
    last_returncode: int
    agent_summary: str = ""


def _truncate(s: str, limit: int = 4000) -> str:
    if not s:
        return ""
    if len(s) <= limit:
        return s
    head = s[: limit // 2]
    tail = s[-(limit // 2):]
    return f"{head}\n…[truncated {len(s) - limit} chars]…\n{tail}"


def invoke_recovery_agent(
    *,
    cwd: str,
    failure_context: str,
    directive: str,
    on_output: Callable[[str], None] = print,
    timeout: int = 600,
) -> tuple[bool, str]:
    """Run a one-shot `claude -p` in `cwd` with full permissions to fix things.

    Returns (success, summary_text). Success is best-effort: claude exit 0 +
    non-empty output. The caller must independently verify the desired state
    afterwards.
    """
    prompt = (
        f"{directive}\n\n"
        f"Working directory: {cwd}\n\n"
        f"Failure context:\n```\n{failure_context}\n```\n\n"
        f"Investigate the working tree, take whatever corrective actions are "
        f"needed, and report a one-paragraph summary of what you did. If the "
        f"situation is unrecoverable, say so explicitly and stop."
    )
    on_output("  [recovery] invoking claude agent")
    try:
        proc = subprocess.run(
            ["claude", "-p", "--dangerously-skip-permissions",
             "--output-format", "text"],
            input=prompt,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        on_output("  [recovery] agent timed out")
        return False, ""

    summary = (proc.stdout or "").strip()
    if proc.returncode != 0:
        on_output(f"  [recovery] agent exited {proc.returncode}")
        return False, summary
    if summary:
        # surface first non-empty line for the TUI
        first = next((ln for ln in summary.splitlines() if ln.strip()), "")
        if first:
            on_output(f"  [recovery] {first[:200]}")
    return True, summary


def run_with_recovery(
    cmd: list[str],
    *,
    cwd: str,
    on_output: Callable[[str], None] = print,
    directive: str = "",
    extra_context: str = "",
    max_retries: int = 1,
    check_ok: Callable[[], tuple[bool, str]] | None = None,
    timeout: int = 0,
) -> RecoveryResult:
    """Run `cmd`. If it fails (or `check_ok` says state is wrong), call the
    recovery agent and retry up to `max_retries` times.

    `check_ok` is a callable returning (ok, why_not). It runs AFTER cmd
    succeeds and lets the caller assert post-conditions (e.g. "working tree
    clean", "no rebase in progress") that a zero exit code doesn't guarantee.
    """
    if not directive:
        directive = (
            "A subprocess failed. Diagnose the cause from the failure context "
            "and the current state of the working directory, then resolve the "
            "issue so the command can succeed on a retry. Do not skip past "
            "the underlying problem (e.g. with --force, --no-verify, "
            "--skip)."
        )

    attempts = 0
    last_stdout = ""
    last_stderr = ""
    last_rc = 0

    while attempts <= max_retries:
        attempts += 1
        try:
            proc = subprocess.run(
                cmd, cwd=cwd, capture_output=True, text=True,
                timeout=timeout if timeout > 0 else None,
            )
        except subprocess.TimeoutExpired as e:
            last_stdout = e.stdout or ""
            last_stderr = (e.stderr or "") + "\n[command timed out]"
            last_rc = -1
        else:
            last_stdout = proc.stdout or ""
            last_stderr = proc.stderr or ""
            last_rc = proc.returncode

        cmd_str = " ".join(cmd)
        ok = last_rc == 0
        why_not = ""
        if ok and check_ok is not None:
            ok, why_not = check_ok()
            if not ok:
                on_output(f"  [recovery] post-check failed: {why_not}")

        if ok:
            return RecoveryResult(
                ok=True, attempts=attempts,
                last_stdout=last_stdout, last_stderr=last_stderr,
                last_returncode=last_rc,
            )

        if attempts > max_retries:
            break

        failure_context = (
            f"Command: {cmd_str}\n"
            f"Exit code: {last_rc}\n"
            f"--- stdout ---\n{_truncate(last_stdout)}\n"
            f"--- stderr ---\n{_truncate(last_stderr)}\n"
        )
        if why_not:
            failure_context += f"--- post-check ---\n{why_not}\n"
        if extra_context:
            failure_context += f"--- extra context ---\n{extra_context}\n"

        on_output(
            f"  [recovery] '{cmd_str[:80]}' failed (exit {last_rc}); "
            f"attempt {attempts}/{max_retries + 1}"
        )
        agent_ok, summary = invoke_recovery_agent(
            cwd=cwd,
            failure_context=failure_context,
            directive=directive,
            on_output=on_output,
        )
        if not agent_ok:
            return RecoveryResult(
                ok=False, attempts=attempts,
                last_stdout=last_stdout, last_stderr=last_stderr,
                last_returncode=last_rc,
                agent_summary=summary,
            )

    return RecoveryResult(
        ok=False, attempts=attempts,
        last_stdout=last_stdout, last_stderr=last_stderr,
        last_returncode=last_rc,
    )


# ─── Git-specific helpers ──────────────────────────────────────────────────

def git_state_clean(repo_dir: str) -> tuple[bool, str]:
    """Return (ok, reason). Clean = no uncommitted changes and no in-progress
    rebase/merge/cherry-pick/bisect."""
    import os
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_dir, capture_output=True, text=True,
    )
    if status.stdout.strip():
        return False, f"working tree dirty:\n{status.stdout}"
    git_dir = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        cwd=repo_dir, capture_output=True, text=True,
    ).stdout.strip()
    if not git_dir:
        return False, "could not locate .git dir"
    if not os.path.isabs(git_dir):
        git_dir = os.path.join(repo_dir, git_dir)
    sentinels = [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
        "rebase-apply", "rebase-merge",
    ]
    for s in sentinels:
        if os.path.exists(os.path.join(git_dir, s)):
            return False, f"in-progress operation: {s}"
    return True, ""


def post_merge_wrap(
    repo_dir: str,
    on_output: Callable[[str], None] = print,
    timeout: int = 1800,
) -> bool:
    """Generic post-merge verification step.

    Hands off to a claude-p agent that detects the project's build system,
    installs dependencies, runs the test suite, and reports pass/fail. The
    agent decides what commands to use based on the repo contents — Ralph
    stays language-agnostic.
    """
    directive = (
        "All parallel phases have just been merged into the current branch. "
        "Perform a post-merge verification pass:\n"
        "  1. Inspect the repo to identify the project's build/dependency "
        "system (e.g. package.json, Cargo.toml, pyproject.toml, go.mod, "
        "Gemfile, mix.exs, etc.).\n"
        "  2. Run the dependency-install step for that system if one is "
        "needed (lockfile changed, node_modules absent, etc.). Skip if "
        "unnecessary.\n"
        "  3. Run the project's primary test command. If a root-level "
        "command runs all workspaces/packages, prefer that.\n"
        "  4. If linters or type-checkers are configured (and fast), run "
        "them too.\n"
        "  5. Report a concise pass/fail summary per step. Do not modify "
        "source code; if a test fails, report it — do not try to fix it.\n"
        "Exit with a clear final verdict: ALL GREEN or FAILURES PRESENT."
    )
    on_output("Post-merge wrap: verifying merged state")
    ok, summary = invoke_recovery_agent(
        cwd=repo_dir,
        failure_context="(no failure — this is the post-merge verification pass)",
        directive=directive,
        on_output=on_output,
        timeout=timeout,
    )
    if not ok:
        on_output("Post-merge wrap: agent exited non-zero")
        return False
    verdict_green = "ALL GREEN" in summary.upper()
    on_output(
        f"Post-merge wrap: {'✓ ALL GREEN' if verdict_green else '⚠ failures reported'}"
    )
    return verdict_green
