#!/bin/bash
# Hook: review-plan.sh
# Fires on PreToolUse(ExitPlanMode). Reads the plan file Claude just wrote,
# spins up a fresh claude reviewer with only the plan + requirements in context,
# and blocks exit if any requirements are unmet.

set -e

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

REQUIREMENTS_FILE="$HOME/.claude/plan-requirements.md"

if [ ! -f "$REQUIREMENTS_FILE" ]; then
  echo "[review-plan] No requirements file found at $REQUIREMENTS_FILE, skipping review." >&2
  exit 0
fi

# Find the plan file. Claude writes it to cwd before calling ExitPlanMode.
PLAN_FILE=""
for candidate in "$CWD/plan.md" "$CWD/PLAN.md"; do
  if [ -f "$candidate" ]; then
    PLAN_FILE="$candidate"
    break
  fi
done

if [ -z "$PLAN_FILE" ]; then
  # Fall back to most recently modified .md in cwd (not in .claude/)
  PLAN_FILE=$(find "$CWD" -maxdepth 1 -name "*.md" 2>/dev/null \
    | xargs ls -t 2>/dev/null \
    | head -1)
fi

if [ -z "$PLAN_FILE" ] || [ ! -f "$PLAN_FILE" ]; then
  echo "[review-plan] Could not locate plan file. Skipping review." >&2
  exit 0
fi

# Build the reviewer prompt in a temp file so the heredoc stays clean
PROMPT_FILE=$(mktemp)
trap 'rm -f "$PROMPT_FILE"' EXIT

cat > "$PROMPT_FILE" <<'HEADER'
You are a strict plan reviewer. Your only job is to evaluate whether the plan below satisfies every requirement listed.

Rules for your response:
- If every requirement is fully satisfied, output exactly this on the first line and nothing else:
  APPROVED
- If any requirement is not met (even partially), output exactly this on the first line:
  NEEDS_REVISION
  Then, for each unmet requirement, give a short header and a specific, actionable description of what is missing and how to fix it. Be direct. Do not restate things that are already in the plan.

Do not add commentary, preamble, or closing remarks. First line must be APPROVED or NEEDS_REVISION.

HEADER

printf '\n## REQUIREMENTS\n\n' >> "$PROMPT_FILE"
cat "$REQUIREMENTS_FILE" >> "$PROMPT_FILE"
printf '\n## PLAN TO REVIEW\n\n' >> "$PROMPT_FILE"
cat "$PLAN_FILE" >> "$PROMPT_FILE"

# Run the reviewer in a fresh context (no conversation history)
REVIEW=$(claude -p "$(cat "$PROMPT_FILE")" 2>&1)

FIRST_LINE=$(echo "$REVIEW" | head -1 | tr -d '[:space:]')

if [ "$FIRST_LINE" = "APPROVED" ]; then
  exit 0
else
  echo "" >&2
  echo "============================================================" >&2
  echo " Plan Review: NEEDS REVISION" >&2
  echo "============================================================" >&2
  echo "" >&2
  echo "$REVIEW" >&2
  echo "" >&2
  echo "Please update the plan to address the feedback above, then the plan will be approved." >&2
  exit 2
fi
