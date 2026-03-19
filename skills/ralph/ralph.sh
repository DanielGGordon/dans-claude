#!/usr/bin/env bash
set -euo pipefail

# ralph.sh — Execute a plan file task-by-task using claude -p
#
# Usage: ralph.sh [plan_path] [--dry-run] [--max-turns N] [--batch]
#
# Each task gets a fresh claude invocation with zero context carryover.
# The plan file on disk is the only shared state.

# ─── Configuration ───────────────────────────────────────────────────────────

CODING_AGENTS_FILE="$HOME/.claude/CODING_AGENTS.md"
RALPH_ASCII="$HOME/.claude/skills/ralph/ralph-ascii.txt"
MAX_TURNS="${RALPH_MAX_TURNS:-50}"
DELAY="${RALPH_DELAY:-3}"       # seconds between tasks (for user to ctrl+c)
DRY_RUN=false
BATCH_MODE=false
PLAN_PATH=""

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --max-turns) MAX_TURNS="$2"; shift 2 ;;
        --delay)    DELAY="$2"; shift 2 ;;
        --batch)    BATCH_MODE=true; shift ;;
        --help|-h)
            echo "Usage: ralph.sh [plan_path] [--dry-run] [--max-turns N] [--delay N] [--batch]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would be executed without running claude"
            echo "  --max-turns   Max agentic turns per task (default: 50, env: RALPH_MAX_TURNS)"
            echo "  --delay       Seconds to wait between tasks for ctrl+c (default: 3, env: RALPH_DELAY)"
            echo "  --batch       Process <!-- BATCH --> groups as single invocations"
            echo ""
            echo "Environment variables:"
            echo "  RALPH_MAX_TURNS  Same as --max-turns"
            echo "  RALPH_DELAY      Same as --delay"
            exit 0
            ;;
        *)
            if [[ -z "$PLAN_PATH" ]]; then
                PLAN_PATH="$1"
            else
                echo "Error: unexpected argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# ─── Find plan file ──────────────────────────────────────────────────────────

find_plan() {
    if [[ -n "$PLAN_PATH" ]]; then
        if [[ -f "$PLAN_PATH" ]]; then
            echo "$PLAN_PATH"
            return
        fi
        echo "Error: plan file not found: $PLAN_PATH" >&2
        exit 1
    fi

    # Search order: ./plan.md, ./PLAN.md, ~/.claude/plans/*.md
    for candidate in "plan.md" "PLAN.md"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done

    local plans_dir="$HOME/.claude/plans"
    if [[ -d "$plans_dir" ]]; then
        local -a plans
        mapfile -t plans < <(find "$plans_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null)
        if [[ ${#plans[@]} -eq 1 ]]; then
            echo "${plans[0]}"
            return
        elif [[ ${#plans[@]} -gt 1 ]]; then
            echo "Multiple plans found in $plans_dir:" >&2
            printf '  %s\n' "${plans[@]}" >&2
            echo "Specify one: ralph.sh <path>" >&2
            exit 1
        fi
    fi

    echo "Error: no plan file found" >&2
    exit 1
}

PLAN_PATH="$(find_plan)"
PLAN_PATH="$(realpath "$PLAN_PATH")"
WORK_DIR="$(pwd)"

echo ""
[[ -f "$RALPH_ASCII" ]] && cat "$RALPH_ASCII"
echo "Plan: $PLAN_PATH"
echo "Working directory: $WORK_DIR"
echo ""

# ─── Pre-load context ────────────────────────────────────────────────────────

CODING_RULES=""
if [[ -f "$CODING_AGENTS_FILE" ]]; then
    CODING_RULES="$(cat "$CODING_AGENTS_FILE")"
fi

PLAN_CONTENT="$(cat "$PLAN_PATH")"

# ─── Task parsing ────────────────────────────────────────────────────────────

# Find the next unchecked task line number and text
# Returns: "LINE_NUM|TASK_TEXT" or empty if none
find_next_task() {
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ "$line" =~ ^[[:space:]]*-\ \[\ \]\ (.+)$ ]]; then
            echo "${line_num}|${BASH_REMATCH[1]}"
            return
        fi
    done < "$PLAN_PATH"
}

# Check if the line before a task has <!-- BATCH -->
is_batch_start() {
    local task_line_num="$1"
    local prev_line_num=$((task_line_num - 1))
    if [[ $prev_line_num -lt 1 ]]; then
        return 1
    fi
    local prev_line
    prev_line="$(sed -n "${prev_line_num}p" "$PLAN_PATH")"
    [[ "$prev_line" =~ '<!-- BATCH -->' ]]
}

# Collect consecutive unchecked tasks starting from a line number
collect_batch() {
    local start_line="$1"
    local line_num=0
    local collecting=false
    local tasks=()
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ $line_num -lt $start_line ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*-\ \[\ \]\ (.+)$ ]]; then
            collecting=true
            tasks+=("${line_num}|${BASH_REMATCH[1]}")
        elif $collecting; then
            # Stop at first non-task line
            break
        fi
    done < "$PLAN_PATH"
    printf '%s\n' "${tasks[@]}"
}

# Extract criterion from task text (after " — _Criterion:" or similar patterns)
extract_criterion() {
    local task_text="$1"
    if [[ "$task_text" =~ _Criterion:\ (.+)_$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$task_text" =~ —\ (.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "Task is complete and working correctly"
    fi
}

# ─── Build prompt ────────────────────────────────────────────────────────────

build_single_prompt() {
    local task_text="$1"
    local criterion
    criterion="$(extract_criterion "$task_text")"
    local recent_commits
    recent_commits="$(git log --oneline -3 2>/dev/null || echo 'No git history available.')"

    cat <<PROMPT
You are executing a single task from a plan.

## Your Task

**Task:** ${task_text}
**Completion Criterion:** ${criterion}
**Plan file:** ${PLAN_PATH}
**Working directory:** ${WORK_DIR}

## Plan Context

The full plan is provided below so you do not need to read the plan file. Use this for architecture, project structure, and dependency context:

<plan>
${PLAN_CONTENT}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

${recent_commits}

## Coding Agent Rules

${CODING_RULES:-No coding agent rules file found — use your best judgment.}

## Instructions

- Execute ONLY this single task. Do not work on other tasks.
- When the task is complete and the completion criterion is met, edit the plan file to check off this task: change \`- [ ]\` to \`- [x]\` for this task's line.
- When done, respond with a brief summary of what you did.
PROMPT
}

build_batch_prompt() {
    local -a task_entries=("$@")
    local task_list=""
    for entry in "${task_entries[@]}"; do
        local text="${entry#*|}"
        task_list+="- ${text}"$'\n'
    done
    local recent_commits
    recent_commits="$(git log --oneline -3 2>/dev/null || echo 'No git history available.')"

    cat <<PROMPT
You are executing a batch of related tasks from a plan.

## Your Tasks

${task_list}

**Plan file:** ${PLAN_PATH}
**Working directory:** ${WORK_DIR}

## Plan Context

The full plan is provided below so you do not need to read the plan file. Use this for architecture, project structure, and dependency context:

<plan>
${PLAN_CONTENT}
</plan>

## Recent Commits

These are the last 3 commits in the repo — read them to understand what work has been done recently:

${recent_commits}

## Coding Agent Rules

${CODING_RULES:-No coding agent rules file found — use your best judgment.}

## Instructions

- Execute ALL of the tasks listed above. They are related and should be done together.
- Work through them in order, but use your judgment — if implementing one naturally completes another, that's fine.
- When each task is complete, edit the plan file to check it off: change \`- [ ]\` to \`- [x]\` for that task's line.
- When done, respond with a brief summary of what you did for each task.
PROMPT
}

# ─── Execute ─────────────────────────────────────────────────────────────────

run_claude() {
    local prompt="$1"
    claude -p \
        --max-turns "$MAX_TURNS" \
        --dangerously-skip-permissions \
        --output-format text \
        <<< "$prompt"
}

completed=0
failed=0

# Trap ctrl+c for clean exit
trap 'echo ""; echo "🛑 Stopped by user after ${completed} tasks completed, ${failed} failed."; exit 0' INT

while true; do
    local_result="$(find_next_task)"
    if [[ -z "$local_result" ]]; then
        echo "✅ All tasks complete! (${completed} completed, ${failed} failed)"
        break
    fi

    task_line="${local_result%%|*}"
    task_text="${local_result#*|}"

    # Check for batch
    if $BATCH_MODE && is_batch_start "$task_line"; then
        mapfile -t batch_tasks < <(collect_batch "$task_line")
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📦 BATCH (${#batch_tasks[@]} tasks):"
        for entry in "${batch_tasks[@]}"; do
            echo "   - ${entry#*|}"
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if $DRY_RUN; then
            echo "[dry-run] Would execute batch of ${#batch_tasks[@]} tasks"
            # Mark them done for dry-run progression
            for entry in "${batch_tasks[@]}"; do
                local ln="${entry%%|*}"
                sed -i "${ln}s/- \[ \]/- [x]/" "$PLAN_PATH"
            done
            completed=$((completed + ${#batch_tasks[@]}))
            continue
        fi

        # Countdown
        if [[ "$DELAY" -gt 0 ]]; then
            echo "   Starting in ${DELAY}s... (ctrl+c to stop)"
            sleep "$DELAY"
        fi

        prompt="$(build_batch_prompt "${batch_tasks[@]}")"
        echo ""
        if run_claude "$prompt"; then
            completed=$((completed + ${#batch_tasks[@]}))
            echo ""
            echo "✅ Batch complete"
        else
            failed=$((failed + ${#batch_tasks[@]}))
            echo ""
            echo "❌ Batch failed (exit code: $?)"
        fi
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 Task: ${task_text}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if $DRY_RUN; then
            echo "[dry-run] Would execute this task"
            sed -i "${task_line}s/- \[ \]/- [x]/" "$PLAN_PATH"
            completed=$((completed + 1))
            continue
        fi

        # Countdown
        if [[ "$DELAY" -gt 0 ]]; then
            echo "   Starting in ${DELAY}s... (ctrl+c to stop)"
            sleep "$DELAY"
        fi

        prompt="$(build_single_prompt "$task_text")"
        echo ""
        if run_claude "$prompt"; then
            completed=$((completed + 1))
            echo ""
            echo "✅ Task complete"
        else
            failed=$((failed + 1))
            echo ""
            echo "❌ Task failed (exit code: $?)"
        fi
    fi

    # Refresh plan content every 3 tasks for the prompt context
    if (( (completed + failed) % 3 == 0 )); then
        PLAN_CONTENT="$(cat "$PLAN_PATH")"
    fi

    echo ""
done
