#!/usr/bin/env bash
input=$(cat)

# Parse all fields in a single python call for efficiency
parsed="$(echo "$input" | python -c "
import sys, json, shlex

d = json.load(sys.stdin)

cwd = d.get('cwd', '')
model_id = d.get('model', {}).get('id', '')
ctx = d.get('context_window', {})
used_pct = ctx.get('used_percentage', '') or 0
usage = ctx.get('current_usage') or {}
input_tokens = (usage.get('input_tokens') or 0) + (usage.get('cache_creation_input_tokens') or 0) + (usage.get('cache_read_input_tokens') or 0)
output_tokens = usage.get('output_tokens') or 0
cost_data = d.get('cost') or {}
total_cost = cost_data.get('total_cost_usd', '')

# Agent and worktree info
agent_name = (d.get('agent') or {}).get('name', '')
worktree_name = (d.get('worktree') or {}).get('name', '')
worktree_branch = (d.get('worktree') or {}).get('branch', '')

def fmt_tokens(n):
    if n >= 1_000_000:
        return f'{n/1_000_000:.1f}M'
    elif n >= 1_000:
        return f'{n//1_000}k'
    return str(n)

# Context bar: 10 chars wide, based on 200k ceiling
bar_width = 10
pct_val = float(used_pct) if used_pct else 0
filled = int(round(pct_val / 100 * bar_width))
filled = min(filled, bar_width)
bar = chr(0x2588) * filled + chr(0x2591) * (bar_width - filled)

# Bar color: green <50%, yellow 50-80%, red >80%
if pct_val > 80:
    bar_color = '31'  # red
elif pct_val > 50:
    bar_color = '33'  # yellow
else:
    bar_color = '32'  # green

print(f'SL_CWD={shlex.quote(cwd)}')
print(f'SL_MODEL={shlex.quote(model_id)}')
print(f'SL_IN_TOKENS={shlex.quote(fmt_tokens(input_tokens))}')
print(f'SL_OUT_TOKENS={shlex.quote(fmt_tokens(output_tokens))}')
print(f'SL_BAR={shlex.quote(bar)}')
print(f'SL_BAR_COLOR={bar_color}')
print(f'SL_PCT={shlex.quote(str(int(round(pct_val))))}')
print(f'SL_COST={shlex.quote(str(total_cost))}')
print(f'SL_AGENT={shlex.quote(agent_name)}')
print(f'SL_WORKTREE={shlex.quote(worktree_name)}')
print(f'SL_WORKTREE_BRANCH={shlex.quote(worktree_branch)}')
" 2>&1)"

if [ $? -ne 0 ] || [ -z "$parsed" ]; then
  # Fallback: show basic info if python parsing fails
  printf "statusline parse error"
  exit 0
fi

eval "$parsed"

# Shorten home directory to ~
dir="${SL_CWD/#$HOME/\~}"
user=$(whoami)
host=$(hostname 2>/dev/null | cut -d. -f1)

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

# Build status line with emoji icons
# 📁 Green: directory
status="${GREEN}📁 ${user}@${host}:${dir}${RESET}"

# 🌿 Cyan: git branch
if [ -n "$git_branch" ]; then
  status="${status} ${CYAN}🌿 ${git_branch}${RESET}"
fi

# 🤖 Magenta: model
if [ -n "$SL_MODEL" ]; then
  status="${status} ${DIM}|${RESET} ${MAGENTA}🧠 ${SL_MODEL}${RESET}"
fi

# 📊 Context bar with token counts
if [ -n "$SL_BAR_COLOR" ]; then
  status="${status} ${DIM}|${RESET} \033[${SL_BAR_COLOR}m${SL_BAR} ${SL_PCT}%${RESET}"
  status="${status} ${YELLOW}${SL_IN_TOKENS}↑ ${SL_OUT_TOKENS}↓${RESET}"
fi

# 💰 Green: session cost
if [ -n "$SL_COST" ] && [ "$SL_COST" != "None" ] && [ "$SL_COST" != "" ]; then
  cost_fmt=$(printf "\$%.2f" "$SL_COST" 2>/dev/null || echo "\$${SL_COST}")
  status="${status} ${DIM}|${RESET} ${GREEN}💰 ${cost_fmt}${RESET}"
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

printf "%b" "$status"
