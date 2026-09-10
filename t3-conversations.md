# T3 Code Conversations

Where to find the coding-agent conversations for **every** project on this
machine, from a session in any project.

## Where they live

One self-hosted T3 Code server at `https://15.204.108.12:7443`, backed by a
single event-sourced SQLite database:

```
~/.t3/userdata/state.sqlite
```

Every project's threads are in there — don't try to reconstruct a conversation
from the current repo's git history.

## Reading it

There is no `sqlite3` binary on this box. Query read-only with the helper that
ships in the T3 repo:

```bash
cd ~/projects/meta/t3code-v2 && node apps/server/scripts/t3-sqlite-state.ts query \
  --base-dir ~/.t3 --sql "SELECT ..."
```

Output is JSON on stdout. Read-only `query` is safe while the server is running.
**Never** run the helper's `exec` (write) mode against `~/.t3` — that is live
prod state.

## Tables that matter

Join on `project_id` / `thread_id`; ignore rows with `deleted_at` set.

- `projection_projects` — `project_id`, `title`, `workspace_root`
- `projection_threads` — `thread_id`, `project_id`, `title`, `branch`,
  `worktree_path`, `created_at`, `updated_at`, `archived_at`, `settled_at`
- `projection_thread_messages` — `message_id`, `thread_id`, `turn_id`, `role`,
  `text`, `created_at`
- `projection_thread_activities`, `projection_turns` — per-turn tool/activity
  detail when the message text isn't enough
- `orchestration_events` — the raw event log the projections are built from

Example — recent threads for a project by name:

```sql
SELECT t.thread_id, t.title, t.branch, t.updated_at
FROM projection_threads t
JOIN projection_projects p ON p.project_id = t.project_id
WHERE p.title = 'sofer-ai' AND t.deleted_at IS NULL
ORDER BY t.updated_at DESC LIMIT 20;
```

## Full raw transcripts

The message table holds rendered text. For everything a thread's agent actually
did (tool calls, results, thinking), take the thread's `worktree_path` and read
the Claude Code JSONL transcripts at:

```
~/.claude/projects/<worktree_path with every / and . replaced by ->/*.jsonl
```

e.g. `/home/dgordon/.t3/worktrees/sofer-ai/t3code-6ca4429f` →
`~/.claude/projects/-home-dgordon--t3-worktrees-sofer-ai-t3code-6ca4429f/`.
