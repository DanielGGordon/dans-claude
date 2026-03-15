#!/usr/bin/env bash
input=$(cat)

user=$(whoami)
host=$(hostname 2>/dev/null | cut -d. -f1)
dir=$(echo "$input" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null)

# Shorten home directory to ~
home="$HOME"
if [ -n "$home" ] && [ -n "$dir" ]; then
  dir="${dir/#$home/~}"
fi

model=$(echo "$input" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('model',{}).get('id',''))" 2>/dev/null)
used=$(echo "$input" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('context_window',{}).get('used_percentage',''))" 2>/dev/null)

# Build the status line
status="${user}@${host}:${dir}"

if [ -n "$model" ]; then
  status="${status} | ${model}"
fi

if [ -n "$used" ]; then
  printf_used=$(printf "%.0f" "$used" 2>/dev/null || echo "$used")
  status="${status} | ${printf_used}%"
fi

printf "%s" "$status"
