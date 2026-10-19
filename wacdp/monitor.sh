#!/usr/bin/env bash
# wacdp local monitor — tier 1 of the two-tier persistence setup.
#
# A dumb 30-second health loop. It checks three mechanical facts and restarts
# the failed unit; it does NOT analyze logs or make judgment calls. Deeper
# diagnosis (scrape-error patterns, wedge analysis, restart-loop guard tuning)
# stays with the 15-minute agent watchdog, which also recreates this unit
# after a VM replacement (only the runtime cron survives those).
#
# Checks per cycle:
#   1. wacdp-forwarder / wacdp-chrome / wacdp-webhook / wacdp-daemon are active
#   2. CDP :9429 answers (browser process alive)
#   3. daemon heartbeat: state.json mtime < 120s (rewritten every 20s tick)
#
# Anti-thrash: never restart the same unit more than once per 5 minutes; if a
# restart didn't fix it, log loudly and leave it for the agent watchdog.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
STATE="$DIR/state.json"
MARKER="$DIR/.last_chrome_restart"
LOG="$DIR/monitor.log"
BACKOFF="$DIR/.monitor_backoff"   # lines: "<unit> <epoch-of-last-restart>"

log() { echo "$(date -u '+%F %T') monitor: $*" >> "$LOG"; }

# Grace period on monitor start: let the whole stack settle after a boot or
# VM replacement before judging anything.
sleep 90
log "started (pid $$)"

backed_off() { # $1=unit -> 0 if a restart happened <300s ago
  local unit="$1" now last
  now=$(date +%s)
  last=$(awk -v u="$unit" '$1==u {print $2}' "$BACKOFF" 2>/dev/null | tail -1)
  if [ -n "$last" ] && [ $((now - last)) -lt 300 ]; then
    return 0
  fi
  return 1
}

note_restart() { # $1=unit
  local unit="$1" now tmp
  now=$(date +%s)
  tmp="$BACKOFF.tmp"
  grep -v "^$unit " "$BACKOFF" 2>/dev/null > "$tmp" || true
  echo "$unit $now" >> "$tmp"
  mv "$tmp" "$BACKOFF"
}

do_restart() { # $1=unit -> 0 if restarted, 1 if backed off
  local unit="$1"
  if backed_off "$unit"; then
    log "$unit unhealthy but restarted <5m ago — backing off, leaving for agent watchdog"
    return 1
  fi
  log "restarting $unit"
  systemctl restart "$unit.service" >/dev/null 2>&1 || true
  note_restart "$unit"
  return 0
}

daemon_up_seconds() {
  local mono up
  mono=$(systemctl show wacdp-daemon.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
  up=$(cut -d. -f1 /proc/uptime)
  if [ -n "$mono" ] && [ "$mono" -gt 0 ] 2>/dev/null; then
    echo $(( up - mono / 1000000 ))
  else
    echo 0
  fi
}

recent_scrape_errors() { # 0 if any "scrape error" in daemon.log in last 5 min
  local since
  since=$(date -u -d '5 minutes ago' '+%F %H:%M')
  awk -v since="$since" '$1" "$2 >= since && /scrape error/ {found=1} END {exit !found}' \
    "$DIR/daemon.log" 2>/dev/null
}

chrome_in_grace() { # 0 if within 8 min of a recorded chrome restart
  local now last
  now=$(date +%s)
  last=$(cat "$MARKER" 2>/dev/null || echo 0)
  [ $((now - last)) -lt 480 ]
}

while true; do
  # 1. units active
  for u in wacdp-forwarder wacdp-chrome wacdp-webhook wacdp-daemon; do
    if [ "$(systemctl is-active "$u.service" 2>/dev/null)" != "active" ]; then
      do_restart "$u" || true
    fi
  done

  cdp_ok=0
  curl -s -m 8 http://127.0.0.1:9429/json/version >/dev/null 2>&1 && cdp_ok=1

  # 2. CDP answering (browser alive). CDP is the browser's own endpoint, so a
  #    reload of the WhatsApp page doesn't affect it — no false positives.
  if [ "$cdp_ok" = 0 ]; then
    if chrome_in_grace; then
      log "CDP not answering but inside 8-min chrome reload grace — skipping"
    elif do_restart wacdp-chrome; then
      date +%s > "$MARKER"
      sleep 20
      python3 "$DIR/ensure_wa_tab.py" >/dev/null 2>&1 || true
    fi
  fi

  # 3. daemon heartbeat. Skip when the browser side is unhealthy (that's a
  #    chrome problem, not a daemon problem) or chrome just restarted.
  if [ "$cdp_ok" = 1 ] && ! chrome_in_grace && [ -f "$STATE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STATE") ))
    if [ "$age" -gt 120 ] && [ "$(daemon_up_seconds)" -gt 300 ]; then
      if recent_scrape_errors; then
        log "heartbeat stale (${age}s) but daemon is logging scrape errors — ticking, leaving for agent watchdog"
      else
        log "heartbeat stale (${age}s), daemon up >5m, no scrape errors — wedged, restarting daemon"
        do_restart wacdp-daemon || true
      fi
    fi
  fi

  sleep 30
done
