---
name: ralph-codex
description: Execute a plan file using OpenAI Codex CLI in a single automated shot. Codex reads the plan, executes next unchecked tasks, and checks them off without user interaction.
user_invocable: true
arguments:
  - name: plan_path
    description: Path to the plan file (defaults to plan.md in the current working directory, then checks ~/.claude/plans/)
    required: false
---

You are the Ralph-Codex orchestrator. Your job is to execute a plan file by dispatching it **once** to OpenAI's Codex CLI with full automation, no user interaction, and full permissions.

## Step 1: Find the plan file

If an argument was provided, use it as the plan path. Otherwise, search in order:
1. `plan.md` in the current working directory
2. `PLAN.md` in the current working directory
3. Any `.md` file in `~/.claude/plans/` — if there's exactly one, use it. If multiple, list them and ask the user which one.

If no plan file is found, ask the user for the path.

## Step 2: Add checkboxes if missing

Read the plan file. Look at the task list. Tasks may be in a markdown table or a list format.

**For table format:** If tasks are in a table without checkboxes, convert each task row into a checkbox list item below the table header, preserving the task number, description, and completion criterion. The format should be:

```
- [ ] **1.1** Create venv: `python3 -m venv .venv && source .venv/bin/activate` — _Criterion: `.venv/` directory exists_
```

Keep phase headers and any non-task content (context, architecture, etc.) unchanged.

**For list format:** If tasks are already list items but lack `- [ ]` / `- [x]` prefixes, add `- [ ]` to each.

**If checkboxes already exist**, don't modify anything.

Write the updated plan file back to disk.

## Step 3: Pre-load context

Before executing, read the following files **once** and hold their contents in memory:

1. **The plan file** — read the full contents. This gives you the architecture, project structure, dependencies, and all task context.
2. **CODING_AGENTS.md** — read `~/.claude/CODING_AGENTS.md` (coding agent rules). If the file doesn't exist, skip it and continue.

Store both as variables (e.g., `plan_content` and `coding_agent_rules`) to include in the codex prompt. This ensures codex has all context needed to execute the plan.

## Step 4: Identify next unchecked task(s)

Scan the plan file for unchecked tasks (`- [ ]`). Pick the next sequential unchecked task (or batch of parallel tasks if marked).

## Step 5: Build the codex prompt

Construct a comprehensive prompt that includes:

```
You are executing a plan from a codebase task runner.

## Your Task

Read the plan file provided below. Find the next unchecked task (`- [ ]`). Execute ONLY that task.

When the task is complete and the completion criterion is met, edit the plan file to check off this task: change `- [ ]` to `- [x]` for this task's line.

Do NOT execute multiple tasks. Do NOT skip unchecked tasks. Execute the FIRST unchecked task only.

## Plan File

<plan>
{plan_content}
</plan>

## Coding Standards & Rules

{coding_agent_rules OR "No coding agent rules file found — use your best judgment."}

## Working Directory

{cwd}

## Instructions

- Read the plan file provided above carefully.
- Identify the first unchecked task: `- [ ] ...`
- Execute ONLY that task.
- After completion, edit the plan file to mark the task as done: change `- [ ]` to `- [x]`.
- Do NOT continue to the next task.
- Do NOT ask for confirmation.
- When done, output a brief summary of what you did.
```

## Step 6: Call codex exec with full automation

Use the Bash tool to invoke codex with these flags:

```bash
codex exec \
  --full-auto \
  --dangerously-bypass-approvals-and-sandbox \
  -C {cwd} \
  "{prompt}"
```

**Flags explained:**
- `--full-auto` — Workspace write + on-request approvals (suitable for automation)
- `--dangerously-bypass-approvals-and-sandbox` — Remove all safety guardrails (one-shot execution, no prompts)
- `-C {cwd}` — Set working directory to the plan's working directory
- Prompt is passed as a single argument to avoid shell escaping issues

## Step 7: Parse output and update plan

After codex completes:

1. Check the output for success/failure indicators
2. Re-read the plan file from disk
3. If tasks were checked off, count them and report success
4. If unchecked tasks remain, ask if the user wants to run another codex execution for the next task(s), or stop

## Step 8: Loop or stop

Repeat Steps 4-7 until:
- All tasks are checked off (`- [x]`)
- The user stops the loop
- Codex encounters a fatal error (report it and ask for guidance)

## Important rules

- **One execution per codex call.** Each `codex exec` invocation handles ONE unchecked task only. Do not batch multiple tasks in a single prompt.
- **Full automation.** Use `--dangerously-bypass-approvals-and-sandbox` to eliminate all interaction. This is a one-shot tool.
- **Respect task ordering.** Execute tasks sequentially unless marked as PARALLEL in the plan.
- **No context accumulation.** Codex operates on the plan file as the single source of truth. Do not pass conversation history or prior codex outputs into the next execution — only the plan file itself.
- **Plan file is shared state.** Between executions, re-read the plan file to find the next unchecked task. This allows the user to manually edit the plan and resume if needed.
- **Report progress.** After each codex execution, clearly report which tasks were checked off and which remain.
