#!/usr/bin/env bash
set -euo pipefail

# ralph-github.sh — Execute a plan file task-by-task with GitHub PR pipeline
#
# Per-task pipeline:
#   ① Branch off previous task (or base branch)
#   ② Execute task (claude -p, fresh context per task)
#   ③ Codex review (falls back to Claude Opus 4.6)
#   ④ Fix review findings
#   ⑤ Create PR (triggers bugbot)
#   ⑥ Check previous PR bugbot → examine → fix → merge → rebase
#
# Usage: ralph-github.sh [plan_path] [--dry-run] [--max-turns N] [--no-review] [--no-bugbot]

# ─── Configuration ───────────────────────────────────────────────────────────

CODING_AGENTS_FILE="$HOME/.claude/CODING_AGENTS.md"
RALPH_ASCII="$HOME/.claude/skills/ralph/ralph-ascii.txt"
MAX_TURNS="${RALPH_MAX_TURNS:-50}"
DELAY="${RALPH_DELAY:-5}"
DRY_RUN=false
PLAN_PATH=""
INBOX_FILE=".ralph-inbox"
USER_GUIDANCE=""
START_TIME=""
INPUT_PID=""

# GitHub pipeline config
MAIN_BRANCH="${RALPH_BASE_BRANCH:-master}"
BUGBOT_USER="${RALPH_BUGBOT_USER:-cursor[bot]}"
BUGBOT_POLL_INTERVAL=30
BUGBOT_MAX_WAIT=300
SKIP_REVIEW=false
SKIP_BUGBOT=false
GITHUB_REPO=""

# Pipeline state
PREV_PR=""
PREV_PR_URL=""
PREV_BRANCH=""
CURRENT_BRANCH=""
ORIGINAL_BRANCH=""

# ─── Argument parsing ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=true; shift ;;
        --max-turns)     MAX_TURNS="$2"; shift 2 ;;
        --delay)         DELAY="$2"; shift 2 ;;
        --base-branch)   MAIN_BRANCH="$2"; shift 2 ;;
        --bugbot-user)   BUGBOT_USER="$2"; shift 2 ;;
        --no-review)     SKIP_REVIEW=true; shift ;;
        --no-bugbot)     SKIP_BUGBOT=true; shift ;;
        --help|-h)
            sed -n '2,/^$/s/^# //p' "$0"
            echo ""
            echo "Options:"
            echo "  --dry-run          Preview without executing"
            echo "  --max-turns N      Max agentic turns per task (default: 50)"
            echo "  --delay N          Countdown seconds between tasks (default: 5)"
            echo "  --base-branch NAME Main branch (default: master)"
            echo "  --bugbot-user NAME Bugbot GitHub user (default: cursor[bot])"
            echo "  --no-review        Skip codex/claude review step"
            echo "  --no-bugbot        Skip bugbot waiting/checking"
            exit 0
            ;;
        *)
            if [[ -z "$PLAN_PATH" ]]; then PLAN_PATH="$1"
            else echo "Error: unexpected argument '$1'" >&2; exit 1
            fi
            shift ;;
    esac
done

# ─── Find plan file ──────────────────────────────────────────────────────────

find_plan() {
    if [[ -n "$PLAN_PATH" ]]; then
        [[ -f "$PLAN_PATH" ]] && { echo "$PLAN_PATH"; return; }
        echo "Error: plan file not found: $PLAN_PATH" >&2; exit 1
    fi
    for candidate in "plan.md" "PLAN.md"; do
        [[ -f "$candidate" ]] && { echo "$candidate"; return; }
    done
    local plans_dir="$HOME/.claude/plans"
    if [[ -d "$plans_dir" ]]; then
        local -a plans
        mapfile -t plans < <(find "$plans_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null)
        if [[ ${#plans[@]} -eq 1 ]]; then echo "${plans[0]}"; return
        elif [[ ${#plans[@]} -gt 1 ]]; then
            echo "Multiple plans found:" >&2
            printf '  %s\n' "${plans[@]}" >&2
            exit 1
        fi
    fi
    echo "Error: no plan file found" >&2; exit 1
}

PLAN_PATH="$(realpath "$(find_plan)")"
WORK_DIR="$(pwd)"

# ─── Detect GitHub repo ──────────────────────────────────────────────────────

detect_repo() {
    git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||'
}

GITHUB_REPO="$(detect_repo)"
if [[ -z "$GITHUB_REPO" ]]; then
    echo "Error: could not detect GitHub repo from git remote" >&2
    exit 1
fi

ORIGINAL_BRANCH="$(git branch --show-current 2>/dev/null || echo "$MAIN_BRANCH")"

echo ""
[[ -f "$RALPH_ASCII" ]] && cat "$RALPH_ASCII"
echo "📋 Plan:     $PLAN_PATH"
echo "📂 Working:  $WORK_DIR"
echo "🌿 Base:     $MAIN_BRANCH"
echo "🔗 Repo:     $GITHUB_REPO"
echo "🤖 Bugbot:   $BUGBOT_USER"
echo "📬 Inbox:    $WORK_DIR/$INBOX_FILE"
echo ""

# ─── Pre-load context ────────────────────────────────────────────────────────

CODING_RULES=""
[[ -f "$CODING_AGENTS_FILE" ]] && CODING_RULES="$(cat "$CODING_AGENTS_FILE")"
PLAN_CONTENT="$(cat "$PLAN_PATH")"

# ─── Task parsing ────────────────────────────────────────────────────────────

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

extract_criterion() {
    local task_text="$1"
    if [[ "$task_text" =~ _Criterion:\ (.+)_$ ]]; then echo "${BASH_REMATCH[1]}"
    elif [[ "$task_text" =~ —\ (.+)$ ]]; then echo "${BASH_REMATCH[1]}"
    else echo "Task is complete and working correctly"
    fi
}

# ─── Inbox & interaction ─────────────────────────────────────────────────────

read_inbox() {
    if [[ -f "$INBOX_FILE" ]] && [[ -s "$INBOX_FILE" ]]; then
        cat "$INBOX_FILE"; > "$INBOX_FILE"
    fi
}

interactive_countdown() {
    local guidance=""
    local inbox_msg; inbox_msg="$(read_inbox)"
    [[ -n "$inbox_msg" ]] && { echo "  📬 Inbox: ${inbox_msg}"; guidance+="${inbox_msg}"$'\n'; }

    if [[ "$DELAY" -le 0 ]]; then USER_GUIDANCE="$guidance"; return 0; fi

    printf "  > (%ds) guidance, 'skip', 'stop', or Enter: " "$DELAY"
    local input=""
    if read -t "$DELAY" -r input; then
        case "$input" in
            skip) USER_GUIDANCE=""; return 1 ;;
            stop) USER_GUIDANCE=""; return 2 ;;
            "")   ;;
            *)    guidance+="${input}"$'\n' ;;
        esac
    fi
    printf "\r%80s\r" ""
    USER_GUIDANCE="$guidance"
    return 0
}

needs_followup() {
    local result="$1"
    [[ -z "$result" ]] && return 1
    echo "$result" | grep -qiE \
        '(need clarification|which approach|should [iI]|blocked by|unclear|please confirm|before I proceed|could you|can you clarify)'
}

handle_followup() {
    local result="$1"
    USER_GUIDANCE=""
    if needs_followup "$result"; then
        echo ""
        echo "━━━ ⚠️  Agent is asking for input ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$result" | tail -5 | sed 's/^/  /'
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "  > reply, 'skip', or 'stop': "
        local reply=""; read -r reply
        case "$reply" in
            skip) return 0 ;;
            stop) echo "🛑 Stopped by user."; exit 0 ;;
            *)    USER_GUIDANCE="$reply" ;;
        esac
    fi
}

# ─── Same-terminal chat ──────────────────────────────────────────────────────

start_input_reader() {
    [[ -t 0 ]] || return 0
    ( while IFS= read -r line </dev/tty 2>/dev/null; do
        [[ -z "$line" ]] && continue
        echo "$line" >> "$INBOX_FILE"
        echo "  📬 Queued: $line" >/dev/tty
    done ) &
    INPUT_PID=$!
}

stop_input_reader() {
    if [[ -n "$INPUT_PID" ]] && kill -0 "$INPUT_PID" 2>/dev/null; then
        kill "$INPUT_PID" 2>/dev/null; wait "$INPUT_PID" 2>/dev/null || true; INPUT_PID=""
    fi
}

# ─── Time tracking ───────────────────────────────────────────────────────────

elapsed() {
    local secs=$(( $(date +%s) - START_TIME ))
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 )) s=$(( secs % 60 ))
    if [[ $h -gt 0 ]]; then printf "%dh%02dm%02ds" "$h" "$m" "$s"
    elif [[ $m -gt 0 ]]; then printf "%dm%02ds" "$m" "$s"
    else printf "%ds" "$s"
    fi
}

count_tasks() {
    local total=0 done=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-\ \[[xX]\] ]]; then done=$((done + 1)); total=$((total + 1))
        elif [[ "$line" =~ ^[[:space:]]*-\ \[\ \] ]]; then total=$((total + 1))
        fi
    done < "$PLAN_PATH"
    echo "${done}/${total}"
}

status_line() {
    echo "  ⏱ $(elapsed) | 💰 \$${total_cost} | 📋 $(count_tasks) tasks | 🌿 ${CURRENT_BRANCH:-$MAIN_BRANCH}"
}

# ─── Utility ──────────────────────────────────────────────────────────────────

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | head -c 40
}

log_phase() {
    local phase="$1" msg="$2"
    echo "  ${phase} ${msg}"
}

# ─── Git operations ──────────────────────────────────────────────────────────

create_task_branch() {
    local task_num="$1" task_text="$2"
    local slug; slug="$(slugify "$task_text")"
    local base="${PREV_BRANCH:-$MAIN_BRANCH}"
    local branch="ralph/task-${task_num}-${slug}"

    # Ensure base exists locally
    if ! git rev-parse --verify "$base" &>/dev/null; then
        git fetch origin "$base" &>/dev/null || true
    fi

    git checkout -b "$branch" "$base" 2>/dev/null
    echo "$branch"
}

# Ensure all changes are committed before review/PR
auto_commit() {
    local task_num="$1"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        git add -A
        git commit -m "ralph-github: auto-commit remaining changes (task ${task_num})" 2>/dev/null
    fi
}

rebase_on_main() {
    local branch="$1"
    log_phase "📥" "Rebasing ${branch} on ${MAIN_BRANCH}..."
    git checkout "$MAIN_BRANCH" 2>/dev/null
    git pull origin "$MAIN_BRANCH" 2>/dev/null

    git checkout "$branch" 2>/dev/null
    if ! git rebase "$MAIN_BRANCH" 2>/dev/null; then
        echo "  ⚠️  Rebase conflict — falling back to merge"
        git rebase --abort 2>/dev/null || true
        git merge "$MAIN_BRANCH" --no-edit 2>/dev/null || true
    fi
    git push --force-with-lease origin "$branch" 2>/dev/null || true
}

# ─── Review ───────────────────────────────────────────────────────────────────

run_review() {
    local base="${PREV_BRANCH:-$MAIN_BRANCH}"
    local task_text="$1"

    if $SKIP_REVIEW; then
        echo "LGTM (review skipped)"
        return
    fi

    if command -v codex &>/dev/null; then
        log_phase "🔍" "Codex reviewing changes..." >&2
        codex review --base "$base" \
            "Review for: ${task_text}. Look for bugs, edge cases, and things the implementing agent may not have considered. Say LGTM if the code looks good." \
            2>&1 || echo "LGTM (codex error)"
    else
        log_phase "🔍" "Claude Opus reviewing changes..." >&2
        local diff; diff="$(git diff "$base"..HEAD 2>/dev/null)"
        if [[ -z "$diff" ]]; then
            echo "LGTM — no changes to review"
            return
        fi
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
    # Short output is likely "LGTM"
    [[ ${#output} -lt 50 ]] && echo "$output" | grep -qiE '(LGTM|no issues|looks good|no bugs|clean)' && return 1
    # Explicit LGTM at start
    echo "$output" | head -3 | grep -qiE '^(LGTM|no issues|looks good|all good)' && return 1
    return 0
}

fix_review_issues() {
    local review_output="$1" task_num="$2"
    if ! has_review_issues "$review_output"; then
        log_phase "✅" "Review passed"
        return
    fi
    log_phase "🔧" "Fixing review issues..."
    claude -p \
        --max-turns 15 \
        --dangerously-skip-permissions \
        <<< "A code reviewer found the following issues. Fix each one. Commit when done.

## Review Findings
${review_output}

## Working Directory
$(pwd)" 2>/dev/null || true
    auto_commit "$task_num"
}

# ─── GitHub: PR creation ─────────────────────────────────────────────────────

create_pr() {
    local branch="$1" task_text="$2" task_num="$3"
    local title="Task ${task_num}: ${task_text:0:60}"

    git push -u origin "$branch" >&2

    local pr_url
    pr_url="$(gh pr create \
        --base "$MAIN_BRANCH" \
        --title "$title" \
        --body "$(cat <<EOF
## Task ${task_num}

${task_text}

### Review Pipeline
- [x] Task executed by Claude agent
- [x] Codex/Claude review completed
- [ ] Bugbot review pending

---
*Auto-generated by ralph-github*
EOF
)")"

    local pr_num; pr_num="$(echo "$pr_url" | sed -n 's|.*/pull/\([0-9]*\).*|\1|p')"
    echo "${pr_num}|${pr_url}"
}

# ─── GitHub: Bugbot ───────────────────────────────────────────────────────────

wait_for_bugbot() {
    local pr_num="$1"
    if $SKIP_BUGBOT; then
        echo "skipped"
        return 1
    fi

    log_phase "🤖" "Waiting for bugbot on PR #${pr_num}..."
    local waited=0

    while [[ $waited -lt $BUGBOT_MAX_WAIT ]]; do
        # Check for bugbot reviews
        local review_count
        review_count="$(gh api "repos/${GITHUB_REPO}/pulls/${pr_num}/reviews" \
            --jq "[.[] | select(.user.login == \"${BUGBOT_USER}\")] | length" 2>/dev/null || echo "0")"

        if [[ "$review_count" -gt 0 ]]; then
            log_phase "🤖" "Bugbot reviewed PR #${pr_num}"
            return 0
        fi

        printf "\r  ⏳ Waiting for bugbot... %ds / %ds" "$waited" "$BUGBOT_MAX_WAIT"
        sleep "$BUGBOT_POLL_INTERVAL"
        waited=$((waited + BUGBOT_POLL_INTERVAL))
    done

    printf "\r%80s\r" ""
    log_phase "⏰" "Bugbot timeout (${BUGBOT_MAX_WAIT}s) — proceeding"
    return 1
}

get_bugbot_comments() {
    local pr_num="$1"
    gh api "repos/${GITHUB_REPO}/pulls/${pr_num}/comments" \
        --jq ".[] | select(.user.login == \"${BUGBOT_USER}\") | .body" 2>/dev/null
}

examine_bugbot_findings() {
    local pr_num="$1" prev_branch="$2" comments="$3" return_branch="$4"

    log_phase "🔍" "Examining bugbot findings on PR #${pr_num}..."

    # Switch to previous branch to apply fixes
    git checkout "$prev_branch" 2>/dev/null

    # Strip HTML/markdown image tags from bugbot comments for cleaner prompt
    local clean_comments
    clean_comments="$(echo "$comments" | sed 's/<p>.*<\/p>//g; s/<!-- BUGBOT_BUG_ID:.*-->//g; s/<!-- LOCATIONS.*END -->//g')"

    claude -p \
        --max-turns 15 \
        --dangerously-skip-permissions \
        <<< "Bugbot (${BUGBOT_USER}) reviewed PR #${pr_num} and found these issues:

${clean_comments}

For each finding:
1. Does the suggestion make sense given the code?
2. If yes, implement the fix.
3. If the finding is a false positive, skip it.
Commit any fixes with a message like: fix: address bugbot finding - <summary>

Working directory: $(pwd)" 2>/dev/null || true

    # Push fixes if there are new commits
    local local_head; local_head="$(git rev-parse HEAD)"
    local remote_head; remote_head="$(git rev-parse "origin/$prev_branch" 2>/dev/null || echo "")"
    if [[ "$local_head" != "$remote_head" ]]; then
        git push origin "$prev_branch" 2>/dev/null || true
    fi

    # Switch back
    git checkout "$return_branch" 2>/dev/null
}

merge_pr() {
    local pr_num="$1"
    log_phase "🔀" "Merging PR #${pr_num}..."
    if ! gh pr merge "$pr_num" --merge --delete-branch 2>/dev/null; then
        echo "  ⚠️  Merge failed — PR may need manual merge"
        return 1
    fi
    return 0
}

# ─── Handle previous PR (phase ⑥) ────────────────────────────────────────────

handle_previous_pr() {
    local return_branch="$1"
    [[ -z "$PREV_PR" ]] && return 0

    echo ""
    echo "  ── Handling previous PR #${PREV_PR} ──"

    # Wait for and check bugbot
    if wait_for_bugbot "$PREV_PR"; then
        local comments; comments="$(get_bugbot_comments "$PREV_PR")"
        if [[ -n "$comments" ]]; then
            examine_bugbot_findings "$PREV_PR" "$PREV_BRANCH" "$comments" "$return_branch"
        fi
    fi

    # Merge and rebase
    if merge_pr "$PREV_PR"; then
        rebase_on_main "$return_branch"
    fi
}

# ─── Handle final PR ─────────────────────────────────────────────────────────

handle_final_pr() {
    [[ -z "$PREV_PR" ]] && return 0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🏁 Handling final PR #${PREV_PR}..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if wait_for_bugbot "$PREV_PR"; then
        local comments; comments="$(get_bugbot_comments "$PREV_PR")"
        if [[ -n "$comments" ]]; then
            examine_bugbot_findings "$PREV_PR" "$PREV_BRANCH" "$comments" "$PREV_BRANCH"
        fi
    fi

    if merge_pr "$PREV_PR"; then
        git checkout "$MAIN_BRANCH" 2>/dev/null
        git pull origin "$MAIN_BRANCH" 2>/dev/null
    fi
}

# ─── Build prompt ────────────────────────────────────────────────────────────

build_task_prompt() {
    local task_text="$1"
    local criterion; criterion="$(extract_criterion "$task_text")"
    local recent_commits; recent_commits="$(git log --oneline -5 2>/dev/null || echo 'No git history.')"

    cat <<PROMPT
You are executing a single task from a plan.

## Your Task

**Task:** ${task_text}
**Completion Criterion:** ${criterion}
**Plan file:** ${PLAN_PATH}
**Working directory:** ${WORK_DIR}

## Plan Context

<plan>
${PLAN_CONTENT}
</plan>

## Recent Commits

${recent_commits}

## Coding Agent Rules

${CODING_RULES:-No coding agent rules file found — use your best judgment.}

## Instructions

- Execute ONLY this single task. Do not work on other tasks.
- When the task is complete and the completion criterion is met, edit the plan file to check off this task: change \`- [ ]\` to \`- [x]\` for this task's line.
- Commit your work with a clear message.
- If you need clarification, say so clearly at the end of your response.
- When done, respond with a brief summary of what you did.
PROMPT

    # Add previous PR context
    if [[ -n "$PREV_PR_URL" ]]; then
        cat <<PRCTX

## Previous Work

The previous task created PR: ${PREV_PR_URL}
Your branch already includes those changes. Bugbot review of that PR is pending.
PRCTX
    fi

    # Add user guidance
    if [[ -n "$USER_GUIDANCE" ]]; then
        cat <<GUIDE

## User Guidance

${USER_GUIDANCE}
GUIDE
    fi
}

# ─── Stream parsing (live progress) ──────────────────────────────────────────

format_tool_detail() {
    local name="$1" input="$2"
    local detail=""
    case "$name" in
        Read|Write) detail="$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)"; [[ -n "$detail" ]] && detail="$(basename "$detail")" ;;
        Edit)       local fp; fp="$(printf '%s' "$input" | jq -r '.file_path // empty' 2>/dev/null)"; [[ -n "$fp" ]] && detail="$(basename "$fp")" ;;
        Bash)       detail="$(printf '%s' "$input" | jq -r '.command // empty' 2>/dev/null)"; [[ ${#detail} -gt 80 ]] && detail="${detail:0:77}..." ;;
        Grep)       local pat path; pat="$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null)"; path="$(printf '%s' "$input" | jq -r '.path // empty' 2>/dev/null)"; [[ -n "$path" ]] && path="$(basename "$path")"; detail="${pat:+/$pat/}${path:+ in $path}" ;;
        Glob)       detail="$(printf '%s' "$input" | jq -r '.pattern // empty' 2>/dev/null)" ;;
        Agent)      detail="$(printf '%s' "$input" | jq -r '.description // empty' 2>/dev/null)" ;;
    esac
    if [[ -n "$detail" ]]; then echo "  🔧 $name — $detail"; else echo "  🔧 $name"; fi
}

parse_stream() {
    local final_text=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local type; type="$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)" || continue
        case "$type" in
            assistant)
                printf '%s' "$line" | jq -r '
                    .message.content[]? | select(.type == "tool_use") |
                    "\(.name)\t\(.input | @json)"
                ' 2>/dev/null | while IFS=$'\t' read -r tool_name tool_input; do
                    [[ -n "$tool_name" ]] && format_tool_detail "$tool_name" "$tool_input"
                done ;;
            content_block_delta)
                local dt; dt="$(printf '%s' "$line" | jq -r '.delta.type // empty' 2>/dev/null)"
                if [[ "$dt" == "text_delta" ]]; then
                    final_text+="$(printf '%s' "$line" | jq -r '.delta.text // empty' 2>/dev/null)"
                fi ;;
            result)
                local rt; rt="$(printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null)"
                if [[ -n "$rt" ]]; then echo ""; echo "$rt"; echo "$rt" > "$RESULT_TMPFILE"
                elif [[ -n "$final_text" ]]; then echo ""; echo "$final_text"; echo "$final_text" > "$RESULT_TMPFILE"
                fi
                local cost; cost="$(printf '%s' "$line" | jq -r '.total_cost_usd // empty' 2>/dev/null)"
                if [[ -n "$cost" ]]; then
                    echo "  💰 Cost: \$${cost}"
                    echo "$cost" > "$COST_TMPFILE"
                fi ;;
        esac
    done
}

# ─── Execute task ─────────────────────────────────────────────────────────────

CLAUDE_PID=""

run_claude() {
    local prompt="$1"
    start_input_reader
    coproc CLAUDE_PROC {
        claude -p \
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
    stop_input_reader
    return $rc
}

# ─── Cost tracking ───────────────────────────────────────────────────────────

completed=0
failed=0
consecutive_fails=0
MAX_CONSECUTIVE_FAILS=3
total_cost=0
COST_TMPFILE="$(mktemp)"
RESULT_TMPFILE="$(mktemp)"
trap 'rm -f "$COST_TMPFILE" "$RESULT_TMPFILE"' EXIT

accumulate_cost() {
    if [[ -s "$COST_TMPFILE" ]]; then
        local task_cost; task_cost="$(cat "$COST_TMPFILE")"
        total_cost="$(awk "BEGIN {printf \"%.8f\", $total_cost + $task_cost}")"
        > "$COST_TMPFILE"
    fi
}

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
    stop_input_reader
    if [[ -n "$CLAUDE_PID" ]] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null; wait "$CLAUDE_PID" 2>/dev/null
    fi
}

trap '
    echo ""
    cleanup
    accumulate_cost
    echo "🛑 Stopped after ${completed} tasks, ${failed} failed. ⏱ $(elapsed) | 💰 \$${total_cost}"
    # Return to original branch on interrupt
    git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
    exit 0
' INT

# ─── Main loop ───────────────────────────────────────────────────────────────

START_TIME="$(date +%s)"
echo "📬 Type a message any time — it will be sent to the next agent."
echo ""

while true; do
    local_result="$(find_next_task)"
    if [[ -z "$local_result" ]]; then
        handle_final_pr
        echo ""
        echo "✅ All tasks complete and merged! (${completed} completed, ${failed} failed)"
        status_line
        break
    fi

    task_line="${local_result%%|*}"
    task_text="${local_result#*|}"
    task_num=$((completed + failed + 1))

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Task ${task_num}: ${task_text}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if $DRY_RUN; then
        echo "[dry-run] Would execute: branch → task → review → PR → bugbot"
        sed -i "${task_line}s/- \[ \]/- [x]/" "$PLAN_PATH"
        completed=$((completed + 1))
        continue
    fi

    # Interactive countdown
    rc=0
    interactive_countdown "$task_text" || rc=$?
    if [[ $rc -eq 1 ]]; then echo "  ⏭️  Skipped"; continue; fi
    if [[ $rc -eq 2 ]]; then echo "🛑 Stopped by user."; break; fi

    # ── ① BRANCH ──
    CURRENT_BRANCH="$(create_task_branch "$task_num" "$task_text")"
    log_phase "🌿" "Branch: ${CURRENT_BRANCH} (from ${PREV_BRANCH:-$MAIN_BRANCH})"

    # ── ② EXECUTE ──
    > "$RESULT_TMPFILE"
    prompt="$(build_task_prompt "$task_text")"
    echo ""
    if run_claude "$prompt"; then
        accumulate_cost
        # Check if task was checked off
        new_result="$(find_next_task)"
        new_task="${new_result#*|}"
        if [[ "$new_task" == "$task_text" ]]; then
            failed=$((failed + 1))
            consecutive_fails=$((consecutive_fails + 1))
            echo ""; echo "❌ Task failed (not checked off)"
            status_line
            # Still create PR for partial work if there are changes
            if [[ -z "$(git diff "${PREV_BRANCH:-$MAIN_BRANCH}"..HEAD 2>/dev/null)" ]]; then
                echo "  ↩️  No changes — skipping PR"
                git checkout "${PREV_BRANCH:-$MAIN_BRANCH}" 2>/dev/null
                git branch -D "$CURRENT_BRANCH" 2>/dev/null || true
                continue
            fi
        else
            completed=$((completed + 1))
            consecutive_fails=0
            echo ""; echo "✅ Task complete"
        fi
    else
        accumulate_cost
        failed=$((failed + 1))
        consecutive_fails=$((consecutive_fails + 1))
        echo ""; echo "❌ Task failed (exit code)"
        status_line
        # Clean up the failed task branch
        git checkout "${PREV_BRANCH:-$MAIN_BRANCH}" 2>/dev/null
        git branch -D "$CURRENT_BRANCH" 2>/dev/null || true
        # Handle outstanding previous PR before continuing
        # Pass MAIN_BRANCH as return branch since PREV_BRANCH will be deleted by merge
        handle_previous_pr "$MAIN_BRANCH"
        PREV_PR=""
        PREV_PR_URL=""
        PREV_BRANCH=""
        continue
    fi

    # Handle follow-up questions
    if [[ -s "$RESULT_TMPFILE" ]]; then
        handle_followup "$(cat "$RESULT_TMPFILE")"
    fi

    # ── ③ AUTO-COMMIT ──
    auto_commit "$task_num"

    # ── ④ REVIEW ──
    review_output="$(run_review "$task_text")"
    fix_review_issues "$review_output" "$task_num"

    # ── ⑤ CREATE PR ──
    log_phase "📝" "Creating PR..."
    pr_result="$(create_pr "$CURRENT_BRANCH" "$task_text" "$task_num")"
    pr_num="${pr_result%%|*}"
    pr_url="${pr_result#*|}"
    if [[ -n "$pr_num" ]]; then
        log_phase "📝" "PR #${pr_num}: ${pr_url}"
    else
        echo "  ⚠️  PR creation may have failed: ${pr_url}"
    fi

    # ── ⑥ HANDLE PREVIOUS PR ──
    handle_previous_pr "$CURRENT_BRANCH"

    # ── ADVANCE ──
    PREV_PR="$pr_num"
    PREV_PR_URL="$pr_url"
    PREV_BRANCH="$CURRENT_BRANCH"
    status_line

    # Bail on repeated failures
    if [[ $consecutive_fails -ge $MAX_CONSECUTIVE_FAILS ]]; then
        echo ""
        echo "🛑 Stopping: ${MAX_CONSECUTIVE_FAILS} consecutive failures."
        break
    fi

    # Refresh plan content periodically
    if (( (completed + failed) % 3 == 0 )); then
        PLAN_CONTENT="$(cat "$PLAN_PATH")"
    fi

    echo ""
done
