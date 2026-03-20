#!/usr/bin/env bash
#
# Claude Code status line command
#
# Reads JSON session data from stdin and renders a colored single-line status bar.
#
# Segments (left to right):
#   📁  dir                  — working directory (green, ~ for home)
#   🌿  branch               — current git branch (cyan, hidden if not a repo)
#   🔥  Model effort         — model + effort level (emoji/color by effort)
#   ██░░ 42%  12k↑ 3k↓      — gradient context bar + input/output tokens
#                               true-color gradient: green→yellow→red (fully red at 70%)
#   💰  $1.23                — session cost in USD (API users only, green)
#   📈  hour/day             — token usage last hour / today (subscription users, green)
#   🌲  worktree:branch      — active git worktree (cyan, hidden if none)
#   🤖  agent-name           — active subagent name (magenta, hidden if none)
#   📡                       — remote control active (single emoji, hidden if inactive)
#
# Token tracking (subscription mode):
#   When no cost data is present (subscription plan), token deltas are logged
#   to ~/.claude/token-usage.log and aggregated per-hour and per-day. A state
#   file (~/.claude/token-usage.state) tracks per-session totals to compute
#   deltas. The log is pruned to today's entries on each run.
#
# Requires a terminal with true-color (24-bit) support for the gradient bar.

input=$(cat)

# Parse all fields in a single python call for efficiency
parsed="$(echo "$input" | python -c "
import sys, json, shlex, os

d = json.load(sys.stdin)

cwd = d.get('cwd', '')
model_obj = d.get('model', {})
if isinstance(model_obj, dict):
    model_id = model_obj.get('id', '')
else:
    model_id = str(model_obj)

ctx = d.get('context_window', {})
usage = ctx.get('current_usage') or {}
input_tokens = (usage.get('input_tokens') or 0) + (usage.get('cache_creation_input_tokens') or 0) + (usage.get('cache_read_input_tokens') or 0)
output_tokens = usage.get('output_tokens') or 0
cost_data = d.get('cost') or {}
total_cost = cost_data.get('total_cost_usd', '')
session_id = d.get('session_id', '') or d.get('cwd', '')

# Agent and worktree info
agent_name = (d.get('agent') or {}).get('name', '')
worktree_name = (d.get('worktree') or {}).get('name', '')
worktree_branch = (d.get('worktree') or {}).get('branch', '')

# Effort level — check JSON data, then fall back to settings.json
effort = ''
for key in ('effortLevel', 'effort_level', 'reasoning_effort'):
    v = d.get(key, '')
    if v:
        effort = v
        break
if not effort and isinstance(model_obj, dict):
    for key in ('effortLevel', 'effort_level'):
        v = model_obj.get(key, '')
        if v:
            effort = v
            break
if not effort:
    try:
        with open(os.path.expanduser('~/.claude/settings.json')) as f:
            effort = json.load(f).get('effortLevel', '')
    except Exception:
        pass
if isinstance(effort, (int, float)):
    if effort <= 33:
        effort = 'low'
    elif effort <= 66:
        effort = 'medium'
    else:
        effort = 'high'
effort = str(effort).lower().strip() if effort else ''

# Remote control
remote = bool(d.get('remoteControl') or d.get('remote_control') or d.get('isRemoteControlled'))

def fmt_model(m):
    mappings = {
        'claude-opus-4-6[1m]': 'Opus 4.6 (1M)',
        'claude-opus-4-6': 'Opus 4.6',
        'claude-sonnet-4-6[1m]': 'Sonnet 4.6 (1M)',
        'claude-sonnet-4-6': 'Sonnet 4.6',
        'claude-haiku-4-5-20251001': 'Haiku 4.5',
        'claude-sonnet-4-5-20250514': 'Sonnet 4.5',
        'claude-opus-4-0-20250514': 'Opus 4.0',
        'claude-sonnet-4-0-20250514': 'Sonnet 4.0',
    }
    if m in mappings:
        return mappings[m]
    # Fallback: strip 'claude-' prefix and date suffixes
    name = m.replace('claude-', '').split('-2025')[0].split('-2024')[0].split('-2026')[0]
    # Handle [Xm] context suffix
    ctx = ''
    if '[' in name:
        ctx_part = name[name.index('['):]
        name = name[:name.index('[')]
        ctx = ' (' + ctx_part.strip('[]').upper() + ')'
    parts = name.split('-')
    return ' '.join(p.capitalize() for p in parts) + ctx

model_id = fmt_model(model_id)

def fmt_tokens(n):
    if n >= 1_000_000:
        return f'{n/1_000_000:.1f}M'
    elif n >= 1_000:
        return f'{n//1_000}k'
    return str(n)

# Context bar: 10 chars wide, based on 200k ceiling (not model max)
total_tokens = input_tokens + output_tokens
ceiling = 200_000
pct_val = total_tokens / ceiling * 100
if pct_val > 100:
    pct_val = 100

bar_width = 10
filled = int(round(pct_val / 100 * bar_width))
filled = min(filled, bar_width)

# Percentage text color: green <35%, yellow 35-70%, red >=70%
if pct_val >= 70:
    pct_color = '31'  # red
elif pct_val >= 35:
    pct_color = '33'  # yellow
else:
    pct_color = '32'  # green

# --- Token usage tracking (hour/day) — only for subscription (no cost) ---
has_cost = total_cost and str(total_cost) not in ('', 'None', '0')
hour_tokens = 0
day_tokens = 0

if not has_cost:
    import time, hashlib, fcntl
    from datetime import datetime

    log_dir = os.path.expanduser('~/.claude')
    log_file = os.path.join(log_dir, 'token-usage.log')
    state_file = os.path.join(log_dir, 'token-usage.state')

    now = time.time()
    sid = hashlib.md5(session_id.encode()).hexdigest()[:8]

    # Read last known total for this session
    last_total = 0
    state_lines = {}
    try:
        with open(state_file) as f:
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) == 2:
                    state_lines[parts[0]] = int(parts[1])
        last_total = state_lines.get(sid, 0)
    except FileNotFoundError:
        pass

    # Compute delta and log if positive
    delta = total_tokens - last_total
    if delta < 0:
        delta = total_tokens  # new session (total reset)
        last_total = 0

    if delta > 0:
        try:
            with open(log_file, 'a') as f:
                fcntl.flock(f, fcntl.LOCK_EX)
                f.write(f'{int(now)}\t{delta}\n')
                fcntl.flock(f, fcntl.LOCK_UN)
        except Exception:
            pass
        state_lines[sid] = total_tokens
        try:
            with open(state_file, 'w') as f:
                for k, v in state_lines.items():
                    f.write(f'{k}\t{v}\n')
        except Exception:
            pass

    # Sum tokens from log for past hour and today
    hour_ago = now - 3600
    today_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    pruned = []
    try:
        with open(log_file) as f:
            for line in f:
                parts = line.strip().split('\t')
                if len(parts) != 2:
                    continue
                ts, tok = int(parts[0]), int(parts[1])
                if ts >= today_start:
                    pruned.append(line)
                    day_tokens += tok
                    if ts >= hour_ago:
                        hour_tokens += tok
        with open(log_file, 'w') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.writelines(pruned)
            fcntl.flock(f, fcntl.LOCK_UN)
    except FileNotFoundError:
        pass
    except Exception:
        pass

print(f'SL_CWD={shlex.quote(cwd)}')
print(f'SL_MODEL={shlex.quote(model_id)}')
print(f'SL_EFFORT={shlex.quote(effort)}')
print(f'SL_IN_TOKENS={shlex.quote(fmt_tokens(input_tokens))}')
print(f'SL_OUT_TOKENS={shlex.quote(fmt_tokens(output_tokens))}')
print(f'SL_FILLED={filled}')
print(f'SL_PCT_COLOR={pct_color}')
print(f'SL_PCT={shlex.quote(str(int(round(pct_val))))}')
print(f'SL_COST={shlex.quote(str(total_cost))}')
print(f'SL_HOUR_TOKENS={shlex.quote(fmt_tokens(hour_tokens))}')
print(f'SL_DAY_TOKENS={shlex.quote(fmt_tokens(day_tokens))}')
print(f'SL_AGENT={shlex.quote(agent_name)}')
print(f'SL_WORKTREE={shlex.quote(worktree_name)}')
print(f'SL_WORKTREE_BRANCH={shlex.quote(worktree_branch)}')
print(f'SL_REMOTE={1 if remote else 0}')
" 2>&1)"

if [ $? -ne 0 ] || [ -z "$parsed" ]; then
  # Fallback: show basic info if python parsing fails
  printf "statusline parse error"
  exit 0
fi

eval "$parsed"

# Shorten home directory to ~
dir="${SL_CWD/#$HOME/\~}"

# Git branch (fast — typically <5ms on local repos)
git_branch=$(git -C "$SL_CWD" branch --show-current 2>/dev/null)

# Colors
GREEN='\033[32m'
MAGENTA='\033[35m'
YELLOW='\033[33m'
CYAN='\033[36m'
RED='\033[31m'
DIM='\033[2m'
RESET='\033[0m'

# Build gradient context bar (true-color per-character)
# Gradient: green(46,180,46) → yellow(220,180,46) at 35% → red(220,46,46) at 70%
bar=""
for ((i=0; i<10; i++)); do
  char_pct=$(( (i + 1) * 10 ))
  if [ "$i" -lt "$SL_FILLED" ]; then
    if [ "$char_pct" -le 35 ]; then
      r=$(( 46 + char_pct * 174 / 35 ))
      g=180
      b=46
    elif [ "$char_pct" -le 70 ]; then
      r=220
      g=$(( 180 - (char_pct - 35) * 134 / 35 ))
      b=46
    else
      r=220
      g=46
      b=46
    fi
    bar="${bar}\033[38;2;${r};${g};${b}m█"
  else
    bar="${bar}\033[38;2;80;80;80m░"
  fi
done
bar="${bar}${RESET}"

# Build status line with emoji icons
# 📁 Green: directory (no hostname)
status="${GREEN}📁 ${dir}${RESET}"

# 🌿 Cyan: git branch
if [ -n "$git_branch" ]; then
  status="${status} ${CYAN}🌿 ${git_branch}${RESET}"
fi

# Model + effort level (emoji and color vary by effort)
if [ -n "$SL_MODEL" ]; then
  case "$SL_EFFORT" in
    max)    effort_emoji="💎"; effort_color='\033[1;35m' ;;
    high)   effort_emoji="🔥"; effort_color="${RED}" ;;
    medium) effort_emoji="⚡"; effort_color="${YELLOW}" ;;
    low)    effort_emoji="🧊"; effort_color="${CYAN}" ;;
    *)      effort_emoji="🧠"; effort_color="${MAGENTA}" ;;
  esac
  if [ -n "$SL_EFFORT" ]; then
    status="${status} ${DIM}|${RESET} ${effort_color}${effort_emoji} ${SL_MODEL} ${SL_EFFORT}${RESET}"
  else
    status="${status} ${DIM}|${RESET} ${effort_color}${effort_emoji} ${SL_MODEL}${RESET}"
  fi
fi

# 📊 Gradient context bar with token counts
status="${status} ${DIM}|${RESET} ${bar} \033[${SL_PCT_COLOR}m${SL_PCT}%${RESET}"
status="${status} ${YELLOW}${SL_IN_TOKENS}↑ ${SL_OUT_TOKENS}↓${RESET}"

# 💰 Cost (API) or 📈 Token usage hour/day (subscription)
if [ -n "$SL_COST" ] && [ "$SL_COST" != "None" ] && [ "$SL_COST" != "" ] && [ "$SL_COST" != "0" ]; then
  cost_fmt=$(printf "\$%.2f" "$SL_COST" 2>/dev/null || echo "\$${SL_COST}")
  status="${status} ${DIM}|${RESET} ${GREEN}💰 ${cost_fmt}${RESET}"
elif [ -n "$SL_DAY_TOKENS" ] && [ "$SL_DAY_TOKENS" != "0" ]; then
  status="${status} ${DIM}|${RESET} ${GREEN}📈 ${SL_HOUR_TOKENS}/${SL_DAY_TOKENS}${RESET}"
fi

# 🌲 Worktree indicator
if [ -n "$SL_WORKTREE" ]; then
  wt_label="$SL_WORKTREE"
  [ -n "$SL_WORKTREE_BRANCH" ] && wt_label="${wt_label}:${SL_WORKTREE_BRANCH}"
  status="${status} ${DIM}|${RESET} ${CYAN}🌲 ${wt_label}${RESET}"
fi

# 🤖 Agent indicator
if [ -n "$SL_AGENT" ]; then
  status="${status} ${DIM}|${RESET} ${MAGENTA}🤖 ${SL_AGENT}${RESET}"
fi

# 📡 Remote control indicator
if [ "$SL_REMOTE" = "1" ]; then
  status="${status} 📡"
fi

printf "%b" "$status"
