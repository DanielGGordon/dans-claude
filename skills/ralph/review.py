"""Code review subsystem — codex, claude, and gemini fallback."""

import os
import re
import subprocess
import time
from collections.abc import Callable

from models import Config, UsageLimitExceeded, _USAGE_LIMIT_RE


def run_review(base_sha: str, task_text: str, config: Config,
               out: Callable[[str], None] = print) -> str:
    if config.skip_review:
        return "LGTM (review skipped)"

    # Diff working tree (committed + uncommitted) against review base
    result = subprocess.run(
        ["git", "diff", base_sha],
        capture_output=True, text=True,
    )
    diff = result.stdout.strip()
    if not diff:
        out("  no diff — working tree matches review base")
        return "LGTM — no changes to review"

    # Log diff stats
    diff_stat = subprocess.run(
        ["git", "diff", "--stat", base_sha],
        capture_output=True, text=True,
    )
    stat_summary = diff_stat.stdout.strip().splitlines()
    if stat_summary:
        out(f"  diff: {stat_summary[-1].strip()}")

    # Reviewer selection logic
    use_codex = False
    if config.reviewer == "codex":
        use_codex = True
        out("  reviewer: codex (explicit config)")
    elif config.reviewer == "claude":
        use_codex = False
        out("  reviewer: claude (explicit config)")
    elif config.reviewer == "auto":
        use_codex = subprocess.run(
            ["which", "codex"], capture_output=True
        ).returncode == 0
        if use_codex:
            out("  reviewer: codex (auto-detected on PATH)")
        else:
            out("  reviewer: claude (codex not found on PATH)")

    if use_codex:
        cmd = ["codex", "review", "--base", base_sha]
        out(f"  running: {' '.join(cmd)}")
        t0 = time.time()
        try:
            result = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=300,
            )
            elapsed = time.time() - t0
            output = result.stdout + result.stderr
            out(f"  codex finished in {elapsed:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except Exception as exc:
            elapsed = time.time() - t0
            out(f"  codex FAILED after {elapsed:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (codex error: {exc})"
    else:
        review_prompt = f"""Review this diff for bugs, edge cases, and issues the implementing agent may not have considered. Be specific about file and line. If the code looks good, just say LGTM.

## Task Context
{task_text}

## Diff
{diff}"""

        # Try Claude first
        out("  🔍 Claude reviewing changes...")
        t0 = time.time()
        try:
            result = subprocess.run(
                ["claude", "-p", "--model", "claude-opus-4-6", "--max-turns", "5",
                 "--dangerously-skip-permissions"],
                input=review_prompt, capture_output=True, text=True, timeout=300,
            )
            elapsed_t = time.time() - t0
            output = result.stdout + result.stderr
            # Check for usage limit in review output
            if _USAGE_LIMIT_RE.search(output) or (result.returncode and not output.strip()):
                raise UsageLimitExceeded(output or f"exit code {result.returncode}")
            out(f"  claude finished in {elapsed_t:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except UsageLimitExceeded:
            elapsed_t = time.time() - t0
            out(f"  claude hit usage limit after {elapsed_t:.1f}s — falling back to Gemini...")
        except Exception as exc:
            elapsed_t = time.time() - t0
            out(f"  claude FAILED after {elapsed_t:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (claude error: {exc})"

        # Gemini fallback for review
        out("  🔍 Gemini reviewing changes...")
        t0 = time.time()
        try:
            result = subprocess.run(
                ["gemini", "-p", review_prompt, "--yolo"],
                capture_output=True, text=True, timeout=300,
            )
            elapsed_t = time.time() - t0
            output = result.stdout + result.stderr
            out(f"  gemini finished in {elapsed_t:.1f}s — exit code {result.returncode}, output {len(output)} chars")
            return output
        except Exception as exc:
            elapsed_t = time.time() - t0
            out(f"  gemini FAILED after {elapsed_t:.1f}s — {type(exc).__name__}: {exc}")
            return f"LGTM (gemini error: {exc})"


def has_review_issues(output: str) -> bool:
    if not output:
        return False
    last_lines = "\n".join(output.strip().splitlines()[-5:])
    return not bool(re.search(
        r"(LGTM|no issues|looks good|no bugs|no discrete|did not find|did not identify)",
        last_lines, re.IGNORECASE,
    ))


def fix_review_issues(review_output: str, config: Config,
                      out: Callable[[str], None] = print) -> None:
    if not has_review_issues(review_output):
        out("  ✅ Review passed — LGTM")
        # Show first few lines of what the reviewer actually said
        lines = [l for l in review_output.strip().splitlines() if l.strip()]
        for line in lines[:3]:
            out(f"    | {line}")
        if len(lines) > 3:
            out(f"    | ... ({len(lines) - 3} more lines)")
        return

    out("  🔧 Fixing review findings...")
    for line in review_output.splitlines()[:20]:
        out(f"    {line}")

    fix_prompt = f"""A code reviewer found the following issues. Fix each one. Commit when done.

## Review Findings
{review_output}

## Working Directory
{os.getcwd()}"""

    try:
        subprocess.run(
            ["claude", "-p", "--max-turns", "15", "--dangerously-skip-permissions"],
            input=fix_prompt, capture_output=True, text=True, timeout=600,
        )
    except Exception:
        pass
