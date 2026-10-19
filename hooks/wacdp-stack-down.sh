#!/usr/bin/env bash
# wacdp-stack-down — hook poller with PROGRAMMATIC recovery.
#
# Detects stack failure every 60s and recovers it inline (no agent) for all
# known signatures. Wakes an agent ONLY when programmatic recovery fails —
# that is when judgment is actually needed. The hourly agent watchdog remains
# the deep-check/backstop tier (scrape patterns, wedges, boot log).
#
# Detection:
#   1. Any wacdp unit file missing from /etc -> VM replacement wiped them.
#   2. wacdp-monitor not active -> the 30s tier-1 loop itself is down.
#   3. monitor.log "backing off" in last 10 min -> tier-1 gave up on a unit.
#   4. CDP :9429 down for 2 consecutive polls -> browser dead (1st strike
#      stays silent to ride out boot/restart settling).
#
# Recovery (all idempotent, all verified afterward):
#   1-3 -> run ensure-stack.sh (reinstalls all 5 units, restarts, re-tabs).
#   4   -> restart wacdp-chrome (outside grace window only), write the shared
#          .last_chrome_restart marker, re-run ensure_wa_tab.py.
# Verify: up to 3 min for 5 units active + CDP answering + heartbeat fresh.
# Overlap: flock guard — a second poll while recovery runs stays silent.
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

DIR=/home/hatch/workspace/wacdp
MARKER="$DIR/.last_chrome_restart"
STATE_DIR="$HOME/hooks/state/wacdp-stack-down"
FAIL_COUNT="$STATE_DIR/cdp_fail_count"
LOCK="$STATE_DIR/recovery.lock"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
mkdir -p "$STATE_DIR"

finish_wake() { wake "$1" "$2"; exit 0; }
finish_silent() { silent "$1" "$2"; exit 0; }

chrome_in_grace() {
  local now last
  now=$(date +%s)
  last=$(cat "$MARKER" 2>/dev/null || echo 0)
  [ $((now - last)) -lt 480 ]
}

verify_stack() {
  # 0 when all five units active, CDP answering, heartbeat fresh <120s.
  local deadline ok u
  deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ok=1
    for u in wacdp-forwarder wacdp-chrome wacdp-webhook wacdp-daemon wacdp-monitor; do
      [ "$(systemctl is-active "$u.service" 2>/dev/null)" = "active" ] || ok=0
    done
    curl -s -m 5 http://127.0.0.1:9429/json/version >/dev/null 2>&1 || ok=0
    if [ -f "$DIR/state.json" ]; then
      [ $(( $(date +%s) - $(stat -c %Y "$DIR/state.json") )) -lt 120 ] || ok=0
    else
      ok=0
    fi
    [ "$ok" = 1 ] && return 0
    sleep 10
  done
  return 1
}

(
  flock -n 200 || finish_silent "recovery already in progress" '{}'

  # ---- detect ----
  reason=""; action=""
  for u in wacdp-forwarder wacdp-chrome wacdp-webhook wacdp-daemon wacdp-monitor; do
    if [ ! -f "/etc/systemd/system/$u.service" ]; then
      reason="unit files missing (VM replacement), first: $u"; action="full"
      break
    fi
  done
  if [ -z "$reason" ] && [ "$(systemctl is-active wacdp-monitor.service 2>/dev/null)" != "active" ]; then
    reason="wacdp-monitor not active"; action="full"
  fi
  if [ -z "$reason" ] && [ -f "$DIR/monitor.log" ]; then
    since=$(date -u -d '10 minutes ago' '+%F %H:%M')
    if awk -v since="$since" '($1" "$2) >= since && /backing off/ {found=1} END{exit !found}' \
        "$DIR/monitor.log" 2>/dev/null; then
      reason="wacdp-monitor backing off on a failed unit"; action="full"
    fi
  fi
  if [ -z "$reason" ]; then
    if curl -s -m 8 http://127.0.0.1:9429/json/version >/dev/null 2>&1; then
      [ "$DRY" != "1" ] && echo 0 > "$FAIL_COUNT"
      finish_silent "stack healthy" '{}'
    else
      n=$(($(cat "$FAIL_COUNT" 2>/dev/null || echo 0) + 1))
      [ "$DRY" != "1" ] && echo "$n" > "$FAIL_COUNT"
      if [ "$n" -ge 2 ]; then
        if chrome_in_grace; then
          finish_silent "CDP down but inside chrome reload grace (monitor owns it)" '{}'
        fi
        reason="CDP :9429 not answering for 2 consecutive polls"; action="chrome"
      else
        finish_silent "CDP down, first strike" '{}'
      fi
    fi
  fi

  # ---- recover (programmatic, no agent) ----
  if [ "$DRY" = "1" ]; then
    finish_silent "dry-run: would recover: $reason" '{}'
  fi
  log "programmatic recovery: $reason" "{}"
  if [ "$action" = "full" ]; then
    bash "$DIR/ensure-stack.sh" >/dev/null 2>&1 || true
  elif [ "$action" = "chrome" ]; then
    systemctl restart wacdp-chrome.service >/dev/null 2>&1 || true
    date +%s > "$MARKER"
    sleep 20
    python3 "$DIR/ensure_wa_tab.py" >/dev/null 2>&1 || true
  fi

  # ---- verify ----
  if verify_stack; then
    log "recovered OK: $reason" "{}"
    [ "$DRY" != "1" ] && echo 0 > "$FAIL_COUNT"
    finish_silent "recovered programmatically: $reason" '{}'
  else
    finish_wake "programmatic recovery FAILED: $reason" '{}'
  fi
) 200>"$LOCK"
