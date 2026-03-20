#!/usr/bin/env bash
# ralph-github.sh — Thin wrapper: runs ralph.sh --review
#
# The review functionality (codex / claude fallback) is now built into ralph.sh.
# This wrapper exists for backwards compatibility.
#
# Usage: ralph-github.sh [plan_path] [options]
#   All options are passed through to ralph.sh (plus --review).

exec bash "$(dirname "$0")/../ralph/ralph.sh" --review "$@"
