#!/usr/bin/env bash
# cli-fingerprint — zero-cost identity of the CLIs the delegation layer sits on
# (claude, codex, cursor-agent). Prints one TSV line per installed tool:
#   <tool>\t<fingerprint>[\t<version>]
# fingerprint = resolved binary path + size + mtime — changes whenever the tool
# is updated, without spawning it. --versions additionally runs `<tool> --version`
# (slower; routecheck uses it, the SessionStart hook does not).
# Consumers: tests/routecheck.sh writes ~/.claude/route-health-tools.txt with
# versions; hooks/route-health-banner.sh compares fingerprints against it and
# nags to re-run routecheck when Claude Code / Codex / Cursor CLI changed.
set -u
WANT_VERSIONS=0; [ "${1:-}" = "--versions" ] && WANT_VERSIONS=1
for tool in claude codex cursor-agent; do
  path=$(command -v "$tool" 2>/dev/null) || continue
  real=$(readlink -f "$path" 2>/dev/null || echo "$path")
  # mise shims all resolve to the mise binary — ask mise for the real tool path.
  if [ "$(basename "$real")" = mise ] && command -v mise >/dev/null 2>&1; then
    real=$(mise which "$tool" 2>/dev/null || echo "$real"); real=$(readlink -f "$real" 2>/dev/null || echo "$real")
  fi
  fp="$real:$(stat -c '%s:%Y' "$real" 2>/dev/null || echo unknown)"
  if [ "$WANT_VERSIONS" -eq 1 ]; then
    ver=$(timeout 20 "$tool" --version 2>/dev/null | head -1 | tr -d '\t' )
    printf '%s\t%s\t%s\n' "$tool" "$fp" "${ver:-unknown}"
  else
    printf '%s\t%s\n' "$tool" "$fp"
  fi
done
