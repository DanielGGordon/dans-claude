---
name: ralph
description: Execute a plan file task-by-task in isolated subagents, resetting context between each task. Adds checkboxes to tasks if missing, checks them off as they complete.
user_invocable: true
arguments:
  - name: plan_path
    description: Path to the plan file (defaults to plan.md in the current working directory, then checks ~/.claude/plans/)
    required: false
---

You are the Ralph loop orchestrator. Your job is to execute a plan file **one task at a time**, dispatching each task to a fresh subagent so context doesn't accumulate.

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

Before entering the task loop, read the following files **once** and hold their contents in memory:

1. **The plan file** — read the full contents. This gives you the architecture, project structure, dependencies, and all task context that subagents will need.
2. **CODING_AGENTS.md** — read `~/.claude/CODING_AGENTS.md` (coding agent rules). If the file doesn't exist, skip it and continue.
3. **Recent git history** — run `git log --oneline -3` and store the output. This gives subagents context on what has been done recently.

Store all as variables (e.g., `plan_content`, `coding_agent_rules`, and `recent_commits`) to inject into subagent prompts. This avoids every subagent redundantly re-reading the same files.

## Step 4: Print Ralph and begin the loop

Before executing the first task, print Ralph to the console using the Bash tool:

```bash
cat ~/.claude/skills/ralph/ralph-ascii.txt
```

## Step 5: Execute tasks

Find the first unchecked task (`- [ ]`). Before launching, check whether it is part of a **batch**.

### Batch detection

A `<!-- BATCH -->` comment on the line immediately before a group of consecutive unchecked tasks means those tasks should all go to **one** subagent. Collect every consecutive `- [ ]` task following the `<!-- BATCH -->` marker (stop at the first non-task line, checked task, or another marker). These tasks form a single unit of work for one subagent.

If there is no `<!-- BATCH -->` marker before the current task, treat it as a single task (the default).

### For each task (or batch):

1. **Show the user** what you're about to execute. For a batch, list all tasks in the group.
2. **Give a 3-second countdown with auto-proceed.** Do NOT use AskUserQuestion (it blocks forever). Instead, use the Bash tool to run a countdown timer that auto-proceeds:

   ```bash
   echo "⏳ Starting **{task number(s)}**: {short description}"; echo "   Type 'skip' or 'stop', or press Enter to go now."; input=""; for i in $(seq 3 -1 1); do printf "\r   %2ds remaining... " "$i"; if read -t 1 -r input 2>/dev/null; then break; fi; done; printf "\r                       \r"; echo "${input:-auto}"
   ```

   Parse the output:
   - If output is "auto" or empty → **auto-proceed** (launch the subagent).
   - If output is "skip" → skip to the next task/batch.
   - If output is "stop" → end the loop.
   - Any other text → treat as guidance and pass it to the subagent as additional context.
3. **Launch a subagent** using the Agent tool with this prompt:

For a **single task**:
```
You are executing a single task from a plan.

## Your Task

**Task:** {task description}
**Completion Criterion:** {criterion}
**Plan file:** {plan_path}
**Working directory:** {cwd}

## Plan Context

The full plan is provided below so you do not need to read the plan file. Use this for architecture, project structure, and dependency context:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits OR "No git history available."}

## Coding Agent Rules

{coding_agent_rules OR "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ONLY this single task. Do not work on other tasks.
- When the task is complete and the completion criterion is met, edit the plan file to check off this task: change `- [ ]` to `- [x]` for this task's line.
- If you need clarification from the user, ask — do not guess.
- When done, respond with a brief summary of what you did.
```

For a **batch of tasks**:
```
You are executing a batch of related tasks from a plan.

## Your Tasks

{numbered list of all tasks in the batch, each with its description}

**Plan file:** {plan_path}
**Working directory:** {cwd}

## Plan Context

The full plan is provided below so you do not need to read the plan file. Use this for architecture, project structure, and dependency context:

<plan>
{plan_content}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

{recent_commits OR "No git history available."}

## Coding Agent Rules

{coding_agent_rules OR "No coding agent rules file found — use your best judgment."}

## Instructions

- Execute ALL of the tasks listed above. They are related and should be done together.
- Work through them in order, but use your judgment — if implementing one naturally completes another, that's fine.
- When each task is complete, edit the plan file to check it off: change `- [ ]` to `- [x]` for that task's line.
- If you need clarification from the user, ask — do not guess.
- When done, respond with a brief summary of what you did for each task.
```

4. After the subagent completes, **re-read the plan file from disk** to pick up the checked-off tasks, then find the next unchecked task (`- [ ]`).
5. **Compact every 3 tasks.** Keep a counter of completed tasks in the current session. After every 3rd task completes, run `/compact` to free up context before continuing. Also re-read the recent git history (`git log --oneline -3`) to refresh `recent_commits` for the next subagent.
6. Repeat until all tasks are checked or the user stops the loop.

## Important rules

- **Auto-proceed by default.** Do NOT block waiting for user confirmation. Show the task, give a 3-second window, then go. The user can always type during the window or interrupt with Ctrl+C.
- **One task at a time by default.** Never run multiple tasks in a single subagent unless they are grouped by a `<!-- BATCH -->` marker in the plan.
- **Respect parallel markers.** If the plan marks tasks as parallelizable (e.g., "PARALLEL", "Yes" in a parallel column), you MAY launch multiple subagents concurrently for those tasks. Show what you're about to launch and give the 15-second window before starting the batch.
- **Respect sequential markers.** If tasks are marked sequential or have dependencies, run them one at a time in order.
- **Don't accumulate context.** Each subagent is independent. The plan file on disk is the shared state for *completion tracking only*. Never pass conversation history or prior subagent results into a new subagent — only the task description, pre-loaded plan context, and coding agent rules.
- **Re-read plan for task status only.** Between tasks, re-read the plan file only to find the next unchecked `- [ ]` task. Do not re-read for context — you already have that from Step 3.
