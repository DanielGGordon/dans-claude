# Global Claude Code Instructions

## Claude Config Management

All Claude Code configuration — hooks, agents, skills, settings, and utilities — is managed in `~/dotfiles/claude/`. Never edit files directly in `~/.claude/`; most are symlinks back to the repo.

Before making any changes to hooks, skills, agents, or Claude settings:

1. Read `~/dotfiles/claude/README.md` for the full repo structure, conventions, and how install works.
2. Make all edits in `~/dotfiles/claude/` (not `~/.claude/`).
3. Update `~/dotfiles/claude/README.md` if the change adds, removes, or alters any documented feature.
4. Commit the changes and push to GitHub.
5. Run `bash ~/dotfiles/claude/install.sh` so symlinks and merged settings take effect.
6. Remind the user to restart Claude Code if settings changed.
