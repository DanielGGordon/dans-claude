#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Installing dans-claude from $REPO_DIR"
echo "Target: $CLAUDE_DIR"
echo ""

# Ensure ~/.claude exists (CC creates it on first run)
mkdir -p "$CLAUDE_DIR"

# --- Symlinks ---

link() {
  local src="$1"
  local dst="$2"

  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -e "$dst" ]; then
    echo "  Backing up existing $dst → ${dst}.bak"
    mv "$dst" "${dst}.bak"
  fi

  ln -s "$src" "$dst"
  echo "  Linked $dst → $src"
}

link "$REPO_DIR/agents"              "$CLAUDE_DIR/agents"
link "$REPO_DIR/plan-requirements.md" "$CLAUDE_DIR/plan-requirements.md"
link "$REPO_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"

# --- Merge settings.partial.json into settings.json ---

SETTINGS="$CLAUDE_DIR/settings.json"
PARTIAL="$REPO_DIR/settings.partial.json"

if [ ! -f "$SETTINGS" ]; then
  echo "{}" > "$SETTINGS"
fi

echo ""
echo "Merging settings.partial.json into settings.json..."

# Resolve python — prefer python over python3 (avoids Windows Store alias issue)
PYTHON=""
for cmd in python python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    PYTHON="$cmd"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "  ERROR: Python is required for settings merge. Install Python and re-run." >&2
  exit 1
fi

"$PYTHON" -c "
import json, sys

settings_path = sys.argv[1]
partial_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)
with open(partial_path) as f:
    partial = json.load(f)

def deep_merge(base, override):
    for key, val in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(val, dict):
            deep_merge(base[key], val)
        else:
            base[key] = val
    return base

merged = deep_merge(settings, partial)

with open(settings_path, 'w') as f:
    json.dump(merged, f, indent=2, ensure_ascii=False)
    f.write('\n')

print('  Merged successfully.')
" "$SETTINGS" "$PARTIAL"

echo ""
echo "Done. Restart Claude Code to pick up changes (/exit or Ctrl+C, then run 'claude')."
