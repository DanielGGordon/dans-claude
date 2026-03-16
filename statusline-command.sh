#!/usr/bin/env bash
input=$(cat)

# Parse all fields in a single python call for efficiency
eval "$(echo "$input" | python -c "
import sys, json, shlex

d = json.load(sys.stdin)

cwd = d.get('cwd', '')
model_id = d.get('model', {}).get('id', '')
ctx = d.get('context_window', {})
used_pct = ctx.get('used_percentage', '')
usage = ctx.get('current_usage', {})
input_tokens = usage.get('input_tokens', 0) + usage.get('cache_creation_input_tokens', 0) + usage.get('cache_read_input_tokens', 0)
cost_data = d.get('cost', {})
total_cost = cost_data.get('total_cost_usd', '')

# Format tokens as compact (e.g. 84k, 1.2M)
if input_tokens >= 1_000_000:
    tokens_fmt = f'{input_tokens/1_000_000:.1f}M'
elif input_tokens >= 1_000:
    tokens_fmt = f'{input_tokens//1_000}k'
else:
    tokens_fmt = str(input_tokens)

print(f'SL_CWD={shlex.quote(cwd)}')
print(f'SL_MODEL={shlex.quote(model_id)}')
print(f'SL_USED_PCT={shlex.quote(str(used_pct))}')
print(f'SL_TOKENS={shlex.quote(tokens_fmt)}')
print(f'SL_COST={shlex.quote(str(total_cost))}')
" 2>/dev/null)"

# Shorten home directory to ~
dir="${SL_CWD/#$HOME/\~}"
user=$(whoami)
host=$(hostname 2>/dev/null | cut -d. -f1)

# Colors
GREEN='\033[32m'
MAGENTA='\033[35m'
YELLOW='\033[33m'
RESET='\033[0m'

# Build status line with colors
# Green: directory | Magenta: model | Yellow: context | Green: cost
status="${GREEN}${user}@${host}:${dir}${RESET}"

if [ -n "$SL_MODEL" ]; then
  status="${status} | ${MAGENTA}${SL_MODEL}${RESET}"
fi

if [ -n "$SL_USED_PCT" ]; then
  pct=$(printf "%.0f" "$SL_USED_PCT" 2>/dev/null || echo "$SL_USED_PCT")
  status="${status} | ${YELLOW}${pct}% ${SL_TOKENS}${RESET}"
fi

if [ -n "$SL_COST" ] && [ "$SL_COST" != "None" ] && [ "$SL_COST" != "" ]; then
  cost_fmt=$(printf "$%.2f" "$SL_COST" 2>/dev/null || echo "\$${SL_COST}")
  status="${status} | ${GREEN}${cost_fmt}${RESET}"
fi

printf "%b" "$status"
