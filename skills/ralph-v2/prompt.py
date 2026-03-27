"""Prompt building for Ralph v2 -- generator, evaluator, retry, and rescue."""

import subprocess
from pathlib import Path

from models import Config, Phase, CODING_AGENTS_FILE


# ─── Playwright CLI directions (always included in evaluator prompts) ────────

PLAYWRIGHT_DIRECTIONS = """## Playwright CLI Directions

Use Playwright to test web applications. These directions are always available -- use them when testing web UIs.

### Setup
```bash
# Install if needed
npx playwright install chromium
```

### Programmatic testing
```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto("http://localhost:3000")

    # Navigate and interact
    page.click("text=Submit")
    page.fill("input[name=email]", "test@example.com")

    # Assert
    assert page.title() == "Expected Title"
    assert page.locator(".success-message").is_visible()

    # Screenshot for evidence
    page.screenshot(path="evidence.png")

    # Check console errors
    errors = []
    page.on("console", lambda msg: errors.append(msg.text) if msg.type == "error" else None)
    page.reload()
    assert len(errors) == 0, f"Console errors: {errors}"

    # Check network requests
    with page.expect_response("**/api/**") as response_info:
        page.click("button#submit")
    response = response_info.value
    assert response.status == 200

    browser.close()
```

### Common patterns
- **Check page loads**: `page.goto(url)` then `assert page.locator("body").is_visible()`
- **Fill forms**: `page.fill("selector", "value")` then `page.click("button[type=submit]")`
- **Wait for navigation**: `page.wait_for_url("**/dashboard")`
- **Check text content**: `assert "expected" in page.locator(".element").text_content()`
- **Console errors**: Listen for console events and assert no errors
- **Screenshots**: `page.screenshot(path="screenshot.png")` for evidence
"""


# ─── Context loading ────────────────────────────────────────────────────────

def get_recent_commits() -> str:
    try:
        result = subprocess.run(
            ["git", "log", "--oneline", "-5"],
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
    parts: list[str] = []
    for filename in ("README.md", "PROJECT_STRUCTURE.md"):
        filepath = Path(work_dir) / filename
        if filepath.is_file():
            contents = filepath.read_text().strip()
            if contents:
                parts.append(f"This is the {filename}:\n\n{contents}")
    return "\n\n".join(parts)


def get_restart_context(work_dir: str) -> str:
    """Gather git state for --restart mode: status, diff summary, and stash list."""
    parts: list[str] = []
    try:
        status = subprocess.run(
            ["git", "status", "--short"],
            capture_output=True, text=True, timeout=10, cwd=work_dir,
        )
        if status.stdout.strip():
            parts.append(f"### git status --short\n```\n{status.stdout.strip()}\n```")
        else:
            parts.append("### git status\nWorking tree is clean.")
    except Exception:
        parts.append("### git status\nFailed to run git status.")

    try:
        diff_stat = subprocess.run(
            ["git", "diff", "--stat", "HEAD"],
            capture_output=True, text=True, timeout=10, cwd=work_dir,
        )
        if diff_stat.stdout.strip():
            parts.append(f"### git diff --stat HEAD\n```\n{diff_stat.stdout.strip()}\n```")
    except Exception:
        pass

    try:
        stash = subprocess.run(
            ["git", "stash", "list"],
            capture_output=True, text=True, timeout=5, cwd=work_dir,
        )
        if stash.stdout.strip():
            parts.append(f"### git stash list\n```\n{stash.stdout.strip()}\n```")
    except Exception:
        pass

    return "\n\n".join(parts)


# ─── Shared context appender ────────────────────────────────────────────────

def _append_context(prompt: str, learnings: str = "",
                    project_context: str = "",
                    user_guidance: str = "",
                    proposed_changes: str = "",
                    restart_context: str = "") -> str:
    if restart_context:
        prompt += f"""

## RESTART — READ CAREFULLY

This is a **restart** — a previous run was interrupted mid-phase. There are uncommitted changes in the working directory from the interrupted run. Before starting:

1. Run `git status` and `git diff --stat` to understand what was already changed
2. Check if work related to your current phase was already partially or fully done
3. If work was partially done, continue from where it left off — do NOT redo or revert existing changes
4. If the uncommitted changes are unrelated to your phase, leave them alone and proceed normally

Here is the git state at restart time:

{restart_context}"""

    if learnings:
        prompt += f"""

## Learnings from Prior Phases

Previous phases recorded these notes. Read them to avoid repeating mistakes:

{learnings}"""

    if proposed_changes:
        prompt += f"""

## Proposed Changes from Prior Phases

Earlier generators proposed these changes to future phases. Consider them:

{proposed_changes}"""

    if project_context:
        prompt += f"""

## Project Context

{project_context}"""

    if user_guidance:
        prompt += f"""

## User Guidance

The user has provided the following context. Read carefully and follow:

{user_guidance}"""

    return prompt


# ─── Generator prompt ───────────────────────────────────────────────────────

def build_generator_prompt(phase: Phase, plan_header: str, config: Config,
                           coding_rules: str, recent_commits: str,
                           user_guidance: str = "",
                           project_context: str = "",
                           learnings: str = "",
                           proposed_changes: str = "",
                           restart_context: str = "") -> str:
    criteria_list = "\n".join(f"- {c}" for c in phase.acceptance_criteria)

    v1_context = ""
    if phase.v1_tasks:
        task_list = "\n".join(f"- {t}" for t in phase.v1_tasks)
        v1_context = f"""

## Legacy Task List

This phase was written with checkbox tasks (v1 format). Implement all of them as part of this phase:

{task_list}
"""

    plan_stem = Path(config.plan_path).stem if config.plan_path else "plan"
    proposed_changes_file = f"{plan_stem}-proposed-changes.md"

    prompt = f"""You are the generator agent for Phase {phase.number}: {phase.title}.

Your job is to implement this entire phase autonomously in a single session.

## Phase Description

**Delivers**: {phase.delivers}

**Acceptance criteria** (the evaluator will test each of these):
{criteria_list}
{v1_context}
## Plan Header

{plan_header}

## Working Directory

{config.work_dir}

## Plan File

{config.plan_path}

## Recent Commits

{recent_commits}

## Coding Rules

{coding_rules or "No coding agent rules file found -- use your best judgment."}

## Instructions

1. Implement the full phase autonomously. Do NOT ask for permission or clarification -- make decisions and move forward.
2. Commit your work incrementally with meaningful commit messages. Each logical unit of work should be its own commit.
3. The acceptance criteria above are your target. The evaluator will test each one independently after you finish.
4. Do NOT self-evaluate quality -- that is the evaluator's job. Focus on building.
5. If you discover something relevant to future phases (architectural decisions, gotchas, suggested changes), write it to `{proposed_changes_file}`. Format:
   ```
   ## After Phase {phase.number} (proposed by Phase {phase.number} generator)
   - Description of proposed change or learning
   ```
6. As your FINAL output, produce a learnings summary (1-8 sentences) capturing what you learned during this phase. This will be saved for future phases. Format:
   ```
   LEARNINGS:
   <your 1-8 sentence summary>
   ```
   Only include genuine gotchas, surprises, or non-obvious decisions. Do not summarize routine work."""

    return _append_context(prompt, learnings, project_context, user_guidance,
                           proposed_changes, restart_context=restart_context)


# ─── Evaluator prompt ───────────────────────────────────────────────────────

def build_evaluator_prompt(phase: Phase, config: Config) -> str:
    criteria_list = "\n".join(
        f"{i+1}. {c}" for i, c in enumerate(phase.acceptance_criteria)
    )

    prompt = f"""You are the evaluator agent for Phase {phase.number}: {phase.title}.

Your job is to test what was built against the acceptance criteria. Be adversarial -- look for things that are broken, not things that work.

## Acceptance Criteria to Test

{criteria_list}

## Working Directory

{config.work_dir}

## Instructions

Test each acceptance criterion independently. For each one:

1. Figure out how to verify it (run tests, check files, use Playwright for web UIs, exercise CLI tools, etc.)
2. Actually run the verification -- do not just read code and guess
3. Record your findings

Use the tools available to you:
- Run test suites if they exist (`pytest`, `npm test`, etc.)
- Exercise CLI tools by running them with representative inputs
- Use Playwright to navigate and interact with web UIs (directions below)
- Check that files, routes, schemas, etc. exist as expected
- Look for edge cases and error handling

## Output Format

You MUST produce output in this exact format:

```
## Phase {phase.number} Evaluation

**Overall**: PASS / FAIL (X of Y criteria met)

### Criterion 1: [description]
**Result**: PASS
**Evidence**: [what was tested, what was observed]

### Criterion 2: [description]
**Result**: FAIL
**Issue**: [specific problem found]
**Suggestion**: [actionable fix direction]

### General observations
- [anything notable not covered by criteria]
```

Replace PASS/FAIL based on your actual findings. Every criterion must have a Result line.

{PLAYWRIGHT_DIRECTIONS}"""

    return prompt


# ─── Generator retry prompt ─────────────────────────────────────────────────

def build_generator_retry_prompt(phase: Phase, plan_header: str, config: Config,
                                 coding_rules: str, recent_commits: str,
                                 eval_feedback: str,
                                 eval_round: int,
                                 user_guidance: str = "",
                                 project_context: str = "",
                                 learnings: str = "",
                                 proposed_changes: str = "") -> str:
    criteria_list = "\n".join(f"- {c}" for c in phase.acceptance_criteria)

    prompt = f"""You are the generator agent for Phase {phase.number}: {phase.title} (retry attempt {eval_round}).

The evaluator found issues with the previous implementation. Fix them without regressing on criteria that already passed.

## Evaluator Feedback

{eval_feedback}

## Phase Description

**Delivers**: {phase.delivers}

**Acceptance criteria**:
{criteria_list}

## Plan Header

{plan_header}

## Working Directory

{config.work_dir}

## Plan File

{config.plan_path}

## Recent Commits

{recent_commits}

## Coding Rules

{coding_rules or "No coding agent rules file found -- use your best judgment."}

## Instructions

1. Focus specifically on the FAILED criteria from the evaluator feedback above.
2. Do NOT regress on criteria that already PASSED.
3. Commit your fixes with meaningful messages explaining what changed and why.
4. Do NOT self-evaluate -- the evaluator will test again after you finish.
5. As your FINAL output, produce a learnings summary (1-8 sentences):
   ```
   LEARNINGS:
   <your 1-8 sentence summary>
   ```"""

    return _append_context(prompt, learnings, project_context, user_guidance,
                           proposed_changes)


# ─── Rescue prompt ──────────────────────────────────────────────────────────

def build_rescue_prompt(phase: Phase, plan_header: str, config: Config,
                        coding_rules: str, recent_commits: str,
                        elapsed_mins: int,
                        learnings: str = "",
                        project_context: str = "") -> str:
    criteria_list = "\n".join(f"- {c}" for c in phase.acceptance_criteria)

    prompt = f"""You are rescuing a stuck phase. A previous generator was working on Phase {phase.number}: {phase.title} for over {elapsed_mins} minutes and appeared stuck. It was terminated, but its code changes are still in the working tree.

## Phase Description

**Delivers**: {phase.delivers}

**Acceptance criteria**:
{criteria_list}

## What Happened

The previous agent ran for {elapsed_mins} minutes without completing. Its partial changes are in the working tree. Common causes:
- Stuck in a test-fix loop
- Over-engineering or going down the wrong path
- Waiting on something that will not resolve

## What You Should Do

1. Run `git diff` and `git status` to see what the previous agent changed
2. Assess whether the changes are on the right track or need a different approach
3. If close, finish them up. If wrong, revert and start fresh.
4. Keep it simple -- the previous agent likely overcomplicated things
5. Commit your work with meaningful messages

## Plan Header

{plan_header}

## Working Directory

{config.work_dir}

## Recent Commits

{recent_commits}

## Coding Rules

{coding_rules or "No coding agent rules file found -- use your best judgment."}"""

    return _append_context(prompt, learnings, project_context)


# ─── Learnings extraction ───────────────────────────────────────────────────

def extract_learnings(generator_output: str) -> str:
    """Extract the LEARNINGS: section from generator output."""
    lines = generator_output.splitlines()
    collecting = False
    learnings_lines: list[str] = []

    for line in lines:
        if line.strip().upper().startswith("LEARNINGS:"):
            collecting = True
            # Check if there's content on the same line
            rest = line.strip()[len("LEARNINGS:"):].strip()
            if rest:
                learnings_lines.append(rest)
            continue
        if collecting:
            # Stop at the next section marker or triple backtick
            if line.strip().startswith("```") and learnings_lines:
                break
            if line.strip().startswith("##") and learnings_lines:
                break
            learnings_lines.append(line)

    result = "\n".join(learnings_lines).strip()
    # Clean up any leading/trailing backticks
    if result.startswith("```"):
        result = result[3:]
    if result.endswith("```"):
        result = result[:-3]
    return result.strip()
