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

## Android Deployment

When planning or executing an Android app deployment for any project, consult `~/.claude/android.md` first. It is the system-wide canonical reference for Android signing, build, version bumping, and distribution. If the project's deploy process changes (or a new project deploys Android differently), update `~/.claude/android.md` to reflect the new canonical process — diverging projects must be documented there.
