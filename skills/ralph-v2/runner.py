"""Claude subprocess runner, stream parsing, inbox, and follow-up detection."""

import json
import os
import re
import subprocess
import threading
from collections.abc import Callable
from pathlib import Path

from models import (
    Config, ClaudeResult, AgentKilled, AgentTimeout, UsageLimitExceeded,
    _USAGE_LIMIT_RE, INBOX_FILE, format_context_summary,
)


# ─── Stream parser and Claude runner ────────────────────────────────────────

def format_tool_detail(name: str, input_data: dict) -> str:
    detail = ""
    if name in ("Read", "Write"):
        fp = input_data.get("file_path", "")
        if fp:
            detail = os.path.basename(fp)
    elif name == "Edit":
        fp = input_data.get("file_path", "")
        if fp:
            detail = os.path.basename(fp)
    elif name == "Bash":
        cmd = input_data.get("command", "")
        if len(cmd) > 80:
            cmd = cmd[:77] + "..."
        detail = cmd
    elif name == "Grep":
        pat = input_data.get("pattern", "")
        path = input_data.get("path", "")
        if path:
            path = os.path.basename(path)
        parts = []
        if pat:
            parts.append(f"/{pat}/")
        if path:
            parts.append(f"in {path}")
        detail = " ".join(parts)
    elif name == "Glob":
        detail = input_data.get("pattern", "")
    elif name == "Agent":
        detail = input_data.get("description", "")

    if detail:
        return f"  {name} -- {detail}"
    return f"  {name}"


def run_claude(prompt: str, config: Config,
               on_output: Callable[[str], None] = print,
               proc_register: Callable[[subprocess.Popen], None] | None = None,
               timeout: int = 0,
               continue_session: str = "",
               on_context: Callable[[int], None] | None = None,
               model_flags: list[str] | None = None) -> ClaudeResult:
    cmd = [
        "claude", "-p",
        *(model_flags if model_flags is not None else config.claude_model_flags()),
        "--dangerously-skip-permissions",
        "--verbose",
        "--output-format", "stream-json",
    ]
    if continue_session:
        cmd += ["--resume", continue_session]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    proc.stdin.write(prompt)
    proc.stdin.close()

    if proc_register is not None:
        proc_register(proc)

    # Watchdog: kill proc after timeout (0 = no timeout)
    timed_out = threading.Event()
    watchdog: threading.Timer | None = None
    if timeout > 0:
        def _timeout_kill():
            timed_out.set()
            try:
                proc.kill()
            except Exception:
                pass
        watchdog = threading.Timer(timeout, _timeout_kill)
        watchdog.daemon = True
        watchdog.start()

    result = ClaudeResult()

    for raw_line in proc.stdout:
        line = raw_line.strip()
        if not line:
            continue

        # Fast-path: skip frequent events
        if '"content_block_delta"' in line:
            continue
        if '"content_block_stop"' in line:
            continue
        if '"message_start"' in line:
            continue
        if '"message_delta"' in line:
            continue
        if '"message_stop"' in line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Tool use events + per-turn token tracking
        if event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    name = block.get("name", "")
                    input_data = block.get("input", {})
                    on_output(format_tool_detail(name, input_data))
            usage = event.get("message", {}).get("usage", {})
            if usage:
                turn_input = (usage.get("input_tokens", 0)
                              + usage.get("cache_read_input_tokens", 0)
                              + usage.get("cache_creation_input_tokens", 0))
                if turn_input > result.peak_input_tokens:
                    result.peak_input_tokens = turn_input
                    if on_context is not None:
                        on_context(turn_input)

        elif '"content_block_start"' in line and '"tool_use"' in line:
            tool = event.get("content_block", {}).get("name", "")
            if tool:
                on_output(f"  {tool}")

        elif event.get("type") == "result":
            result.text = event.get("result", "")
            if result.text:
                on_output("")
                on_output(result.text)
            cost = event.get("total_cost_usd")
            if cost is not None:
                result.cost = float(cost)
            usage = event.get("usage", {})
            result.input_tokens = usage.get("input_tokens", 0)
            result.output_tokens = usage.get("output_tokens", 0)
            result.cache_read_tokens = usage.get("cache_read_input_tokens", 0)
            result.cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
            result.session_id = event.get("session_id", "")
            result.num_turns = event.get("num_turns", 0)
            result.duration_ms = event.get("duration_ms", 0)
            result.duration_api_ms = event.get("duration_api_ms", 0)
            on_output(f"  {format_context_summary(result)}")
            on_output(f"  ${result.cost:.4f}")
            break  # result is the final event — stop reading

    if watchdog is not None:
        watchdog.cancel()

    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    if timed_out.is_set():
        raise AgentTimeout()
    if proc.returncode is not None and proc.returncode < 0:
        raise AgentKilled()

    # Detect usage/rate limit errors
    if result.text and _USAGE_LIMIT_RE.search(result.text):
        raise UsageLimitExceeded(result.text)
    if proc.returncode and proc.returncode > 0 and not result.text:
        raise UsageLimitExceeded(f"claude exited with code {proc.returncode}")

    return result


# ─── Inbox & interaction ────────────────────────────────────────────────────

def read_inbox() -> str:
    p = Path(INBOX_FILE)
    if p.is_file() and p.stat().st_size > 0:
        contents = p.read_text()
        p.write_text("")  # clear
        return contents.strip()
    return ""


_FOLLOWUP_RE = re.compile(
    r"(need clarification|which approach|should [iI]|blocked by|unclear|"
    r"question:|please confirm|please advise|awaiting|before I proceed|"
    r"could you|can you clarify|not sure whether|two options|either .+ or)",
    re.IGNORECASE,
)


def needs_followup(text: str) -> bool:
    if not text:
        return False
    return bool(_FOLLOWUP_RE.search(text))
