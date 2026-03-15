#!/usr/bin/env bash
input=$(cat)

user=$(whoami)
host=$(hostname -s)
dir=$(echo "$input" | jq -r '.cwd // empty')

# Shorten home directory to ~
home="$HOME"
if [ -n "$home" ] && [ -n "$dir" ]; then
  dir="${dir/#$home/~}"
fi

model=$(echo "$input" | jq -r '.model.id // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

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
