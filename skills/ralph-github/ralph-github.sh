#!/usr/bin/env bash
# ralph-github.sh — Thin wrapper: runs ralph.py --review
#
# The review functionality (codex / claude fallback) is built into ralph.py.
# This wrapper exists for backwards compatibility.
#
# Usage: ralph-github.sh [plan_path] [options]
#   All options are passed through to ralph.py (plus --review).

exec python3 "$(dirname "$0")/../ralph/ralph.py" --review "$@"
