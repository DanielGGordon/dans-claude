#!/bin/bash
#
# install.sh — Install dans-claude config into ~/.claude/
#
# Creates symlinks from ~/.claude/ back to this repo so that Claude Code
# picks up custom config while the source of truth stays in ~/dotfiles/claude/.
#
# Symlinks created:
#   ~/.claude/CLAUDE.md            → Global instructions loaded every session
#   ~/.claude/CODING_AGENTS.md     → Coding agent rules injected by the ralph skill
#   ~/.claude/agents/              → Named agents (e.g. plan-reviewer)
#   ~/.claude/skills/              → Skills (e.g. /ralph)
#   ~/.claude/plan-requirements.md → Requirements enforced by the plan review hook
#   ~/.claude/hooks/                → Hook scripts (e.g. plan review on Stop)
#   ~/.claude/statusline-command.sh → Status bar renderer (model, tokens, context, cost)
#
# Settings merge:
#   Deep-merges settings.partial.json into ~/.claude/settings.json so that
#   hooks, statusline config, and other custom keys are applied without
#   overwriting Claude Code-managed keys (model, permissions, plugins).
#   Requires Python.
#
# Safe to re-run: existing symlinks are replaced; regular files are backed up
# to *.bak before being overwritten.
#
# Usage:
#   bash ~/dotfiles/claude/install.sh
#
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

link "$REPO_DIR/CLAUDE.md"            "$CLAUDE_DIR/CLAUDE.md"
link "$REPO_DIR/agents"              "$CLAUDE_DIR/agents"
link "$REPO_DIR/skills"              "$CLAUDE_DIR/skills"
link "$REPO_DIR/plan-requirements.md" "$CLAUDE_DIR/plan-requirements.md"
link "$REPO_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
link "$REPO_DIR/CODING_AGENTS.md"    "$CLAUDE_DIR/CODING_AGENTS.md"
link "$REPO_DIR/hooks"               "$CLAUDE_DIR/hooks"

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

# Remove deprecated PreToolUse plan review hook (replaced by Stop hook)
pre = merged.get('hooks', {}).get('PreToolUse', [])
merged.setdefault('hooks', {})['PreToolUse'] = [
    h for h in pre if h.get('matcher') != 'ExitPlanMode'
]
if not merged['hooks']['PreToolUse']:
    del merged['hooks']['PreToolUse']

with open(settings_path, 'w') as f:
    json.dump(merged, f, indent=2, ensure_ascii=False)
    f.write('\n')

print('  Merged successfully.')
" "$SETTINGS" "$PARTIAL"

echo ""
echo "Done. Restart Claude Code to pick up changes (/exit or Ctrl+C, then run 'claude')."
