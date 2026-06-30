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
#   ~/.claude/android.md           → System-wide Android deployment reference
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
link "$REPO_DIR/android.md"           "$CLAUDE_DIR/android.md"
link "$REPO_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
link "$REPO_DIR/CODING_AGENTS.md"    "$CLAUDE_DIR/CODING_AGENTS.md"
link "$REPO_DIR/hooks"               "$CLAUDE_DIR/hooks"

# --- Install excalidraw-diagram-skill ---

EXCALIDRAW_REPO="https://github.com/coleam00/excalidraw-diagram-skill.git"
EXCALIDRAW_DIR="$REPO_DIR/skills/excalidraw-diagram"

if [ -d "$EXCALIDRAW_DIR/.git" ]; then
  echo "  Updating excalidraw-diagram-skill..."
  git -C "$EXCALIDRAW_DIR" pull --ff-only
else
  echo "  Cloning excalidraw-diagram-skill..."
  git clone "$EXCALIDRAW_REPO" "$EXCALIDRAW_DIR"
fi

# Install Python deps for the renderer if uv is available
if command -v uv >/dev/null 2>&1; then
  echo "  Installing excalidraw renderer dependencies..."
  (cd "$EXCALIDRAW_DIR/references" && uv sync && uv run playwright install chromium)
else
  echo "  WARNING: 'uv' not found — skipping excalidraw renderer setup."
  echo "  Install uv (https://docs.astral.sh/uv/) then run:"
  echo "    cd $EXCALIDRAW_DIR/references && uv sync && uv run playwright install chromium"
fi

echo ""

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

# --- Shell aliases ---

ALIASES_FILE="$HOME/.bash_aliases"
SOURCE_LINE="source ~/dotfiles/claude/aliases.sh"

# Create ~/.bash_aliases if it doesn't exist
if [ ! -f "$ALIASES_FILE" ]; then
  echo "  Creating $ALIASES_FILE"
  touch "$ALIASES_FILE"
fi

# Add source line if not already present
if ! grep -qF "$SOURCE_LINE" "$ALIASES_FILE" 2>/dev/null; then
  echo "" >> "$ALIASES_FILE"
  echo "# Claude Code aliases (managed by ~/dotfiles/claude/install.sh)" >> "$ALIASES_FILE"
  echo "$SOURCE_LINE" >> "$ALIASES_FILE"
  echo "  Added source line to $ALIASES_FILE"
else
  echo "  $ALIASES_FILE already sources aliases.sh"
fi

echo ""
echo "Done. Restart Claude Code and run 'source ~/.bash_aliases' to pick up changes."
