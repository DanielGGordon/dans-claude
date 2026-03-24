"""Prompt building for Ralph task execution."""

import subprocess
from pathlib import Path

from models import Config, Task, CODING_AGENTS_FILE


# ─── Context loading ────────────────────────────────────────────────────────

def get_recent_commits() -> str:
    try:
        result = subprocess.run(
            ["git", "log", "--oneline", "-3"],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip() or "No git history available."
    except Exception:
        return "No git history available."


def load_coding_rules() -> str:
    if CODING_AGENTS_FILE.is_file():
        return CODING_AGENTS_FILE.read_text()
    return ""


def load_project_context(work_dir: str) -> str:
    """Load README.md and PROJECT_STRUCTURE.md from the working directory if they exist."""
    parts: list[str] = []
    for filename in ("README.md", "PROJECT_STRUCTURE.md"):
        filepath = Path(work_dir) / filename
        if filepath.is_file():
            contents = filepath.read_text().strip()
            if contents:
                parts.append(f"This is the {filename}:\n\n{contents}")
    return "\n\n".join(parts)


# ─── Shared prompt context ──────────────────────────────────────────────────

def _append_prompt_context(prompt: str, learnings_content: str = "",
                           project_context: str = "",
                           user_guidance: str = "") -> str:
    """Append learnings, project context, and user guidance sections to a prompt."""
    if learnings_content:
        prompt += f"""

## Progress & Learnings

Previous tasks recorded these notes. Read them to avoid repeating mistakes or rediscovering gotchas:

{learnings_content}"""

    if project_context:
        prompt += f"""

## Project Context

{project_context}"""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

{user_guidance}"""

    return prompt


# ─── Prompt builders ────────────────────────────────────────────────────────

def build_single_prompt(task: Task, plan_content: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        user_guidance: str,
                        project_context: str = "",
                        learnings_content: str = "") -> str:
    prompt = f"""You are executing a single task from a plan.

## Your Task

**Task:** {task.text}
**Completion Criterion:** {task.criterion}
**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## Plan Context

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ONLY this single task. Do not work on other tasks.
- When the task is complete and the completion criterion is met, edit the plan file to check off this task: change `- [ ]` to `- [x]` for this task's line.
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did.
- After completing (or failing) the task, append a single line to `{config.learnings_path}`. Use this format:
  `[done YYYY-MM-DD HH:MM] Task description. ⚠️ Learning: <only if there's a genuine gotcha, else omit>`
  Only record a learning if you discovered something surprising — a workaround, an environment quirk, a non-obvious dependency, or a dead end worth avoiding. Do not record routine work."""

    return _append_prompt_context(prompt, learnings_content, project_context,
                                  user_guidance)


def build_batch_prompt(tasks: list[Task], plan_content: str, config: Config,
                       coding_rules: str, recent_commits: str,
                       user_guidance: str,
                       project_context: str = "",
                       learnings_content: str = "") -> str:
    task_list = "\n".join(f"- {t.text}" for t in tasks)

    prompt = f"""You are executing a batch of related tasks from a plan.

## Your Tasks

{task_list}

**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## Plan Context

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ALL of the tasks listed above. They are related and should be done together.
- Work through them in order, but use your judgment — if implementing one naturally completes another, that's fine.
- When each task is complete, edit the plan file to check it off: change `- [ ]` to `- [x]` for that task's line.
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did for each task.
- After completing the batch, append a single line per task to `{config.learnings_path}`. Use this format:
  `[done YYYY-MM-DD HH:MM] Task description. ⚠️ Learning: <only if there's a genuine gotcha, else omit>`
  Only record a learning if you discovered something surprising. Do not record routine work."""

    return _append_prompt_context(prompt, learnings_content, project_context,
                                  user_guidance)


def build_rescue_prompt(task: Task, plan_content: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        elapsed_mins: int,
                        learnings_content: str = "",
                        project_context: str = "") -> str:
    """Build a prompt for a fresh agent to rescue a stuck task."""
    prompt = f"""You are rescuing a stuck task. A previous agent was working on this task for over {elapsed_mins} minutes and appeared to be stuck or in a loop. It was terminated, but its code changes are still in the working tree — nothing was stashed or reverted.

## Your Task

**Task:** {task.text}
**Completion Criterion:** {task.criterion}
**Plan file:** {config.plan_path}
**Working directory:** {config.work_dir}

## What Happened

The previous agent ran for {elapsed_mins} minutes without completing this task. Its partial changes are in the working tree right now. Common causes:
- Stuck in a test-fix loop (tests fail, agent tries to fix, tests fail again)
- Over-engineering or going down the wrong path
- Waiting on something that won't resolve

## What You Should Do

1. Run `git diff` and `git status` to see what the previous agent changed
2. Assess whether the changes are on the right track or need a different approach
3. If the changes are close, finish them up. If they're wrong, revert and start fresh.
4. Complete the task and check it off in the plan file: change `- [ ]` to `- [x]`
5. Keep it simple — the previous agent likely overcomplicated things

## Plan Context

<plan>
{plan_content}
</plan>

## Recent Commits

{recent_commits}

## Coding Agent Rules

{coding_rules or "No coding agent rules file found — use your best judgment."}"""

    return _append_prompt_context(prompt, learnings_content, project_context)
