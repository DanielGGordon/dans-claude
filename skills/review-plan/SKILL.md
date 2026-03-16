---
name: review-plan
description: Review the active plan file against requirements, then automatically fix any issues found. Runs up to 2 revision rounds.
user_invocable: true
---

You are the plan review-and-fix skill. Your job is to find the active plan, review it using the `plan-reviewer` agent, and automatically revise the plan until it passes — capped at 2 revision rounds.

## Step 1: Find the active plan file

Search for the plan file in this order:

1. **`~/.claude/plans/*.md`** — pick the most recently modified `.md` file in this directory.
2. **`plan.md`** in the current working directory.
3. **`PLAN.md`** in the current working directory.

Use the Bash tool to find the newest file:

```bash
ls -t ~/.claude/plans/*.md 2>/dev/null | head -1
```

If that returns nothing, check for `plan.md` then `PLAN.md` in the CWD.

If no plan file is found anywhere, tell the user and stop.

Store the resolved path as `PLAN_PATH` for all subsequent steps.

## Step 2: Run the plan-reviewer agent

Launch the `plan-reviewer` named agent, passing it the plan file path:

> Review the plan at `{PLAN_PATH}`

The agent will return a JSON object:
- `{"ok": true}` — the plan passes all requirements.
- `{"ok": false, "reason": "..."}` — the plan has issues that need fixing.

## Step 3: Handle the result

### If `{"ok": true}`

Report to the user:

> Plan review passed. No issues found in `{PLAN_PATH}`.

Stop. You are done.

### If `{"ok": false, "reason": "..."}`

Move to Step 4.

## Step 4: Revise the plan (revision round 1)

1. Read the plan file at `PLAN_PATH`.
2. Carefully parse every issue listed in the `reason` field.
3. Edit the plan file to address **every** issue. Be substantive — add real content, not placeholder text. For example:
   - If the reviewer says a testing strategy is missing, add a concrete testing section with framework names and test types.
   - If parallelism markers are missing, annotate each task with `[PARALLEL: yes/no]`.
   - If completion criteria are missing, add a `_Criterion: ..._` line to each task.
4. Write the updated plan back to disk.

## Step 5: Re-run the plan-reviewer agent

Launch the `plan-reviewer` agent again with the same plan path to confirm the fixes landed.

- If `{"ok": true}` — report success and stop:
  > Plan revised and now passes review. Fixed issues in `{PLAN_PATH}`.

- If `{"ok": false, "reason": "..."}` — move to Step 6.

## Step 6: Revise the plan (revision round 2 — final)

Repeat the same process as Step 4: read the plan, fix every remaining issue, write it back.

Then run the `plan-reviewer` agent one final time.

- If `{"ok": true}` — report success:
  > Plan revised and now passes review after 2 rounds. Fixed issues in `{PLAN_PATH}`.

- If still `{"ok": false}` — report the remaining issues to the user and stop. Do not attempt further revisions:
  > Plan still has issues after 2 revision rounds. Remaining feedback:
  > {reason}
  >
  > Please review and address these manually in `{PLAN_PATH}`.

## Rules

- **Cap at 2 revision rounds.** Never loop more than twice to avoid infinite cycles.
- **Be substantive in edits.** Do not add vague filler. Every edit should directly resolve the reviewer's feedback with concrete content.
- **Preserve existing plan content.** Only add or modify what's needed to fix the issues. Do not rewrite sections that already pass.
- **Always use the `plan-reviewer` agent** for validation — do not try to evaluate requirements yourself.
