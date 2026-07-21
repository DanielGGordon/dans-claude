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

## Model Strategy & Delegation

Model routing is documented in two files — selection (when/why) and usage (how):

1. **`~/.claude/model-selection.md` — WHICH model, WHEN.** Any time you are
   about to use a subagent (Agent tool) or a workflow (Workflow tool), read it
   FIRST — before launching anything — and pick each agent's model according to
   it. This applies to every delegation, not just big ones: single Explore
   agents, review panels, workflow fan-outs, all of it. It covers the rankings
   table, per-task-type guidance (bulk/mechanical vs. user-facing vs.
   review/planning vs. recent-info research), and the
   intelligence > taste > cost-efficiency priority for anything that ships.
2. **`~/.claude/model-usage.md` — HOW to invoke the chosen model.** Canonical
   `codex exec` and `cursor-agent` wrapper patterns, native Claude model routing
   for subagents/workflows, exact current model ids, and the auth/quota
   stop-and-surface rules.

Follow both strictly unless the user explicitly says otherwise. (`~/.claude/models.md`
is a deprecated stub pointing at these two.)

## Visual Web Testing (Playwright)

When the user asks you to "test visually", screenshot a web app, or use Playwright, read `~/.claude/playwright.md` first — it documents the canonical screenshot toolkit and how to visually evaluate the result. Only on the user's request; do not add Playwright testing to tasks that didn't ask for it.

## Android Deployment

When planning or executing an Android app deployment for any project, consult `~/.claude/android.md` first. It is the system-wide canonical reference for Android signing, build, version bumping, and distribution. If the project's deploy process changes (or a new project deploys Android differently), update `~/.claude/android.md` to reflect the new canonical process — diverging projects must be documented there.
