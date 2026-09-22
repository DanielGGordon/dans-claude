#!/usr/bin/env bash
# catalog-drift — compare the LIVE model catalogs (Cursor: `cursor-agent
# --list-models`; Codex: `codex debug models`, a local-cache read) against
# bin/routes.tsv and report drift. Exists so the next "grok 4.7" shows up at
# session start instead of mid-task as a model-run.sh exit-64.
#
#   bash ~/dotfiles/claude/bin/catalog-drift.sh            # live: always re-fetch, refresh caches
#   bash ~/dotfiles/claude/bin/catalog-drift.sh --cached   # reuse ~/.claude/catalog-<backend>.txt if <24h old (hook mode)
#   bash ~/dotfiles/claude/bin/catalog-drift.sh --unrouted # list every unrouted catalog id (combinable with --cached)
#
# Findings, one per stdout line, tab-separated <kind>\t<message>:
#   newer        a model FAMILY routed in routes.tsv (cursor-grok, composer, glm, gpt, ...)
#                has a NEWER version in the catalog than any routes.tsv row,
#                e.g. "Cursor catalog has cursor-grok-4.7-* but routes.tsv stops at cursor-grok-4.6"
#   vanished     a routes.tsv id is no longer in its backend's catalog (the route
#                will hard-fail or silently remap — fix routes.tsv now)
#   unrouted     catalog ids that are neither a `model` nor a `retired` row nor
#                matched by an `ignore` row, summarized per backend by family
#                ("Codex catalog has 2 unrouted ids: gpt-6-luna, gpt-6-sol"). Catches
#                what version-max misses: a new TIER at a routed version (gpt-6-sol
#                next to gpt-6-astra) or a brand-new family (claude-opus-5-5-*, kimi-*).
#   stale        a backend's catalog could not be refreshed; findings above/below for it
#                come from a stale cache (informational)
#   unavailable  a backend's catalog could not be read and no cache exists (binary
#                missing, timeout, not logged in) — that backend is SKIPPED, never fatal
# Exit: 0 no drift · 1 drift found (newer, vanished and/or unrouted) · 2 no catalog readable at all.
# --unrouted prints ONLY `<backend>\t<id>` lines (notes go to stderr); exit 1 if
# any, 0 if none, 2 if no catalog readable. Acknowledge an id you deliberately
# don't route with an `ignore<TAB><glob><TAB><reason>` row in routes.tsv.
# Fail-open by design: unavailable catalogs are reported, not treated as drift.
# --cached also remembers a failed fetch for 1h (catalog-<backend>.failed stamp)
# so a broken/unauthenticated CLI costs one timeout per hour, not per session.
#
# Family/version parsing: strip a leading "cursor-", then <family>-<N[.N...]>[-variant]
# → family + version ("cursor-grok-4.6-high-fast" → grok 4.6; "gpt-5.6-sol" → gpt 5.6;
# "composer-2.5" → composer 2.5). Only families present in routes.tsv are compared;
# new variants of an already-routed version (e.g. -xhigh-fast) are NOT "newer"
# drift — they surface as "unrouted" instead, until routed or ignored.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="$DIR/routes.tsv"
[ -f "$TABLE" ] || { echo "catalog-drift: routing table missing: $TABLE" >&2; exit 2; }
CACHE_DIR="${CATALOG_DRIFT_CACHE_DIR:-$HOME/.claude}"
MAX_AGE="${CATALOG_DRIFT_MAX_AGE:-86400}"   # seconds; --cached reuses a cache younger than this
MODE=live; UNROUTED_ONLY=0
for a in "$@"; do
  case "$a" in
    --cached) MODE=cached ;;
    --unrouted) UNROUTED_ONLY=1 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "catalog-drift: unknown arg '$a'" >&2; exit 64 ;;
  esac
done
[ "$MODE" = cached ] && FETCH_TIMEOUT="${CATALOG_DRIFT_TIMEOUT:-10}" || FETCH_TIMEOUT="${CATALOG_DRIFT_TIMEOUT:-30}"

DRIFT=0; READABLE=0; UNROUTED_FOUND=0
ERR=$(mktemp /tmp/catalog-drift.XXXXXX) || exit 2; trap 'rm -f "$ERR"' EXIT
# --unrouted: only `<backend>\t<id>` lines on stdout; every other finding is
# informational there and goes to stderr.
emit() { if [ "$UNROUTED_ONLY" = 1 ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2"; fi; }

# Raw catalog fetchers: print one model id per line, exit nonzero on failure.
fetch_cursor() {
  command -v cursor-agent >/dev/null 2>&1 || return 127
  local out
  out=$(timeout "$FETCH_TIMEOUT" cursor-agent --list-models </dev/null 2>/dev/null) || return $?
  printf '%s\n' "$out" | awk '/^[a-z0-9][a-z0-9._-]* - /{print $1}' | grep -q . || return 65
  printf '%s\n' "$out" | awk '/^[a-z0-9][a-z0-9._-]* - /{print $1}'
}
fetch_codex() {
  command -v codex >/dev/null 2>&1 || return 127
  local out
  out=$(timeout "$FETCH_TIMEOUT" codex debug models </dev/null 2>/dev/null) || return $?
  printf '%s\n' "$out" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(65)
ms=d.get("models",d) if isinstance(d,dict) else d
ids=[m.get("slug") or m.get("id") for m in ms if isinstance(m,dict) and m.get("visibility","list")!="hide"]
ids=[i for i in ids if i]
if not ids: sys.exit(65)
print("\n".join(ids))'
}

# Returns the id list for a backend (cached or live per MODE) on stdout; prints a
# human reason on stderr and returns nonzero when nothing usable exists.
catalog_for() {
  local be="$1" cache="$CACHE_DIR/catalog-$be.txt" label
  case "$be" in cursor) label="Cursor";; codex) label="Codex";; *) label="$be";; esac
  if [ "$MODE" = cached ] && [ -s "$cache" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$MAX_AGE" ]; then cat "$cache"; return 0; fi
  fi
  local ids st why stamp="$CACHE_DIR/catalog-$be.failed"
  if [ "$MODE" = cached ] && [ -f "$stamp" ] \
     && [ $(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) )) -lt "${CATALOG_DRIFT_FAIL_TTL:-3600}" ]; then
    why="$(cat "$stamp"), not retried for 1h"   # negative cache: don't pay the timeout every session
  else
    ids=$("fetch_$be"); st=$?
    if [ "$st" -eq 0 ]; then
      mkdir -p "$CACHE_DIR" && printf '%s\n' "$ids" > "$cache.tmp" && mv "$cache.tmp" "$cache"
      rm -f "$stamp"; printf '%s\n' "$ids"; return 0
    fi
    case "$st" in
      127) why="$( [ "$be" = cursor ] && echo cursor-agent || echo codex ) not installed" ;;
      124) why="catalog fetch timed out after ${FETCH_TIMEOUT}s" ;;
      65)  why="catalog output unparseable (not logged in?)" ;;
      *)   why="catalog fetch failed (exit $st — not logged in / network?)" ;;
    esac
    mkdir -p "$CACHE_DIR" && printf '%s\n' "$why" > "$stamp"
  fi
  if [ -s "$cache" ]; then
    echo "$label: $why — using stale cache from $(date -r "$cache" +%F)" >&2
    cat "$cache"; return 0
  fi
  echo "$label catalog unavailable ($why)" >&2
  return 1
}

# "<id>" -> "<family> <version>" (or nothing if the id carries no version).
fam_ver() { sed -E 's/^cursor-//' | sed -nE 's/^([a-z][a-z-]*[a-z])-([0-9]+(\.[0-9]+)*)(-.*)?$/\1 \2/p'; }
# Catalog display label per backend for messages.
label_of() { case "$1" in cursor) echo Cursor;; codex) echo Codex;; *) echo "$1";; esac; }
# Family-ish grouping key for the unrouted summary: the leading alphabetic
# dash-words ("claude-opus-5-5-high" -> claude-opus, "kimi-k3-low" -> kimi,
# "gpt-6-sol" -> gpt, "auto" -> auto). Works where fam_ver can't parse a version.
fam_key() { sed -E 's/^cursor-//; s/^([a-z]+(-[a-z]+)*)(-[^-]*[0-9].*)?$/\1/'; }

# Ids routes.tsv already accounts for (any backend): routed + retired. Ignore
# rows are shell globs matched against the bare id AND "<backend>:<id>", so
# `ignore<TAB>cursor:gpt-*<TAB>...` scopes a glob to one backend (Cursor also
# lists gpt-* ids that we route through Codex) while `gemini-3.*` matches anywhere.
# Builtins only (assoc array + case) — this runs in the SessionStart hook over
# ~250 catalog ids, so no per-id forks.
declare -A KNOWN=()
while read -r k; do [ -n "$k" ] && KNOWN[$k]=1; done < <(awk -F'\t' '$1=="model"||$1=="retired"{print $2}' "$TABLE")
mapfile -t IGNORES < <(awk -F'\t' '$1=="ignore" && $2!=""{print $2}' "$TABLE")
is_unrouted() { # $1 backend, $2 id
  [ -n "${KNOWN[$2]:-}" ] && return 1
  local g
  for g in "${IGNORES[@]}"; do
    # shellcheck disable=SC2254  # unquoted on purpose: $g is a glob
    case "$2" in $g) return 1 ;; esac
    case "$1:$2" in $g) return 1 ;; esac
  done
  return 0
}

for be in $(awk -F'\t' '$1=="model"{print $3}' "$TABLE" | sort -u); do
  LABEL=$(label_of "$be")
  ROUTED=$(awk -F'\t' -v b="$be" '$1=="model" && $3==b {print $2}' "$TABLE")
  [ -n "$ROUTED" ] || continue
  if ! CATALOG=$(catalog_for "$be" 2>"$ERR"); then
    emit unavailable "$(cat "$ERR" 2>/dev/null)"; continue
  fi
  [ -s "$ERR" ] && emit stale "$(cat "$ERR")"   # stale-cache note, informational
  READABLE=1

  # (b) routed ids that vanished from the catalog
  while read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$CATALOG" | grep -qxF "$id" \
      || { emit vanished "routes.tsv id $id is gone from the $LABEL catalog"; DRIFT=1; }
  done <<< "$ROUTED"

  # (a) families routed here whose catalog max version is newer than routes.tsv's max
  for fam in $(printf '%s\n' "$ROUTED" | fam_ver | awk '{print $1}' | sort -u); do
    rmax=$(printf '%s\n' "$ROUTED"  | fam_ver | awk -v f="$fam" '$1==f{print $2}' | sort -V | tail -1)
    cmax=$(printf '%s\n' "$CATALOG" | fam_ver | awk -v f="$fam" '$1==f{print $2}' | sort -V | tail -1)
    [ -n "$cmax" ] && [ "$cmax" != "$rmax" ] || continue
    [ "$(printf '%s\n%s\n' "$rmax" "$cmax" | sort -V | tail -1)" = "$cmax" ] || continue
    # Show the new ids as a glob built from a real catalog id ("cursor-grok-4.7-*"),
    # and the routes.tsv ceiling with its real prefix ("cursor-grok-4.6").
    newid=$(printf '%s\n' "$CATALOG" | while read -r id; do
      [ "$(printf '%s\n' "$id" | fam_ver)" = "$fam $cmax" ] && { echo "$id"; break; }; done)
    oldid=$(printf '%s\n' "$ROUTED" | while read -r id; do
      [ "$(printf '%s\n' "$id" | fam_ver)" = "$fam $rmax" ] && { echo "$id"; break; }; done)
    newpfx="${newid%%"$cmax"*}$cmax"; oldpfx="${oldid%%"$rmax"*}$rmax"
    n=$(printf '%s\n' "$CATALOG" | fam_ver | awk -v f="$fam" -v v="$cmax" '$1==f && $2==v' | wc -l)
    emit newer "$LABEL catalog has ${newpfx}-* ($n id$([ "$n" -ne 1 ] && echo s)) but routes.tsv stops at ${oldpfx}"
    DRIFT=1
  done

  # (c) catalog ids routes.tsv doesn't account for at all (see header)
  UNR=$(printf '%s\n' "$CATALOG" | while read -r id; do
    [ -n "$id" ] && is_unrouted "$be" "$id" && printf '%s\n' "$id"; done)
  [ -n "$UNR" ] || continue
  DRIFT=1; UNROUTED_FOUND=1
  if [ "$UNROUTED_ONLY" = 1 ]; then
    printf '%s\n' "$UNR" | sed "s/^/$be\t/"; continue
  fi
  # One line per backend: small families list their ids, big ones "fam-* (n)".
  total=$(printf '%s\n' "$UNR" | wc -l)
  groups=$(paste <(printf '%s\n' "$UNR" | fam_key) <(printf '%s\n' "$UNR") \
    | sort | awk -F'\t' '
        { n[$1]++; ids[$1] = ids[$1] (ids[$1] ? ", " : "") $2; if (!($1 in seen)) { seen[$1]=1; order[++k]=$1 } }
        END { for (i=1;i<=k;i++) { f=order[i]; printf "%s%s", (i>1?"; ":""), (n[f]<=3 ? ids[f] : f "-* (" n[f] ")") } }')
  emit unrouted "$LABEL catalog has $total unrouted id$([ "$total" -ne 1 ] && echo s): $groups — route them in routes.tsv or add ignore rows (list: catalog-drift.sh --unrouted)"
done

[ "$READABLE" -eq 1 ] || exit 2
[ "$UNROUTED_ONLY" = 1 ] && exit "$UNROUTED_FOUND"
exit "$DRIFT"
