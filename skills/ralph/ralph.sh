#!/usr/bin/env bash
set -euo pipefail

# ralph.sh — Execute a plan file task-by-task using claude -p
#
# Usage: ralph.sh [plan_path] [--dry-run] [--max-turns N] [--batch]
#
# Each task gets a fresh claude invocation with zero context carryover.
# The plan file on disk is the only shared state.
#
# Interactive features:
#   Inbox:     echo "guidance" > .ralph-inbox  (from any terminal, any time)
#   Countdown: type during the between-task pause to add guidance
#   Follow-up: ralph detects when an agent asks a question and pauses for you

# ─── Configuration ───────────────────────────────────────────────────────────

CODING_AGENTS_FILE="$HOME/.claude/CODING_AGENTS.md"
RALPH_ASCII="$HOME/.claude/skills/ralph/ralph-ascii.txt"
MAX_TURNS="${RALPH_MAX_TURNS:-50}"
DELAY="${RALPH_DELAY:-5}"       # seconds between tasks (interactive countdown)
DRY_RUN=false
BATCH_MODE=false
SKIP_REVIEW=true                # --review enables codex/claude review after each task
REVIEWER="${RALPH_REVIEWER:-auto}" # auto|codex|claude — which reviewer to use
MODEL="${RALPH_MODEL:-}"        # --model sets claude model + effort (empty = default)
EFFORT=""                       # parsed from model preset
PLAN_PATH=""
INBOX_FILE=".ralph-inbox"       # user drops guidance here from any terminal
LAST_RESULT=""                  # captured from agent's final output
USER_GUIDANCE=""                # accumulated from inbox + countdown + follow-up
START_TIME=""                   # epoch seconds, set when loop begins
INPUT_PID=""                    # background stdin reader PID

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --max-turns) MAX_TURNS="$2"; shift 2 ;;
        --delay)    DELAY="$2"; shift 2 ;;
        --batch)    BATCH_MODE=true; shift ;;
        --review)   SKIP_REVIEW=false; shift ;;
        --no-review) SKIP_REVIEW=true; shift ;;
        --model)    MODEL="$2"; shift 2 ;;
        --reviewer) REVIEWER="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ralph.sh [plan_path] [--dry-run] [--max-turns N] [--delay N] [--batch]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would be executed without running claude"
            echo "  --max-turns   Max agentic turns per task (default: 50, env: RALPH_MAX_TURNS)"
            echo "  --delay       Seconds for interactive countdown (default: 5, env: RALPH_DELAY)"
            echo "  --batch       Process <!-- BATCH --> groups as single invocations"
            echo "  --review      Run codex/claude review after each task"
            echo "  --reviewer X  Reviewer: auto (default), codex, or claude"
            echo "  --model NAME  Model preset (default: your claude default)"
            echo ""
            echo "Model presets:"
            echo "  opus-max       Opus 4.6, max thinking      (most capable, slowest)"
            echo "  opus-high      Opus 4.6, high thinking     (default for hard tasks)"
            echo "  opus-med       Opus 4.6, medium thinking"
            echo "  opus           Opus 4.6, no effort set"
            echo "  sonnet-high    Sonnet 4.6, high thinking"
            echo "  sonnet         Sonnet 4.6, no effort set   (fast, good for simple tasks)"
            echo "  haiku          Haiku 4.5, no effort set    (fastest, cheapest)"
            echo "  Or pass any claude model ID directly (e.g. claude-opus-4-6)"
            echo ""
            echo "Interactive features:"
            echo "  Inbox:     echo 'guidance' > .ralph-inbox  (from any terminal, any time)"
            echo "  Countdown: type during the pause between tasks to add guidance"
            echo "  Follow-up: ralph pauses when an agent asks a question"
            echo ""
            echo "Environment variables:"
            echo "  RALPH_MAX_TURNS  Same as --max-turns"
            echo "  RALPH_DELAY      Same as --delay"
            echo "  RALPH_MODEL      Same as --model"
            echo "  RALPH_REVIEWER   Same as --reviewer"
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

# ─── Resolve model preset ────────────────────────────────────────────────────

if [[ -n "$MODEL" ]]; then
    case "$MODEL" in
        opus-max)   MODEL="claude-opus-4-6";   EFFORT="max" ;;
        opus-high)  MODEL="claude-opus-4-6";   EFFORT="high" ;;
        opus-med)   MODEL="claude-opus-4-6";   EFFORT="medium" ;;
        opus)       MODEL="claude-opus-4-6" ;;
        sonnet-high) MODEL="claude-sonnet-4-6"; EFFORT="high" ;;
        sonnet)     MODEL="claude-sonnet-4-6" ;;
        haiku)      MODEL="claude-haiku-4-5-20251001" ;;
        *)          ;; # treat as raw model ID
    esac
fi

# Build model flags for claude -p
CLAUDE_MODEL_FLAGS=()
[[ -n "$MODEL" ]]  && CLAUDE_MODEL_FLAGS+=(--model "$MODEL")
[[ -n "$EFFORT" ]] && CLAUDE_MODEL_FLAGS+=(--effort "$EFFORT")

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
echo "Inbox: $WORK_DIR/$INBOX_FILE"
if [[ -n "$MODEL" ]]; then echo "Model: ${MODEL}${EFFORT:+ (effort: $EFFORT)}"; fi
if ! $SKIP_REVIEW; then echo "Review: enabled (reviewer: $REVIEWER)"; fi
echo ""

# ─── Pre-load context ────────────────────────────────────────────────────────

CODING_RULES=""
if [[ -f "$CODING_AGENTS_FILE" ]]; then
    CODING_RULES="$(cat "$CODING_AGENTS_FILE")"
fi

# ─── Task parsing ────────────────────────────────────────────────────────────

# Find the next unchecked task line number and text
# Returns: "LINE_NUM|TASK_TEXT" or empty if none
find_next_task() {
    local match
    match="$(grep -n '^[[:space:]]*- \[ \] ' "$PLAN_PATH" | head -1)" || return
    local line_num="${match%%:*}"
    local task_text="${match#*- \[ \] }"
    echo "${line_num}|${task_text}"
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

# ─── Plan trimming ──────────────────────────────────────────────────────────

# Return preamble (before first ## heading) + the section containing the given task line.
# Cuts completed phases to reduce prompt token count.
trim_plan_for_task() {
    local task_line_num="$1"

    # Find all ## heading line numbers
    local -a heading_lines
    mapfile -t heading_lines < <(grep -n '^## ' "$PLAN_PATH" | cut -d: -f1)

    # No headings? Return full plan (no structure to trim)
    if [[ ${#heading_lines[@]} -eq 0 ]]; then
        cat "$PLAN_PATH"
        return
    fi

    # Preamble: everything before the first ## heading
    local preamble_end=$((heading_lines[0] - 1))

    # Task is before any heading — return full plan
    if [[ $task_line_num -lt ${heading_lines[0]} ]]; then
        cat "$PLAN_PATH"
        return
    fi

    # Find the section containing the task line
    local section_start=${heading_lines[0]}
    local section_end=""
    for i in "${!heading_lines[@]}"; do
        if [[ ${heading_lines[$i]} -le $task_line_num ]]; then
            section_start=${heading_lines[$i]}
            local next=$((i + 1))
            if [[ $next -lt ${#heading_lines[@]} ]]; then
                section_end=$((heading_lines[$next] - 1))
            else
                section_end=""
            fi
        fi
    done

    # Print preamble
    if [[ $preamble_end -gt 0 ]]; then
        sed -n "1,${preamble_end}p" "$PLAN_PATH"
    fi

    # Separator if skipping phases
    if [[ $section_start -gt $((preamble_end + 1)) ]]; then
        echo ""
        echo "[... completed phases omitted ...]"
        echo ""
    fi

    # Current section
    if [[ -n "$section_end" ]]; then
        sed -n "${section_start},${section_end}p" "$PLAN_PATH"
    else
        sed -n "${section_start},\$p" "$PLAN_PATH"
    fi
}

# ─── Inbox & interaction ─────────────────────────────────────────────────────

# Read and clear the inbox file (user can write to it any time from any terminal)
read_inbox() {
    if [[ -f "$INBOX_FILE" ]] && [[ -s "$INBOX_FILE" ]]; then
        local contents
        contents="$(cat "$INBOX_FILE")"
        > "$INBOX_FILE"  # clear it (one-shot)
        echo "$contents"
    fi
}

# Check if the agent's output looks like it's asking the user a question
needs_followup() {
    local result="$1"
    [[ -z "$result" ]] && return 1
    echo "$result" | grep -qiE \
        '(need clarification|which approach|should [iI]|blocked by|unclear|question:|please confirm|please advise|awaiting|before I proceed|could you|can you clarify|not sure whether|two options|either .+ or)'
}

# Interactive countdown — user can type guidance, skip, or stop
# Also checks inbox file. Returns accumulated guidance in $USER_GUIDANCE.
interactive_countdown() {
    local task_desc="$1"
    local guidance=""

    # Always check inbox first (may have been written while previous task ran)
    local inbox_msg
    inbox_msg="$(read_inbox)"
    if [[ -n "$inbox_msg" ]]; then
        echo "  📬 Inbox: ${inbox_msg}"
        guidance+="${inbox_msg}"$'\n'
    fi

    if [[ "$DELAY" -le 0 ]]; then
        USER_GUIDANCE="$guidance"
        return 0  # auto-proceed
    fi

    # Show prompt and countdown with read -t
    printf "  > (%ds) guidance, 'skip', 'stop', or Enter: " "$DELAY"
    local input=""
    if read -t "$DELAY" -r input; then
        # User typed something before timer expired
        case "$input" in
            skip) USER_GUIDANCE=""; return 1 ;;
            stop) USER_GUIDANCE=""; return 2 ;;
            "")   ;;  # just pressed Enter — proceed
            *)    guidance+="${input}"$'\n' ;;
        esac
    fi
    printf "\r%80s\r" ""  # clear the countdown line

    USER_GUIDANCE="$guidance"
    return 0  # proceed
}

# After an agent finishes, check if it asked a question. If so, pause and prompt user.
# Appends user's reply to $USER_GUIDANCE for the next task.
handle_followup() {
    local result="$1"
    USER_GUIDANCE=""

    if needs_followup "$result"; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  Agent is asking for input:"
        # Show last 5 lines of result (likely contains the question)
        echo "$result" | tail -5 | sed 's/^/  /'
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "  > reply, 'skip', or 'stop': "
        local reply=""
        read -r reply
        case "$reply" in
            skip) return 0 ;;
            stop) echo "🛑 Stopped by user."; exit 0 ;;
            *)    USER_GUIDANCE="$reply" ;;
        esac
    fi
}

# ─── Time tracking ──────────────────────────────────────────────────────────

elapsed() {
    local now
    now="$(date +%s)"
    local secs=$(( now - START_TIME ))
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    if [[ $h -gt 0 ]]; then
        printf "%dh%02dm%02ds" "$h" "$m" "$s"
    elif [[ $m -gt 0 ]]; then
        printf "%dm%02ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

# Count total and completed tasks in plan
count_tasks() {
    local done_count total_count
    done_count=$(grep -c '^[[:space:]]*- \[[xX]\]' "$PLAN_PATH" || true)
    total_count=$(grep -c '^[[:space:]]*- \[[xX ]\]' "$PLAN_PATH" || true)
    echo "${done_count}/${total_count}"
}

# Print a status line with time, cost, progress
status_line() {
    local progress
    progress="$(count_tasks)"
    echo "  ⏱ $(elapsed) | 💰 \$${total_cost} | 📋 ${progress} tasks"
}

# ─── Review (codex / claude fallback) ───────────────────────────────────────

log_phase() {
    echo "  $1 $2"
}

auto_commit() {
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A
        git commit -m "ralph: auto-commit before review" 2>/dev/null || true
    fi
}

run_review() {
    local base="$1" task_text="$2"
    if $SKIP_REVIEW; then echo "LGTM (review skipped)"; return; fi

    local diff; diff="$(git diff "$base"..HEAD 2>/dev/null)"
    if [[ -z "$diff" ]]; then echo "LGTM — no changes to review"; return; fi

    local use_codex=false
    case "$REVIEWER" in
        codex) use_codex=true ;;
        claude) use_codex=false ;;
        auto)  command -v codex &>/dev/null && use_codex=true ;;
    esac

    if $use_codex; then
        log_phase "🔍" "Codex reviewing changes..." >&2
        codex review --base "$base" \
            2>&1 || echo "LGTM (codex error)"
    else
        log_phase "🔍" "Claude reviewing changes..." >&2
        claude -p \
            --model claude-opus-4-6 \
            --max-turns 5 \
            --dangerously-skip-permissions \
            <<< "Review this diff for bugs, edge cases, and issues the implementing agent may not have considered. Be specific about file and line. If the code looks good, just say LGTM.

## Task Context
${task_text}

## Diff
${diff}" 2>&1 || echo "LGTM (claude error)"
    fi
}

has_review_issues() {
    local output="$1"
    [[ -z "$output" ]] && return 1
    # Check only the last few lines where the verdict appears — matching the
    # full output causes false negatives when words like "clean" appear in
    # reviews that actually describe problems.
    echo "$output" | tail -5 | grep -qiE '(LGTM|no issues|looks good|no bugs|no discrete|did not find|did not identify)' && return 1
    return 0
}

fix_review_issues() {
    local review_output="$1"
    if ! has_review_issues "$review_output"; then
        log_phase "✅" "Review passed — LGTM"
        return
    fi
    log_phase "🔧" "Fixing review findings..."
    echo "$review_output" | head -20 | sed 's/^/    /'
    claude -p \
        --max-turns 15 \
        --dangerously-skip-permissions \
        <<< "A code reviewer found the following issues. Fix each one. Commit when done.

## Review Findings
${review_output}

## Working Directory
$(pwd)" 2>/dev/null || true
}

# ─── Same-terminal chat ─────────────────────────────────────────────────────

# Start a background reader on stdin so user can type messages while agent runs.
# Messages go to the inbox file; ralph picks them up before the next task.
start_input_reader() {
    # Only start if stdin is a terminal
    [[ -t 0 ]] || return 0
    (
        while IFS= read -r line </dev/tty 2>/dev/null; do
            [[ -z "$line" ]] && continue
            echo "$line" >> "$INBOX_FILE"
            echo "  📬 Queued: $line" >/dev/tty
        done
    ) &
    INPUT_PID=$!
}

stop_input_reader() {
    if [[ -n "$INPUT_PID" ]] && kill -0 "$INPUT_PID" 2>/dev/null; then
        kill "$INPUT_PID" 2>/dev/null
        wait "$INPUT_PID" 2>/dev/null || true
        INPUT_PID=""
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

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

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
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did.
PROMPT

    # Append user guidance if present
    if [[ -n "$USER_GUIDANCE" ]]; then
        cat <<GUIDE

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

${USER_GUIDANCE}
GUIDE
    fi
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

The current phase of the plan is below (other phases trimmed). Read the plan file if you need context from other phases:

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
- If you need clarification from the user, say so clearly at the end of your response. The orchestrator will detect this and pause for user input.
- When done, respond with a brief summary of what you did for each task.
PROMPT

    # Append user guidance if present
    if [[ -n "$USER_GUIDANCE" ]]; then
        cat <<GUIDE

## User Guidance

The user has provided the following context for this task. Read carefully and follow:

${USER_GUIDANCE}
GUIDE
    fi
}

# ─── Execute ─────────────────────────────────────────────────────────────────

CLAUDE_PID=""

cleanup() {
    stop_input_reader
    if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null
        wait "$CLAUDE_PID" 2>/dev/null
    fi
}

run_claude() {
    local prompt="$1"
    # Start background stdin reader so user can chat while agent works
    start_input_reader
    # Run claude in a background job so we can track its PID for cleanup
    coproc CLAUDE_PROC {
        claude -p \
            "${CLAUDE_MODEL_FLAGS[@]}" \
            --max-turns "$MAX_TURNS" \
            --dangerously-skip-permissions \
            --verbose \
            --output-format stream-json \
            <<< "$prompt"
    }
    CLAUDE_PID=$CLAUDE_PROC_PID
    parse_stream <&"${CLAUDE_PROC[0]}"
    wait "$CLAUDE_PID" 2>/dev/null
    local rc=$?
    CLAUDE_PID=""
    # Stop background stdin reader
    stop_input_reader
    return $rc
}

# Format tool detail from tool name + input JSON
format_tool_detail() {
    local name="$1" input="$2"
    local detail=""
    case "$name" in
        Read|Write)
            detail="$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)"
            [[ -n "$detail" ]] && detail="$(basename "$detail")"
            ;;
        Edit)
            local fp
            fp="$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)"
            [[ -n "$fp" ]] && detail="$(basename "$fp")"
            ;;
        Bash)
            detail="$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)"
            # Truncate long commands
            if [[ ${#detail} -gt 80 ]]; then
                detail="${detail:0:77}..."
            fi
            ;;
        Grep)
            local pat path
            pat="$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null)"
            path="$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)"
            [[ -n "$path" ]] && path="$(basename "$path")"
            detail="${pat:+/$pat/}${path:+ in $path}"
            ;;
        Glob)
            detail="$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null)"
            ;;
        Agent)
            detail="$(printf '%s' "$input" | jq -r '.description // empty' 2>/dev/null)"
            ;;
        *)
            detail=""
            ;;
    esac
    if [[ -n "$detail" ]]; then
        echo "  🔧 $name — $detail"
    else
        echo "  🔧 $name"
    fi
}

# Parse stream-json output to show live progress
# Uses bash pattern matching to skip frequent events (text deltas, message
# lifecycle) without forking jq. Only forks jq for infrequent events
# (tool use, result) — reduces process spawns from hundreds to ~10-30 per task.
parse_stream() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Fast-path: skip frequent events using bash matching (no jq fork)
        [[ "$line" == *'"content_block_delta"'* ]] && continue
        [[ "$line" == *'"content_block_stop"'* ]] && continue
        [[ "$line" == *'"message_start"'* ]] && continue
        [[ "$line" == *'"message_delta"'* ]] && continue
        [[ "$line" == *'"message_stop"'* ]] && continue

        # Infrequent events — fork jq only for these
        if [[ "$line" == *'"type":"assistant"'* ]]; then
            # Tool use — show which tool is being called with detail
            printf '%s' "$line" | jq -r '
                .message.content[]? |
                select(.type == "tool_use") |
                "\(.name)\t\(.input | @json)"
            ' 2>/dev/null | while IFS=$'\t' read -r tool_name tool_input; do
                [[ -n "$tool_name" ]] && format_tool_detail "$tool_name" "$tool_input"
            done
        elif [[ "$line" == *'"content_block_start"'* && "$line" == *'"tool_use"'* ]]; then
            local tool
            tool="$(printf '%s' "$line" | jq -r '.content_block.name // empty' 2>/dev/null)"
            [[ -n "$tool" ]] && echo "  🔧 $tool"
        elif [[ "$line" == *'"type":"result"'* ]]; then
            local result_text
            result_text="$(printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null)"
            if [[ -n "$result_text" ]]; then
                echo ""
                echo "$result_text"
                echo "$result_text" > "$RESULT_TMPFILE"
            fi
            local cost_usd
            cost_usd="$(printf '%s' "$line" | jq -r '.total_cost_usd // empty' 2>/dev/null)"
            if [[ -n "$cost_usd" ]]; then
                echo "  💰 Cost: \$${cost_usd}"
                echo "$cost_usd" > "$COST_TMPFILE"
            fi
        fi
    done
}

completed=0
failed=0
consecutive_fails=0
MAX_CONSECUTIVE_FAILS=3
last_failed_task=""
total_cost=0
COST_TMPFILE="$(mktemp)"
RESULT_TMPFILE="$(mktemp)"   # agent's final output, for follow-up detection
trap 'rm -f "$COST_TMPFILE" "$RESULT_TMPFILE"' EXIT

# Read task cost from temp file and accumulate
accumulate_cost() {
    if [[ -s "$COST_TMPFILE" ]]; then
        local task_cost
        task_cost="$(cat "$COST_TMPFILE")"
        total_cost="$(awk "BEGIN {printf \"%.8f\", $total_cost + $task_cost}")"
        > "$COST_TMPFILE"
    fi
}

# Trap ctrl+c for clean exit — kill the running claude process
trap '
    echo ""
    cleanup
    accumulate_cost
    echo "🛑 Stopped after ${completed} tasks, ${failed} failed. ⏱ $(elapsed) | 💰 \$${total_cost}"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git stash push -u -m "ralph: interrupted after ${completed} tasks completed" 2>/dev/null \
            && echo "📦 Changes stashed (git stash pop to restore)" \
            || echo "⚠️  git stash failed — changes left in working tree"
    fi
    exit 0
' INT

START_TIME="$(date +%s)"

echo "📬 Type a message any time — it will be sent to the next agent."
echo ""

while true; do
    local_result="$(find_next_task)"
    if [[ -z "$local_result" ]]; then
        echo "✅ All tasks complete! (${completed} completed, ${failed} failed)"
        status_line
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
            for entry in "${batch_tasks[@]}"; do
                local ln="${entry%%|*}"
                sed -i "${ln}s/- \[ \]/- [x]/" "$PLAN_PATH"
            done
            completed=$((completed + ${#batch_tasks[@]}))
            continue
        fi

        # Interactive countdown (reads inbox + accepts typed input)
        interactive_countdown "batch of ${#batch_tasks[@]} tasks"
        rc=$?
        if [[ $rc -eq 1 ]]; then echo "  ⏭️  Skipped"; continue; fi
        if [[ $rc -eq 2 ]]; then echo "🛑 Stopped by user."; break; fi

        review_base="$(git rev-parse HEAD 2>/dev/null || echo "")"
        > "$RESULT_TMPFILE"
        PLAN_CONTENT="$(trim_plan_for_task "$task_line")"
        prompt="$(build_batch_prompt "${batch_tasks[@]}")"
        echo ""
        if run_claude "$prompt"; then
            accumulate_cost
            new_result="$(find_next_task)"
            new_task="${new_result#*|}"
            if [[ "$new_task" == "${batch_tasks[0]#*|}" ]]; then
                failed=$((failed + ${#batch_tasks[@]}))
                consecutive_fails=$((consecutive_fails + 1))
                echo ""
                echo "❌ Batch failed (task not checked off)"
            else
                completed=$((completed + ${#batch_tasks[@]}))
                consecutive_fails=0
                echo ""
                echo "✅ Batch complete"
                # Codex/Claude review
                if ! $SKIP_REVIEW && [[ -n "$review_base" ]]; then
                    auto_commit
                    review_out="$(run_review "$review_base" "${batch_tasks[0]#*|}")"
                    fix_review_issues "$review_out"
                fi
            fi
        else
            accumulate_cost
            failed=$((failed + ${#batch_tasks[@]}))
            consecutive_fails=$((consecutive_fails + 1))
            echo ""
            echo "❌ Batch failed (exit code: $?)"
        fi
        status_line

        # Check if agent asked a question — pause for user if so
        if [[ -s "$RESULT_TMPFILE" ]]; then
            handle_followup "$(cat "$RESULT_TMPFILE")"
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

        # Interactive countdown (reads inbox + accepts typed input)
        interactive_countdown "$task_text"
        rc=$?
        if [[ $rc -eq 1 ]]; then echo "  ⏭️  Skipped"; continue; fi
        if [[ $rc -eq 2 ]]; then echo "🛑 Stopped by user."; break; fi

        review_base="$(git rev-parse HEAD 2>/dev/null || echo "")"
        > "$RESULT_TMPFILE"
        PLAN_CONTENT="$(trim_plan_for_task "$task_line")"
        prompt="$(build_single_prompt "$task_text")"
        echo ""
        if run_claude "$prompt"; then
            accumulate_cost
            new_result="$(find_next_task)"
            new_task="${new_result#*|}"
            if [[ "$new_task" == "$task_text" ]]; then
                failed=$((failed + 1))
                consecutive_fails=$((consecutive_fails + 1))
                echo ""
                echo "❌ Task failed (task not checked off)"
            else
                completed=$((completed + 1))
                consecutive_fails=0
                echo ""
                echo "✅ Task complete"
                # Codex/Claude review
                if ! $SKIP_REVIEW && [[ -n "$review_base" ]]; then
                    auto_commit
                    review_out="$(run_review "$review_base" "$task_text")"
                    fix_review_issues "$review_out"
                fi
            fi
        else
            accumulate_cost
            failed=$((failed + 1))
            consecutive_fails=$((consecutive_fails + 1))
            echo ""
            echo "❌ Task failed (exit code: $?)"
        fi
        status_line

        # Check if agent asked a question — pause for user if so
        if [[ -s "$RESULT_TMPFILE" ]]; then
            handle_followup "$(cat "$RESULT_TMPFILE")"
        fi
    fi

    # Bail out if same task keeps failing
    if [[ $consecutive_fails -ge $MAX_CONSECUTIVE_FAILS ]]; then
        echo ""
        echo "🛑 Stopping: $MAX_CONSECUTIVE_FAILS consecutive failures on the same task."
        echo "   Fix the issue manually, then re-run ralph."
        exit 1
    fi

    echo ""
done
