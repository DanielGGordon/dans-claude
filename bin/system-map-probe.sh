#!/usr/bin/env bash
# system-map-probe — refresh the cached [alfred] session banner.
#
# Writes ready-to-print lines to ~/.claude/system-map.state (override with
# $SYSTEM_MAP_STATE). hooks/system-map-banner.sh only cats that file; this
# script is the only thing that touches systemd or the network, and it is
# cheap: `systemctl --user is-active` per unit (no process spawn beyond
# systemctl) plus two 1s-budget curls.
#
# Fail-open by construction: every probe failure degrades to a "?" and the
# script still writes a usable file and exits 0.
set -u

OUT="${SYSTEM_MAP_STATE:-$HOME/.claude/system-map.state}"

# Long-running units Alfred depends on. Add new ones here (see
# "How to add a component" in system-map.md).
UNITS="t3code second-brain brain-actions voice-gateway voice-tunnel slackcc second-brain-callcards.timer"
# Not installed yet — reported only once their unit file exists.
UNITS_PLANNED="todo"

up=""; down=""; unknown=""
for u in $UNITS; do
  s=$(systemctl --user is-active "$u" 2>/dev/null) || true
  case "$s" in
    active)   up="${up:+$up }$u" ;;
    inactive|failed|activating|deactivating|reloading)
              down="${down:+$down }$u:$s" ;;
    *)        unknown="${unknown:+$unknown }$u" ;;
  esac
done
for u in $UNITS_PLANNED; do
  systemctl --user cat "$u.service" >/dev/null 2>&1 || continue
  s=$(systemctl --user is-active "$u" 2>/dev/null) || true
  [ "$s" = "active" ] && up="${up:+$up }$u" || down="${down:+$down }$u:${s:-?}"
done

# HTTP health (loopback only, 1s budget each, never authenticated — these
# endpoints are unauthenticated by design; never put a token in this script).
health=""
if command -v curl >/dev/null 2>&1; then
  for probe in "second-brain=http://127.0.0.1:4820/health" "brain-actions=http://127.0.0.1:8791/healthz"; do
    name=${probe%%=*}; url=${probe#*=}
    code=$(curl -s -o /dev/null -m 1 -w '%{http_code}' "$url" 2>/dev/null) || code=""
    case "$code" in
      200) health="${health:+$health · }$name ok" ;;
      ""|000) health="${health:+$health · }$name unreachable" ;;
      *)   health="${health:+$health · }$name HTTP $code" ;;
    esac
  done
fi

n_up=$(printf '%s\n' $up | grep -c . || true)
tmp="$OUT.tmp.$$"
{
  echo "# generated $(date -Is) by bin/system-map-probe.sh — do not edit"
  if [ -z "$down$unknown" ]; then
    echo "[alfred] units: all $n_up active ($up) — checked $(date +%H:%M)"
  else
    echo "[alfred] units up ($n_up): ${up:-none} — checked $(date +%H:%M)"
    [ -n "$down" ]    && echo "[alfred] NOT RUNNING: $down — 'systemctl --user status <unit>' / 'journalctl --user -u <unit> -n 50'"
    [ -n "$unknown" ] && echo "[alfred] unit state unknown (not installed?): $unknown"
  fi
  [ -n "$health" ] && echo "[alfred] health: $health"
  echo "[alfred] system map: ~/.claude/system-map.md — read it before any task spanning more than one component; update it in the same commit when a service/port/unit/repo/channel changes."
} > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp"
exit 0
